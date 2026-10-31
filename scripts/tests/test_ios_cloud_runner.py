import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("ios_cloud_native_runner", SCRIPTS / "test_ios_cloud.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class IOSCloudRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.commands = []
        self.linked = []

    def run_command(self, command, **kwargs):
        self.assertTrue(kwargs["check"])
        self.assertEqual(kwargs["cwd"], self.root)
        self.commands.append(command)
        if command[0] == "cargo":
            output = Path(command[command.index("--target-dir") + 1])
            host = command[command.index("--target") + 1]
            output = output / host / "debug"
            output.mkdir(parents=True)
            (output / "libbridge_preview.a").write_bytes(b"synthetic static archive")
            (output / "libbridge_preview.dylib").write_bytes(b"must not be linked")
        if "-DBRIDGE_CLOUD_PUSH" in command:
            directory = Path(next(flag[2:] for flag in command if flag.startswith("-L")))
            self.linked = sorted(path.name for path in directory.iterdir())
            self.assertEqual((directory / "libbridge_preview.a").read_bytes(), b"synthetic static archive")

    def invoke(self, run=None, host="aarch64-apple-darwin", system="Darwin", swift="swift"):
        with patch.object(runner, "ROOT", self.root), \
             patch.object(runner.platform, "system", return_value=system), \
             patch.object(runner.shutil, "which", return_value=swift), \
             patch.object(runner, "toolchain", return_value=("cargo", "rustc")), \
             patch.object(runner.subprocess, "check_output", return_value=f"rustc 1.99.1\nhost: {host}\n"), \
             patch.object(runner.subprocess, "run", side_effect=run or self.run_command), patch("builtins.print"):
            runner.main()

    def test_order_locked_host_and_separate_swift_scratch_paths(self):
        self.invoke()
        ordinary, cargo, native = self.commands
        self.assertEqual([command[0] for command in self.commands], ["swift", "cargo", "swift"])
        self.assertNotIn("-DBRIDGE_CLOUD_PUSH", ordinary)
        self.assertIn("--locked", cargo)
        self.assertIn(str(self.root / "rust_preview/Cargo.toml"), cargo)
        self.assertNotIn(str(self.root / "rust/Cargo.toml"), cargo)
        self.assertEqual(cargo[cargo.index("--target") + 1], "aarch64-apple-darwin")
        self.assertNotEqual(ordinary[ordinary.index("--scratch-path") + 1],
                            native[native.index("--scratch-path") + 1])
        self.assertIn(f"-I{self.root / 'ios/CloudPreviewFFI'}", native)
        self.assertIn("-liconv", native)
        self.assertEqual(self.linked, ["libbridge_preview.a"])

    def test_intel_macos_host_is_explicit(self):
        self.invoke(host="x86_64-apple-darwin")
        self.assertIn("x86_64-apple-darwin", self.commands[1])

    def test_non_macos_missing_swift_and_non_host_target_fail_closed(self):
        for options in [{"system": "Windows"}, {"swift": None}, {"host": "aarch64-apple-ios"}]:
            with self.subTest(options=options), self.assertRaises(SystemExit):
                self.invoke(**options)
        self.assertEqual(self.commands, [])

    def test_pinned_toolchain_failure_prevents_any_build(self):
        with patch.object(runner.platform, "system", return_value="Darwin"), \
             patch.object(runner.shutil, "which", return_value="swift"), \
             patch.object(runner, "toolchain", side_effect=SystemExit("repository-pinned")), \
             patch.object(runner.subprocess, "run") as run, self.assertRaisesRegex(SystemExit, "repository-pinned"):
            runner.main()
        run.assert_not_called()

    def test_each_failed_command_stops_the_remaining_checks(self):
        for failed in range(3):
            self.commands = []

            def fail(command, **kwargs):
                self.run_command(command, **kwargs)
                if len(self.commands) == failed + 1:
                    raise subprocess.CalledProcessError(7, command)

            with self.subTest(failed=failed), self.assertRaises(subprocess.CalledProcessError):
                self.invoke(run=fail)
            self.assertEqual(len(self.commands), failed + 1)

    def test_missing_archive_cannot_fall_back_to_the_dylib(self):
        def omit_archive(command, **kwargs):
            self.run_command(command, **kwargs)
            if command[0] == "cargo":
                directory = Path(command[command.index("--target-dir") + 1])
                host = command[command.index("--target") + 1]
                (directory / host / "debug/libbridge_preview.a").unlink()

        with self.assertRaises(FileNotFoundError):
            self.invoke(run=omit_archive)
        self.assertEqual(len(self.commands), 2)


if __name__ == "__main__":
    unittest.main()
