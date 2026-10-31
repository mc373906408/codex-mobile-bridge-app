from functools import partial
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_toolchains
import prepare_build
import test_rust

BRIDGE_VERSION = "99.0.0"
SDK_VERSION = "100.0.0"


class ToolchainPolicyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        rust = self.root / "rust"
        rust.mkdir()
        (rust / "Cargo.lock").write_text(
            f'[[package]]\nname = "flutter_rust_bridge"\nversion = "{BRIDGE_VERSION}"\n')
        (rust / "Cargo.toml").write_text('[dependencies]\nflutter_rust_bridge = "*"\n')
        (self.root / "pubspec.lock").write_text(
            f'packages:\n  flutter_rust_bridge:\n    dependency: "direct main"\n    version: "{BRIDGE_VERSION}"\n')
        (self.root / "pubspec.yaml").write_text('dependencies:\n  flutter_rust_bridge: any\n')
        (self.root / "rust-toolchain.toml").write_text('[toolchain]\nchannel = "stable"\n')
        (self.root / ".fvmrc").write_text(json.dumps({"flutter": "stable"}))
        policy = {"flutter": "stable", "dart": "bundled", "rust": "stable", "flutter_rust_bridge": "latest"}
        (self.root / "toolchains.json").write_text(json.dumps(policy))

    def capture(self, arguments, codegen=BRIDGE_VERSION):
        if arguments[0] == "flutter":
            return json.dumps({"frameworkVersion": SDK_VERSION, "dartSdkVersion": SDK_VERSION, "channel": "stable"})
        version = codegen if arguments[0] == "flutter_rust_bridge_codegen" else SDK_VERSION
        return f"{arguments[0]} {version} (fixture)"

    def test_future_stable_sdk_and_bridge_versions_are_accepted(self):
        with patch("builtins.print"):
            self.assertEqual(check_toolchains.check(self.root, self.capture), 0)

    def test_codegen_must_match_the_resolved_bridge_release(self):
        with patch("builtins.print"):
            self.assertEqual(check_toolchains.check(self.root, partial(self.capture, codegen="98.0.0")), 1)

    def test_dart_and_rust_bridge_mismatch_is_an_explicit_error(self):
        (self.root / "pubspec.lock").write_text('packages:\n  flutter_rust_bridge:\n    version: "98.0.0"\n')
        with self.assertRaisesRegex(RuntimeError, "same flutter_rust_bridge release"):
            check_toolchains.bridge_version(self.root)

    def test_missing_dart_bridge_does_not_match_a_different_package(self):
        text = 'packages:\n  flutter_rust_bridge:\n    dependency: "direct main"\n'
        (self.root / "pubspec.lock").write_text(text + f'  another:\n    version: "{BRIDGE_VERSION}"\n')
        with self.assertRaises(RuntimeError):
            check_toolchains.bridge_version(self.root)

    def test_preparation_refreshes_before_installing_matching_codegen(self):
        calls = []
        prepare_build.prepare(self.root, lambda arguments, **kwargs: calls.append((arguments, kwargs)))
        arguments = [call[0] for call in calls]
        self.assertEqual(arguments[0][-2:], ["channel", "stable"])
        self.assertEqual(arguments[1][-1], "upgrade")
        self.assertEqual(arguments[2], ["rustup", "update", "stable"])
        dependency_calls = [call for call in arguments if "pub" in call]
        self.assertTrue(all("upgrade" in call and "get" not in call for call in dependency_calls))
        cargo_updates = [call for call in arguments if call[:3] == ["cargo", "+stable", "update"]]
        self.assertEqual(len(cargo_updates), 2)
        install = next(call for call in arguments if "install" in call and "flutter_rust_bridge_codegen" in call)
        self.assertEqual(install[install.index("--version") + 1], BRIDGE_VERSION)
        self.assertEqual(arguments[-4], ["flutter_rust_bridge_codegen", "generate"])
        self.assertTrue(all(call[:3] == ["cargo", "+stable", "fmt"] for call in arguments[-3:-1]))

    def test_refresh_failure_does_not_continue_with_old_dependencies(self):
        calls = []

        def fail(arguments, **kwargs):
            calls.append(arguments)
            raise subprocess.CalledProcessError(1, arguments)

        with self.assertRaises(subprocess.CalledProcessError):
            prepare_build.prepare(self.root, fail)
        self.assertEqual(len(calls), 1)

    def test_generator_does_not_reintroduce_pins_or_skip_parse_errors(self):
        config = (prepare_build.ROOT / "flutter_rust_bridge.yaml").read_text()
        self.assertIn("auto_upgrade_dependency: false", config)
        self.assertIn("stop_on_error: true", config)


class RustTestTimeoutTests(unittest.TestCase):
    def test_timeout_applies_to_running_tests_not_compilation(self):
        calls = []
        test_rust.test("rust/Cargo.toml", lambda arguments, **kwargs: calls.append((arguments, kwargs)))
        self.assertIn("--no-run", calls[0][0])
        self.assertNotIn("timeout", calls[0][1])
        self.assertNotIn("--no-run", calls[1][0])
        self.assertEqual(calls[1][1]["timeout"], test_rust.TEST_TIMEOUT_SECONDS)


if __name__ == "__main__":
    unittest.main()
