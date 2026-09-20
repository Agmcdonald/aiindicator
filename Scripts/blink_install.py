"""Packaging operations. Real install/uninstall only run through main()."""
import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from xml.parsers.expat import ExpatError

from hook_config import CLAUDE_EVENTS, CODEX_EVENTS, atomic_write, load_config, safe_path, update_config

LABEL = "com.andrewmcdonald.blink-status"
SERIALS = ("2000A159", "2000A15D")
MANIFEST = {"label": LABEL, "serials": list(SERIALS), "format": 1}
BLINK_TOOL = "/opt/homebrew/bin/blink1-tool"


@dataclass(frozen=True)
class Paths:
    home: Path

    @property
    def support(self):
        return self.home / "Library/Application Support/BlinkStatus"

    @property
    def plist(self):
        return self.home / "Library/LaunchAgents" / (LABEL + ".plist")

    @property
    def logs(self):
        return self.home / "Library/Logs/BlinkStatus"

    @property
    def configurations(self):
        return ((self.home / ".codex/hooks.json", "codex_hook.py", CODEX_EVENTS),
                (self.home / ".claude/settings.json", "claude_hook.py", CLAUDE_EVENTS))


def verify_devices(output):
    serials = re.findall(r"(?<!\S)serialnum:([^\s()]+)", output)
    if any(serials.count(serial) != 1 for serial in SERIALS):
        raise ValueError("Connect each approved blink(1) exactly once: 2000A159 and 2000A15D")


def private_directory(path):
    path = safe_path(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.chmod(0o700)


def validate_owned_paths(paths):
    # Paths are derived from the account database, never from a user-controlled
    # deletion argument, $HOME override, or a recursive wildcard.
    for path in (paths.support, paths.plist, paths.logs):
        safe_path(path)
    for filename in ("stdout.log", "stderr.log"):
        log_file = safe_path(paths.logs / filename)
        if log_file.exists() and not log_file.is_file():
            raise ValueError(f"Refusing nonregular log file: {log_file}")
    if paths.support.exists():
        marker = safe_path(paths.support / ".installation.json")
        if not marker.is_file() or json.loads(marker.read_bytes()) != MANIFEST:
            raise ValueError(f"Refusing to replace/remove an unrecognized directory: {paths.support}")
    if paths.plist.exists():
        try:
            data = plistlib.loads(paths.plist.read_bytes())
        except ExpatError as error:
            # plistlib reports malformed XML through the parser's own error,
            # which is neither ValueError nor OSError and so escaped main() as
            # a traceback. An unparsable plist is unrecognized: refuse it.
            # plistlib.InvalidFileException is already a ValueError and needs
            # no translation; other exceptions stay unmasked.
            raise ValueError(f"Refusing an unreadable LaunchAgent: {paths.plist}: {error}") from error
        executable = str(paths.support / "bin/blink-statusd")
        if (not isinstance(data, dict) or data.get("Label") != LABEL
                or data.get("ProgramArguments") != [executable]
                or ("Program" in data and data["Program"] != executable)):
            raise ValueError(f"Refusing to replace/remove an unrecognized LaunchAgent: {paths.plist}")


def preflight(paths):
    validate_owned_paths(paths)
    # Validate both before changing either configuration.
    for config, _, _ in paths.configurations:
        load_config(config)


def stage(source, executable, paths):
    validate_owned_paths(paths)
    for directory in (paths.support, paths.support / "bin", paths.support / "hooks",
                      paths.support / "manage", paths.logs):
        private_directory(directory)
    safe_path(paths.plist.parent).mkdir(mode=0o700, parents=True, exist_ok=True)
    # Write the marker first so interruption leaves a recognizable partial install.
    atomic_write(paths.support / ".installation.json", json.dumps(MANIFEST).encode())
    atomic_write(paths.support / "bin/blink-statusd", executable.read_bytes(), 0o700)
    for name in ("codex_hook.py", "claude_hook.py"):
        atomic_write(paths.support / "hooks" / name, (source / "Scripts" / name).read_bytes())
    for name in ("blink_install.py", "hook_config.py", "merge_hooks.py", "merge_claude_settings.py"):
        atomic_write(paths.support / "manage" / name, (source / "Scripts" / name).read_bytes())
    atomic_write(paths.support / "uninstall.sh", (source / "Scripts/uninstall.sh").read_bytes(), 0o700)
    atomic_write(paths.support / "README.md", (source / "README.md").read_bytes())
    plist = plistlib.loads((source / "Resources" / (LABEL + ".plist")).read_bytes())
    plist["ProgramArguments"] = [str(paths.support / "bin/blink-statusd")]
    plist["StandardOutPath"] = str(paths.logs / "stdout.log")
    plist["StandardErrorPath"] = str(paths.logs / "stderr.log")
    atomic_write(paths.plist, plistlib.dumps(plist))


def merge_configurations(paths, remove=False):
    for config, adapter_name, events in paths.configurations:
        update_config(config, paths.support / "hooks" / adapter_name, events, remove)


def uninstall_files(paths):
    validate_owned_paths(paths)
    if paths.plist.exists():
        paths.plist.unlink()
    if paths.support.exists():
        marker = paths.support / ".installation.json"
        # Remove every other entry before the manifest marker. A removal that
        # fails partway then leaves a still-recognized directory, so rerunning
        # the uninstaller can finish it instead of refusing the remainder.
        # Top-level links are refused; rmtree does not follow internal links.
        for entry in sorted(paths.support.iterdir()):
            if entry == marker:
                continue
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry)
            else:
                entry.unlink()
        if marker.exists():
            marker.unlink()
        try:
            paths.support.rmdir()
        except OSError:
            # The marker is gone but the directory survives. Restore the
            # validated manifest so a rerun still recognizes the remainder
            # instead of refusing it.
            atomic_write(marker, json.dumps(MANIFEST).encode())
            raise


