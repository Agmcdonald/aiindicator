"""Lossless-in-meaning hook updates and private, atomic file replacement."""
import argparse
import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shlex
import stat
import sys
import tempfile

CODEX_EVENTS = ("UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd")
CLAUDE_EVENTS = ("SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd")


def safe_path(path):
    """Refuse symbolic-link traversal, including a dangling final link."""
    path = Path(path).absolute()
    for component in (path, *path.parents):
        if component.is_symlink():
            raise ValueError(f"Refusing symbolic link: {component}")
    return path


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f"Invalid JSON number: {value}")


def load_config(path):
    path = safe_path(path)
    raw = path.read_bytes() if path.exists() else None
    data = json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject_constant) if raw and raw.strip() else {}
    if not isinstance(data, dict):
        raise ValueError("Configuration must be a JSON object")
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("hooks must be a JSON object")
    for entries in hooks.values():
        if not isinstance(entries, list):
            raise ValueError("Each hook event must contain an array")
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
                raise ValueError("Each hook entry must contain a hooks array")
            if any(not isinstance(handler, dict) for handler in entry["hooks"]):
                raise ValueError("Hook handlers must be objects")
    return raw, data


def owned(handler, adapter_name):
    command = handler.get("command")
    if handler.get("type") != "command" or not isinstance(command, str):
        return False
    try:
        tokens = shlex.split(command)
    except ValueError:
        return False
    return any(token.endswith("/BlinkStatus/hooks/" + adapter_name) for token in tokens)


def merged_config(data, adapter, events, remove=False):
    adapter = Path(adapter)
    if not adapter.is_absolute() or adapter.name not in ("codex_hook.py", "claude_hook.py"):
        raise ValueError("Adapter must be an absolute path to a supported hook script")
    result = copy.deepcopy(data)
    hooks = result.get("hooks", {})
    for event, entries in list(hooks.items()):
        remaining = []
        for entry in entries:
            handlers = [handler for handler in entry["hooks"] if not owned(handler, adapter.name)]
            if handlers or not entry["hooks"]:
                remaining.append(dict(entry, hooks=handlers))
        # Remove only event containers emptied by removal of this integration.
        if remaining or not entries:
            hooks[event] = remaining
        else:
            del hooks[event]
    if not remove:
        result["hooks"] = hooks
        for event in events:
            hooks.setdefault(event, []).append({"hooks": [{
                "type": "command", "command": "/usr/bin/python3 " + shlex.quote(str(adapter)), "timeout": 2,
            }]})
    return result


def atomic_write(path, content, mode=0o600):
    path = safe_path(path)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def update_config(path, adapter, events, remove=False):
    path = safe_path(path)
    raw, data = load_config(path)
    updated = merged_config(data, adapter, events, remove)
    if data == updated:
        return None
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup = None
    mode = 0o600
    if raw is not None:
        mode = stat.S_IMODE(path.stat().st_mode) & 0o777
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        backup = path.with_name(path.name + ".backup-" + stamp)
        # Exclusive creation avoids collisions and never overwrites an older backup.
        with backup.open("xb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        print(f"Backup: {backup}", flush=True)
    # A concurrent editor must not be silently overwritten after preflight/backup.
    current = path.read_bytes() if path.exists() else None
    if current != raw:
        raise ValueError(f"Configuration changed while preparing update: {path}; retry")
    atomic_write(path, (json.dumps(updated, indent=2, ensure_ascii=False) + "\n").encode(), mode)
    return backup


def merge_cli(events, adapter_name):
    parser = argparse.ArgumentParser(description="Merge or remove BlinkStatus hooks; preserve all unrelated settings.")
    parser.add_argument("config", type=Path)
    parser.add_argument("--adapter", required=True, type=Path)
    parser.add_argument("--remove", action="store_true")
    args = parser.parse_args()
    try:
        if args.adapter.name != adapter_name:
            raise ValueError("Wrong adapter for this configuration")
        update_config(args.config, args.adapter, events, args.remove)
        return 0
    except (OSError, ValueError) as error:
        print(f"Configuration unchanged or update incomplete: {error}", file=sys.stderr)
        return 1
