from argparse import Namespace
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_ios


class IOSBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.ipa = self.root / "build/ios/ipa/bridge.ipa"
        self.args = Namespace(compile_only=False, flavor=None, export_method="development", export_options_plist=None)
        self.calls = []
        self.patcher = patch.object(build_ios, "ROOT", self.root)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def execute(self, arguments):
        self.calls.append(arguments)

    def test_missing_export_is_not_reported_as_success(self):
        with self.assertRaisesRegex(RuntimeError, "did not export a new IPA"):
            build_ios.build(self.args, self.execute)
        self.assertEqual(self.calls[1][0:2], ["pod", "update"])
        self.assertEqual(self.calls[2][3:5], ["build", "ipa"])
        self.assertNotIn("--no-codesign", self.calls[2])

    def test_stale_ipa_is_not_accepted(self):
        self.ipa.parent.mkdir(parents=True)
        self.ipa.write_bytes(b"old test fixture")
        with self.assertRaisesRegex(RuntimeError, "new IPA"):
            build_ios.build(self.args, self.execute)

    def test_export_failure_never_falls_back_to_unsigned_build(self):
        def fail(arguments):
            self.execute(arguments)
            if "ipa" in arguments:
                raise subprocess.CalledProcessError(1, arguments)

        with self.assertRaises(subprocess.CalledProcessError):
            build_ios.build(self.args, fail)
        self.assertEqual(len(self.calls), 3)
        self.assertTrue(all("--no-codesign" not in call for call in self.calls))

    def test_compile_gate_requires_the_explicit_flag(self):
        self.args.compile_only = True
        with patch.object(build_ios, "check_app", return_value={}) as check, patch("builtins.print"):
            build_ios.build(self.args, self.execute)
        self.assertIn("ios", self.calls[2])
        self.assertIn("--no-codesign", self.calls[2])
        self.assertTrue(all("ipa" not in call for call in self.calls))
        check.assert_called_once_with(self.root / "build/ios/iphoneos/Runner.app", cloud=False)

    def test_export_plist_is_not_combined_with_export_method(self):
        self.args.export_options_plist = self.root / "ExportOptions.plist"
        with self.assertRaises(RuntimeError):
            build_ios.build(self.args, self.execute)
        self.assertIn("--export-options-plist", self.calls[2])
        self.assertNotIn("--export-method", self.calls[2])

    def test_archive_traversal_is_rejected(self):
        archive = self.root / "unsafe.ipa"
        with zipfile.ZipFile(archive, "w") as source:
            source.writestr("../outside.txt", "unsafe")
        destination = self.root / "extract"
        destination.mkdir()
        with self.assertRaisesRegex(ValueError, "Unsafe IPA"):
            build_ios.extract_archive(archive, destination)
        self.assertFalse((self.root / "outside.txt").exists())

    def test_signature_failure_prevents_a_success_report(self):
        archive = self.root / "unsigned.ipa"
        with zipfile.ZipFile(archive, "w") as source:
            source.writestr("Payload/Runner.app/fixture", "not a signed binary")

        def fail(arguments):
            raise subprocess.CalledProcessError(1, arguments)

        with patch.object(build_ios, "check_app", return_value={"bundle_id": "test.fixture"}), \
             patch("builtins.print") as report, self.assertRaises(subprocess.CalledProcessError):
            build_ios.verify_ipa(archive, fail, False)
        report.assert_not_called()


if __name__ == "__main__":
    unittest.main()
