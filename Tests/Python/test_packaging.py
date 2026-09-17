from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPTS))


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((SCRIPTS / "blink_install.py").exists(), "Packaging implementation is missing")
        import blink_install
        self.module = blink_install
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve() / "fake home & 'quotes'"
        self.home.mkdir()
        self.paths = blink_install.Paths(self.home)

    def stage(self):
        executable = self.home / "fake-binary"
        executable.write_bytes(b"fixture binary, never executed")
        self.module.stage(SCRIPTS.parent, executable, self.paths)

    def test_serial_preflight_rejects_missing_duplicate_and_substring(self):
        good = "id:0 - serialnum:2000A159 (mk2)\nid:1 - serialnum:2000A15D (mk2)"
        self.module.verify_devices(good)
        for output in ("", good.replace("2000A15D", "2000A15D0"), good + "\nid:2 - serialnum:2000A159 (mk2)"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                self.module.verify_devices(output)

    def test_stage_creates_private_portable_install_and_expanded_plist(self):
        self.stage()
        plist = plistlib.loads(self.paths.plist.read_bytes())
        self.assertEqual(plist["ProgramArguments"], [str(self.paths.support / "bin/blink-statusd")])
        self.assertEqual(plist["KeepAlive"], {"SuccessfulExit": False})
        self.assertEqual(plist["StandardOutPath"], str(self.paths.logs / "stdout.log"))
        for directory in (self.paths.support, self.paths.support / "bin", self.paths.support / "hooks", self.paths.support / "manage", self.paths.logs):
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.paths.support / "bin/blink-statusd").read_bytes(), b"fixture binary, never executed")
        # The installed uninstaller must import its utilities without the checkout.
        result = subprocess.run(["/bin/bash", str(self.paths.support / "uninstall.sh"), "--help"],
                                cwd=self.home, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("uninstall", result.stdout)

    def test_uninstall_removes_only_manifest_owned_install_and_plist(self):
        self.stage()
        sibling = self.paths.support.parent / "KeepMe"
        sibling.mkdir()
        marker = sibling / "data"
        marker.write_text("keep")
        self.paths.logs.joinpath("stdout.log").write_text("diagnostic")
        self.module.uninstall_files(self.paths)
        self.assertFalse(self.paths.support.exists())
        self.assertFalse(self.paths.plist.exists())
        self.assertEqual(marker.read_text(), "keep")
        self.assertTrue(self.paths.logs.joinpath("stdout.log").exists())
        self.module.uninstall_files(self.paths)

    def test_refuses_unowned_or_symlink_install_directory(self):
        self.paths.support.parent.mkdir(parents=True)
        self.paths.support.mkdir()
        (self.paths.support / "user-data").write_text("keep")
        with self.assertRaises(ValueError):
            self.stage()
        with self.assertRaises(ValueError):
            self.module.uninstall_files(self.paths)
        self.assertEqual((self.paths.support / "user-data").read_text(), "keep")
        other_home = self.home / "other"
        other_home.mkdir()
        linked_paths = self.module.Paths(other_home)
        linked_paths.support.parent.mkdir(parents=True)
        linked_paths.support.symlink_to(self.paths.support)
        with self.assertRaises(ValueError):
            self.module.uninstall_files(linked_paths)

    def test_atomic_replace_failure_retains_original_and_backup(self):
        import hook_config
        config = self.home / "config.json"
        original = b'{"setting": "keep"}'
        config.write_bytes(original)
        printed = io.StringIO()
        with redirect_stdout(printed), patch("hook_config.os.replace", side_effect=OSError("simulated replacement failure")):
            with self.assertRaises(OSError):
                hook_config.update_config(config, self.paths.support / "hooks/codex_hook.py", hook_config.CODEX_EVENTS)
        self.assertEqual(config.read_bytes(), original)
        self.assertEqual(next(self.home.glob("config.json.backup-*")).read_bytes(), original)
        self.assertIn(str(next(self.home.glob("config.json.backup-*"))), printed.getvalue())
        self.assertEqual(list(self.home.glob("config.json.tmp-*")), [])

    def test_second_config_invalid_preflight_changes_neither_configuration(self):
        codex, claude = (entry[0] for entry in self.paths.configurations)
        codex.parent.mkdir()
        claude.parent.mkdir()
        codex.write_text('{"keep": "codex"}')
        claude.write_text('malformed')
        with self.assertRaises(ValueError):
            self.module.preflight(self.paths)
        self.assertEqual(codex.read_text(), '{"keep": "codex"}')
        self.assertEqual(claude.read_text(), 'malformed')
        self.assertFalse(self.paths.support.exists())

    def test_non_object_plist_is_refused_before_removal(self):
        self.paths.plist.parent.mkdir(parents=True)
        self.paths.plist.write_bytes(plistlib.dumps([]))
        with self.assertRaises(ValueError):
            self.module.uninstall_files(self.paths)
        self.assertTrue(self.paths.plist.exists())


if __name__ == "__main__":
    unittest.main()
