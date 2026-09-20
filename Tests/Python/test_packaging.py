from contextlib import redirect_stderr, redirect_stdout
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

    def test_uninstall_interrupted_midway_can_be_rerun(self):
        # README: a failed uninstall preserves remaining files so it can be
        # rerun. A rerun must not refuse the remainder because the manifest
        # marker happened to be deleted before the failure.
        self.stage()
        leftover = self.paths.support / "bin/blink-statusd"
        real_unlink = os.unlink

        def fail_on_binary(path, *args, **kwargs):
            # rmtree passes bare entry names alongside dir_fd, not full paths.
            if os.path.basename(str(path)) == "blink-statusd":
                raise PermissionError(13, "Operation not permitted", str(path))
            return real_unlink(path, *args, **kwargs)

        with patch.object(self.module.os, "unlink", fail_on_binary), \
                patch.object(self.module.shutil.os, "unlink", fail_on_binary):
            with self.assertRaises(OSError):
                self.module.uninstall_files(self.paths)
        self.assertTrue(leftover.exists(), "partial removal should leave the un-deletable file")
        # The rerun must still recognize the remainder and finish the job.
        self.module.uninstall_files(self.paths)
        self.assertFalse(self.paths.support.exists())

    def test_uninstall_failing_final_rmdir_can_be_rerun(self):
        # The marker is unlinked last, but the directory removal that follows
        # can still fail. The remainder must stay recognizable for a rerun.
        self.stage()
        real_rmdir = os.rmdir

        def fail_on_support(path, *args, **kwargs):
            if Path(str(path)) == self.paths.support:
                raise OSError(66, "Directory not empty", str(path))
            return real_rmdir(path, *args, **kwargs)

        with patch.object(self.module.os, "rmdir", fail_on_support):
            with self.assertRaises(OSError):
                self.module.uninstall_files(self.paths)
        self.assertTrue(self.paths.support.exists())
        marker = self.paths.support / ".installation.json"
        self.assertTrue(marker.is_file(), "marker must be restored for a rerun")
        self.assertEqual(json.loads(marker.read_bytes()), self.module.MANIFEST)
        # The rerun must recognize the remainder and finish the job.
        self.module.uninstall_files(self.paths)
        self.assertFalse(self.paths.support.exists())

    def test_corrupt_plist_is_refused_as_valueerror_before_removal(self):
        # A truncated XML LaunchAgent must be refused like any other
        # unrecognized plist, not raise an unhandled parser error past main().
        self.paths.plist.parent.mkdir(parents=True)
        # Truncated XML reaches plistlib as an expat parser error; the other
        # two reach it as InvalidFileException. All are unrecognized plists.
        for corrupt in (b'<?xml version="1.0"?><plist version="1.0"><dict><key>Label',
                        b"this is not a plist at all",
                        b"bplist00\xff\xff\xff\xff"):
            with self.subTest(corrupt=corrupt):
                self.paths.plist.write_bytes(corrupt)
                with self.assertRaises(ValueError):
                    self.module.uninstall_files(self.paths)
                self.assertEqual(self.paths.plist.read_bytes(), corrupt)

    def test_uninstall_reports_corrupt_plist_without_traceback(self):
        self.paths.plist.parent.mkdir(parents=True)
        self.paths.plist.write_bytes(b'<?xml version="1.0"?><plist version="1.0"><dict><key>Label')
        errors = io.StringIO()
        argv = ["blink_install.py", "uninstall"]
        with patch.object(sys, "argv", argv), patch.object(self.module.pwd, "getpwuid") as account, \
                patch.object(self.module.sys, "platform", "darwin"), \
                patch.object(self.module.os, "getuid", return_value=501), \
                redirect_stderr(errors):
            account.return_value = type("Account", (), {"pw_dir": str(self.home)})()
            status = self.module.main()
        self.assertEqual(status, 1)
        self.assertIn("uninstall stopped", errors.getvalue())
        self.assertTrue(self.paths.plist.exists())

    def test_log_leaf_symlinks_and_nonregular_files_are_refused_before_mutation(self):
        self.paths.logs.mkdir(parents=True)
        target = self.home / "unrelated-file"
        target.write_text("keep me")
        for filename in ("stdout.log", "stderr.log"):
            for kind in ("symlink", "directory", "fifo"):
                with self.subTest(filename=filename, kind=kind):
                    leaf = self.paths.logs / filename
                    if kind == "symlink":
                        leaf.symlink_to(target)
                    elif kind == "directory":
                        leaf.mkdir()
                    else:
                        os.mkfifo(leaf)
                    try:
                        for action in (lambda: self.module.preflight(self.paths), self.stage,
                                       lambda: self.module.uninstall_files(self.paths)):
                            with self.assertRaises(ValueError):
                                action()
                        self.assertFalse(self.paths.support.exists())
                        self.assertFalse(self.paths.plist.exists())
                        self.assertEqual(target.read_text(), "keep me")
                    finally:
                        if kind == "directory":
                            leaf.rmdir()
                        else:
                            leaf.unlink()

    def test_regular_existing_logs_are_preserved(self):
        self.paths.logs.mkdir(parents=True)
        for filename in ("stdout.log", "stderr.log"):
            (self.paths.logs / filename).write_text("existing diagnostic")
        self.module.preflight(self.paths)
        self.stage()
        for filename in ("stdout.log", "stderr.log"):
            self.assertEqual((self.paths.logs / filename).read_text(), "existing diagnostic")

    def test_conflicting_program_override_is_refused_before_mutation(self):
        self.stage()
        plist = plistlib.loads(self.paths.plist.read_bytes())
        plist["Program"] = "/other/user-program"
        original = plistlib.dumps(plist)
        self.paths.plist.write_bytes(original)
        binary = self.paths.support / "bin/blink-statusd"
        before = binary.read_bytes()
        for action in (lambda: self.module.preflight(self.paths), self.stage,
                       lambda: self.module.uninstall_files(self.paths)):
            with self.assertRaises(ValueError):
                action()
            self.assertEqual(self.paths.plist.read_bytes(), original)
            self.assertEqual(binary.read_bytes(), before)

    def test_matching_program_override_is_recognized(self):
        self.stage()
        plist = plistlib.loads(self.paths.plist.read_bytes())
        plist["Program"] = str(self.paths.support / "bin/blink-statusd")
        self.paths.plist.write_bytes(plistlib.dumps(plist))
        self.module.preflight(self.paths)
        self.module.uninstall_files(self.paths)
        self.assertFalse(self.paths.support.exists())


if __name__ == "__main__":
    unittest.main()
