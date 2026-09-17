import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts" / "claude_hook.py"
SPEC = importlib.util.spec_from_file_location("claude_hook", SCRIPT)
claude_hook = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(claude_hook)


class ClaudeHookTests(unittest.TestCase):
    fixed_timestamp = 1_700_000_000.25

    def test_lifecycle_fixtures_encode_compact_unix_events(self):
        fixtures = [
            ("SessionStart", {}, "update", 0, 24 * 60 * 60),
            ("UserPromptSubmit", {}, "update", 1, 2 * 60 * 60),
            ("PostToolUse", {}, "update", 1, 2 * 60 * 60),
            ("PermissionRequest", {}, "update", 2, 24 * 60 * 60),
            ("Notification", {"notification_type": "permission_prompt"}, "update", 2, 24 * 60 * 60),
            ("Notification", {"notification_type": "elicitation_dialog"}, "update", 2, 24 * 60 * 60),
            ("Notification", {"notification_type": "idle_prompt"}, "update", 0, 24 * 60 * 60),
            ("Stop", {"last_assistant_message": "The requested work is complete."}, "update", 0, 24 * 60 * 60),
            ("Stop", {"last_assistant_message": "Which option should I use?"}, "update", 2, 24 * 60 * 60),
            ("SessionEnd", {}, "clear", None, None),
        ]

        with mock.patch.object(claude_hook.time, "time", return_value=self.fixed_timestamp):
            for event_name, fields, action, state, expiry_seconds in fixtures:
                with self.subTest(event_name=event_name, fields=fields):
                    event = claude_hook.event_for({
                        "hook_event_name": event_name,
                        "session_id": "session-123",
                        **fields,
                    })

                    self.assertEqual("claude-code:session-123", event["sourceID"])
                    self.assertEqual("com.anthropic.claude-code", event["applicationID"])
                    self.assertEqual(action, event["action"])
                    self.assertEqual(state, event["state"])
                    self.assertEqual(self.fixed_timestamp, event["timestamp"])
                    if expiry_seconds is None:
                        self.assertIsNone(event["expiresAt"])
                    else:
                        self.assertEqual(self.fixed_timestamp + expiry_seconds, event["expiresAt"])

                    encoded = json.dumps(event, separators=(",", ":")) + "\n"
                    self.assertEqual(encoded.encode("utf-8"), claude_hook.encoded_line(event))

    def test_unknown_event_and_notification_subtype_produce_no_event(self):
        self.assertIsNone(claude_hook.event_for({
            "hook_event_name": "UnknownEvent",
            "session_id": "session-123",
        }))
        self.assertIsNone(claude_hook.event_for({
            "hook_event_name": "Notification",
            "notification_type": "unknown_prompt",
            "session_id": "session-123",
        }))

    def test_malformed_json_exits_successfully_without_output(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)],
            input="{not json",
            text=True,
            capture_output=True,
            env={**os.environ, "BLINK_STATUS_SOCKET": "/tmp/no-such-blink-status.sock"},
            check=False,
        )

        self.assertEqual(0, result.returncode)
        self.assertEqual("", result.stdout)
        self.assertEqual("", result.stderr)

    def test_socket_unavailable_exits_successfully_without_output(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)],
            input=json.dumps({
                "hook_event_name": "UserPromptSubmit",
                "session_id": "session-123",
            }),
            text=True,
            capture_output=True,
            env={**os.environ, "BLINK_STATUS_SOCKET": "/tmp/no-such-blink-status.sock"},
            check=False,
        )

        self.assertEqual(0, result.returncode)
        self.assertEqual("", result.stdout)
        self.assertEqual("", result.stderr)

    def test_hook_sends_one_compact_newline_delimited_event(self):
        received = self.run_hook({
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session-123",
        })

        self.assertTrue(received.startswith(b'{"sourceID":"claude-code:session-123",'))
        self.assertTrue(received.endswith(b"\n"))
        self.assertNotIn(b", ", received)
        event = json.loads(received)
        self.assertEqual("update", event["action"])
        self.assertEqual(1, event["state"])

    def run_hook(self, payload):
        with tempfile.TemporaryDirectory() as directory:
            socket_path = str(Path(directory) / "events.sock")
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(socket_path)
            listener.listen(1)
            listener.settimeout(2)
            received = []

            def receive_once():
                try:
                    connection, _ = listener.accept()
                except OSError:
                    return
                with connection:
                    received.append(connection.recv(16 * 1024 + 1))

            receiver = threading.Thread(target=receive_once)
            receiver.start()
            try:
                result = subprocess.run(
                    [sys.executable, str(SCRIPT)],
                    input=json.dumps(payload),
                    text=True,
                    capture_output=True,
                    env={**os.environ, "BLINK_STATUS_SOCKET": socket_path},
                    timeout=2,
                    check=False,
                )
            finally:
                listener.close()
            receiver.join(timeout=2)

        self.assertEqual(0, result.returncode)
        self.assertEqual("", result.stdout)
        self.assertEqual("", result.stderr)
        self.assertFalse(receiver.is_alive())
        self.assertEqual(1, len(received))
        return received[0]


if __name__ == "__main__":
    unittest.main()