def run(arguments, **kwargs):
    return subprocess.run([str(argument) for argument in arguments], check=True, **kwargs)


def service_is_loaded(service):
    return subprocess.run(["/bin/launchctl", "print", service], capture_output=True).returncode == 0


def bootout_if_loaded(paths, attempts=50, delay=0.1):
    service = f"gui/{os.getuid()}/{LABEL}"
    if not service_is_loaded(service):
        return
    run(["/bin/launchctl", "bootout", service])
    # bootout returns before launchd finishes deregistering the job, and a
    # bootstrap inside that window fails with an I/O error, so an upgrade over
    # a running install must wait for the service to actually go away.
    for _ in range(attempts):
        if not service_is_loaded(service):
            return
        time.sleep(delay)
    raise ValueError(f"Timed out waiting for {LABEL} to stop; rerun the installer")


def install(source, paths):
    preflight(paths)
    discovered = run([BLINK_TOOL, "--list"], capture_output=True, text=True, timeout=5)
    verify_devices(discovered.stdout)
    source = source.resolve(strict=True)
    if not (source / "Package.swift").is_file():
        raise ValueError("Run the installer from a complete BlinkStatus source checkout")
    # A local scratch directory avoids File Provider extended attributes that
    # interfere with executable signing in the Documents checkout.
    with tempfile.TemporaryDirectory(prefix="blink-status-build-", dir="/private/tmp") as scratch:
        run(["/usr/bin/xcrun", "swift", "build", "--package-path", source,
             "--scratch-path", scratch, "-c", "release"])
        binary_directory = run(["/usr/bin/xcrun", "swift", "build", "--package-path", source,
                                "--scratch-path", scratch, "-c", "release", "--show-bin-path"],
                               capture_output=True, text=True).stdout.strip()
        # Stop an earlier version only after compilation succeeds.
        preflight(paths)
        bootout_if_loaded(paths)
        stage(source, Path(binary_directory) / "blink-statusd", paths)
    merge_configurations(paths)
    run(["/usr/bin/plutil", "-lint", paths.plist])
    run(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", paths.plist])
    run(["/bin/launchctl", "kickstart", f"gui/{os.getuid()}/{LABEL}"])
    run([paths.support / "bin/blink-statusd", "--request-accessibility"])
    print("BlinkStatus installed. Enable Accessibility for blink-statusd when prompted.")
    print(f"Uninstall: /bin/bash {shlex.quote(str(paths.support / 'uninstall.sh'))}")


def uninstall(paths):
    preflight(paths)
    bootout_if_loaded(paths)
    merge_configurations(paths, remove=True)
    uninstall_files(paths)
    print("Removed BlinkStatus helper, its LaunchAgent, and its hook handlers.")
    print(f"Backups remain beside the configuration files. Logs remain at: {paths.logs}")
    print("Homebrew, blink1-tool, and other application settings remain installed.")


def main():
    parser = argparse.ArgumentParser(description="Install or uninstall the two-device BlinkStatus integration.")
    parser.add_argument("action", choices=("install", "uninstall"))
    parser.add_argument("--source", type=Path)
    args = parser.parse_args()
    if sys.platform != "darwin" or os.getuid() == 0:
        parser.error("Run as the signed-in macOS user, without sudo")
    paths = Paths(Path(pwd.getpwuid(os.getuid()).pw_dir))
    try:
        if args.action == "install":
            if args.source is None:
                parser.error("install requires --source")
            install(args.source, paths)
        else:
            uninstall(paths)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"BlinkStatus {args.action} stopped: {error}", file=sys.stderr)
        print("An interrupted operation may be partial. Keep the printed configuration backups; correct the error and rerun.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
