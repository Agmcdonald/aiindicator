import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts" / "codex_hook.py"


class CodexHookTests(unittest.TestCase):
    def test_lifecycle_fixtures_send_expected_events(self):
        fixtures = [
            ("UserPromptSubmit", "", "update", 1, 2 * 60 * 60),
            ("PermissionRequest", "", "update", 2, 24 * 60 * 60),
            ("PostToolUse", "", "update", 1, 2 * 60 * 60),
            ("Stop", "The requested work is complete.", "update", 0, None),
            ("Stop", "Which option should I use?", "update", 2, None),
            ("Interrupt", "", "update", 0, None),
            ("SessionEnd", "", "clear", None, None),
        ]

        for event_name, message, action, state, expiry_seconds in fixtures:
            with self.subTest(event_name=event_name, message=message):
                received = self.run_hook({
                    "hook_event_name": event_name,
                    "session_id": "session-123",
                    "turn_id": "turn-456",
                    "last_assistant_message": message,
                })

                self.assertEqual("codex:session-123", received["sourceID"])
                self.assertEqual("com.openai.codex", received["applicationID"])
                self.assertEqual(action, received["action"])
                self.assertEqual(state, received["state"])
                if expiry_seconds is None:
                    self.assertIsNone(received["expiresAt"])
                else:
                    self.assertAlmostEqual(
                        received["timestamp"] + expiry_seconds,
                        received["expiresAt"],
                        delta=1,
                    )

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
        self.assertTrue(received[0].endswith(b"\n"))
        return json.loads(received[0])


if __name__ == "__main__":
    unittest.main()
