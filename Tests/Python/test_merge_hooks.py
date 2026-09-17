"""Exercise the merge command boundary with isolated configuration files."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"


class MergeTests:
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.config = self.root / "settings.json"
        self.adapter = self.root / "odd ' $(touch injected) `touch nope` & home" / "BlinkStatus/hooks" / self.adapter_name

    def run_merge(self, remove=False, check=True):
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / self.script), str(self.config),
             "--adapter", str(self.adapter)] + (["--remove"] if remove else []),
            text=True, capture_output=True,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_absent_empty_and_empty_object_receive_all_events(self):
        for initial in (None, "", "{}"):
            with self.subTest(initial=initial):
                if self.config.exists():
                    self.config.unlink()
                if initial is not None:
                    self.config.write_text(initial)
                self.run_merge()
                hooks = json.loads(self.config.read_text())["hooks"]
                self.assertEqual(set(hooks), set(self.events))
                for entries in hooks.values():
                    self.assertEqual(len(entries), 1)
                    handler = entries[0]["hooks"][0]
                    self.assertEqual(handler["type"], "command")
                    self.assertEqual(handler["timeout"], 2)
                    self.assertEqual(shlex.split(handler["command"]),
                                     ["/usr/bin/python3", str(self.adapter)])

    def test_preserves_unrelated_settings_and_mixed_matcher_handlers(self):
        original = {"permissions": {"allow": ["Read"]}, "theme": "dark", "hooks": {
            "UnrelatedEvent": [{"custom": 12, "hooks": [{"type": "command", "command": "echo keep"}]}],
            "Stop": [{"matcher": "special", "extra": True, "hooks": [
                {"type": "command", "command": "echo unrelated"},
                {"type": "command", "command": "/usr/bin/python3 " + shlex.quote(str(self.adapter))}]}]}}
        self.config.write_text(json.dumps(original))
        self.run_merge()
        merged = json.loads(self.config.read_text())
        self.assertEqual(merged["permissions"], original["permissions"])
        self.assertEqual(merged["theme"], "dark")
        self.assertEqual(merged["hooks"]["UnrelatedEvent"], original["hooks"]["UnrelatedEvent"])
        self.assertEqual(merged["hooks"]["Stop"][0], {
            "matcher": "special", "extra": True,
            "hooks": [{"type": "command", "command": "echo unrelated"}]})

    def test_repeated_install_is_byte_identical_and_does_not_backup_again(self):
        self.run_merge()
        before = self.config.read_bytes()
        before_stat = self.config.stat()
        result = self.run_merge()
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(self.config.stat().st_ino, before_stat.st_ino)
        self.assertNotIn("Backup:", result.stdout)

    def test_malformed_config_refused_without_writing(self):
        for raw in ('{', '[]', '{"hooks": []}', '{"hooks": {"Stop": {}}}',
                    '{"hooks": {"Stop": [{"hooks": "bad"}]}}',
                    '{"hooks": {"Stop": [{"hooks": [3]}]}}',
                    '{"hooks": {}, "hooks": {}}', '{"value": NaN}'):
            with self.subTest(raw=raw):
                self.config.write_text(raw)
                result = self.run_merge(check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.config.read_text(), raw)
                self.assertEqual(list(self.root.glob("*.backup-*")), [])

    def test_uninstall_only_removes_owned_handlers_and_keeps_other_ecosystem(self):
        other = "claude_hook.py" if self.adapter_name == "codex_hook.py" else "codex_hook.py"
        keep = [{"type": "command", "command": "echo keep"},
                {"type": "command", "command": f"python3 /x/BlinkStatus/hooks/{other}"},
                {"type": "command", "command": f"python3 /x/BlinkStatus/hooks/{self.adapter_name}.backup"}]
        original = {"other": {"setting": 42}, "hooks": {"Stop": [
            {"matcher": "*", "hooks": keep + [{"type": "command", "command":
             "/usr/bin/python3 " + shlex.quote(str(self.adapter))}]},
            {"matcher": "empty-but-existing", "hooks": []}]}}
        self.config.write_text(json.dumps(original))
        self.run_merge(remove=True)
        expected = {"other": {"setting": 42}, "hooks": {"Stop": [
            {"matcher": "*", "hooks": keep}, {"matcher": "empty-but-existing", "hooks": []}]}}
        self.assertEqual(json.loads(self.config.read_text()), expected)
        self.run_merge(remove=True)
        self.assertEqual(json.loads(self.config.read_text()), expected)

    def test_missing_uninstall_is_noop(self):
        self.run_merge(remove=True)
        self.assertFalse(self.config.exists())

    def test_only_exact_installed_python_command_is_owned(self):
        installed = shlex.quote(str(self.adapter))
        keep = [{"type": "command", "command": command} for command in (
            "echo " + installed,
            f"echo /other/BlinkStatus/hooks/{self.adapter_name}",
            f"/usr/bin/python3 /other/BlinkStatus/hooks/{self.adapter_name}",
            "/usr/bin/python3 " + installed + " --unrelated-option",
            "/usr/bin/python3 " + installed + " && echo user-work",
            "env /usr/bin/python3 " + installed,
        )]
        original = {"setting": "keep", "hooks": {"Stop": [{"matcher": "*", "hooks": keep + [
            {"type": "command", "command": "/usr/bin/python3 " + installed}]}]}}
        for remove in (False, True):
            with self.subTest(remove=remove):
                self.config.write_text(json.dumps(original))
                self.run_merge(remove=remove)
                result = json.loads(self.config.read_text())
                self.assertEqual(result["setting"], "keep")
                self.assertEqual(result["hooks"]["Stop"][0], {"matcher": "*", "hooks": keep})
                if remove:
                    self.assertEqual(result, {"setting": "keep", "hooks": {"Stop": [
                        {"matcher": "*", "hooks": keep}]}})

    def test_backup_preserves_original_bytes_and_permissions_are_private(self):
        original = b'{"theme":"dark"}\n'
        self.config.write_bytes(original)
        self.config.chmod(0o640)
        result = self.run_merge()
        backup = Path(next(line.removeprefix("Backup: ") for line in result.stdout.splitlines()
                           if line.startswith("Backup: ")))
        self.assertEqual(backup.read_bytes(), original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
        self.assertEqual(list(self.root.glob("*.tmp-*")), [])

    def test_symlink_config_refused_without_changing_target(self):
        target = self.root / "actual.json"
        target.write_text('{"keep": true}')
        self.config.symlink_to(target)
        self.assertNotEqual(self.run_merge(check=False).returncode, 0)
        self.assertTrue(self.config.is_symlink())
        self.assertEqual(target.read_text(), '{"keep": true}')


class CodexMergeTests(MergeTests, unittest.TestCase):
    script = "merge_hooks.py"
    adapter_name = "codex_hook.py"
    events = ("UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd")


class ClaudeMergeTests(MergeTests, unittest.TestCase):
    script = "merge_claude_settings.py"
    adapter_name = "claude_hook.py"
    events = ("SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd")


if __name__ == "__main__":
    unittest.main()
