#!/usr/bin/env python3
"""Translate one Claude Code hook payload into a local daemon event."""

import json
import os
import socket
import sys
import time


APPLICATION_ID = "com.anthropic.claude-code"
SOCKET_TIMEOUT_SECONDS = 0.2
WORKING_EXPIRY_SECONDS = 2 * 60 * 60
READY_EXPIRY_SECONDS = 24 * 60 * 60
ATTENTION_EXPIRY_SECONDS = 24 * 60 * 60


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
    notification_type = payload.get("notification_type")
    message = payload.get("last_assistant_message")

    if not isinstance(event_name, str) or not isinstance(session_id, str) or not session_id:
        return None

    timestamp = time.time()
    event = {
        "sourceID": f"claude-code:{session_id}",
        "applicationID": APPLICATION_ID,
        "timestamp": timestamp,
        "expiresAt": None,
    }

    if event_name == "SessionStart":
        event.update(action="update", state=0, expiresAt=timestamp + READY_EXPIRY_SECONDS)
    elif event_name in ("UserPromptSubmit", "PostToolUse"):
        event.update(action="update", state=1, expiresAt=timestamp + WORKING_EXPIRY_SECONDS)
    elif event_name == "PermissionRequest":
        event.update(action="update", state=2, expiresAt=timestamp + ATTENTION_EXPIRY_SECONDS)
    elif event_name == "Notification":
        if notification_type in ("permission_prompt", "elicitation_dialog"):
            event.update(action="update", state=2, expiresAt=timestamp + ATTENTION_EXPIRY_SECONDS)
        elif notification_type == "idle_prompt":
            event.update(action="update", state=0, expiresAt=timestamp + READY_EXPIRY_SECONDS)
        else:
            return None
    elif event_name == "Stop":
        state = 2 if needs_input(message) else 0
        event.update(
            action="update",
            state=state,
            expiresAt=timestamp + (ATTENTION_EXPIRY_SECONDS if state == 2 else READY_EXPIRY_SECONDS),
        )
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


def encoded_line(event):
    return json.dumps(event, separators=(",", ":")).encode("utf-8") + b"\n"


def send(event):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(SOCKET_TIMEOUT_SECONDS)
        client.connect(socket_path())
        client.sendall(encoded_line(event))


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
