#!/usr/bin/env python3
"""Translate one Codex lifecycle hook payload into a local daemon event."""

import json
import os
import socket
import sys
import time


APPLICATION_ID = "com.openai.codex-cli"
SOCKET_TIMEOUT_SECONDS = 0.2
WORKING_EXPIRY_SECONDS = 2 * 60 * 60
ATTENTION_EXPIRY_SECONDS = 24 * 60 * 60
READY_EXPIRY_SECONDS = 24 * 60 * 60


def needs_input(message):
    if not isinstance(message, str):
        return False

    normalized = " ".join(message.lower().split())
    if not normalized or "let me know" in normalized:
        return False
    if normalized.endswith("?"):
        return True
    return any(phrase in normalized for phrase in (
        "please attach",
        "attach the missing",
        "need your approval",
        "need your permission",
        "needs permission",
        "requires permission",
        "choose ",
        "select ",
    ))


def event_for(payload):
    event_name = payload.get("hook_event_name")
    session_id = payload.get("session_id")
    turn_id = payload.get("turn_id")
    message = payload.get("last_assistant_message")
    if not isinstance(event_name, str) or not isinstance(session_id, str) or not session_id:
        return None
    if turn_id is not None and not isinstance(turn_id, str):
        return None

    timestamp = time.time()
    event = {
        "sourceID": f"codex:{session_id}",
        "applicationID": APPLICATION_ID,
        "timestamp": timestamp,
        "expiresAt": None,
    }

    if event_name in ("UserPromptSubmit", "PostToolUse"):
        event.update(action="update", state=1, expiresAt=timestamp + WORKING_EXPIRY_SECONDS)
    elif event_name == "PermissionRequest":
        event.update(action="update", state=2, expiresAt=timestamp + ATTENTION_EXPIRY_SECONDS)
    elif event_name == "Stop":
        attention = needs_input(message)
        lease = ATTENTION_EXPIRY_SECONDS if attention else READY_EXPIRY_SECONDS
        event.update(action="update", state=2 if attention else 0, expiresAt=timestamp + lease)
    elif event_name == "Interrupt":
        event.update(action="update", state=0, expiresAt=timestamp + READY_EXPIRY_SECONDS)
    elif event_name == "SessionEnd":
        event.update(action="clear", state=None)
    else:
        return None

    return event


def socket_path():
    return os.environ.get(
        "BLINK_STATUS_SOCKET",
        f"/tmp/blink-status-{os.getuid()}/events.sock",
    )


def send(event):
    payload = json.dumps(event, separators=(",", ":")).encode("utf-8") + b"\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(SOCKET_TIMEOUT_SECONDS)
        client.connect(socket_path())
        client.sendall(payload)


def main():
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            return 0
        event = event_for(payload)
        if event is not None:
            send(event)
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
