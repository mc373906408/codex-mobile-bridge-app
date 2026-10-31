import copy
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_ios_preview
import check_ios_cloud
from ios_project import parse_project


class OpenStepTests(unittest.TestCase):
    def test_comments_quoted_keys_arrays_and_escapes(self):
        value = parse_project('// !$*UTF8*$!\n{ /* x */ "key[sdk=x*]" = (one, "two\\nthree",); }')
        self.assertEqual(value, {"key[sdk=x*]": ["one", "two\nthree"]})

    def test_duplicate_keys_and_truncation_are_errors(self):
        for text in ('{a=one;a=two;}', '{a=(one two);}', '{a=(', '{', '{} tail'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_project(text)


class XcodeContractTests(unittest.TestCase):
    def setUp(self):
        source = check_ios_cloud.ROOT / "ios/Runner.xcodeproj/project.pbxproj"
        self.data = parse_project(source.read_text(encoding="utf-8"))
        self.project = check_ios_cloud.Project(check_ios_cloud.ROOT, self.data)

    def test_current_project_isolated_cloud_graph(self):
        self.assertEqual(check_ios_cloud.check_project()["preview_producers"], 1)

    def test_shared_swift_language_covers_every_project_configuration(self):
        configurations = self.project.configurations(self.project.project)
        versions = {configuration["buildSettings"]["SWIFT_VERSION"]
                    for configuration in configurations.values()}
        self.assertEqual(versions, {"5.0"})
        _, ordinary = self.project.target("Runner")
        profile = self.project.configurations(ordinary)["Profile"]
        self.assertEqual(self.project.path(profile["baseConfigurationReference"]),
                         check_ios_cloud.ROOT / "ios/Flutter/Profile.xcconfig")

    def test_missing_source_reference_is_rejected(self):
        _, extension = self.project.target("BridgeNotificationService")
        phase = self.project.phases(extension, "PBXSourcesBuildPhase")[0]
        reference = self.project.files(phase)[0]
        del self.data["objects"][reference]
        with self.assertRaisesRegex(ValueError, "Dangling"):
            check_ios_cloud.check_project(data=self.data)

    def test_missing_cloud_dependency_is_rejected(self):
        _, cloud = self.project.target("RunnerCloud")
        cloud["dependencies"] = []
        with self.assertRaisesRegex(ValueError, "explicitly depend"):
            check_ios_cloud.check_project(data=self.data)

    def test_duplicate_rust_producer_is_rejected(self):
        producer = next(phase for phase in self.data["objects"].values()
                        if "build_ios_preview.py" in phase.get("shellScript", ""))
        self.data["objects"]["BADPRODUCER"] = copy.deepcopy(producer)
        with self.assertRaisesRegex(ValueError, "exactly one producer"):
            check_ios_cloud.check_project(data=self.data)

    def test_default_preview_linkage_is_rejected(self):
        _, ordinary = self.project.target("Runner")
        self.project.configurations(ordinary)["Release"]["buildSettings"]["OTHER_LDFLAGS"] = ["-lbridge_preview"]
        with self.assertRaisesRegex(ValueError, "must not enable or link"):
            check_ios_cloud.check_project(data=self.data)

    def test_extension_cannot_compile_flutter_or_account_sources(self):
        _, ordinary = self.project.target("Runner")
        _, extension = self.project.target("BridgeNotificationService")
        normal = self.project.phases(ordinary, "PBXSourcesBuildPhase")[0]
        extension_phase = self.project.phases(extension, "PBXSourcesBuildPhase")[0]
        extension_phase["files"].extend(normal["files"])
        with self.assertRaisesRegex(ValueError, "Duplicate source|preview-only"):
            check_ios_cloud.check_project(data=self.data)

    def test_embed_after_thin_is_rejected(self):
        _, cloud = self.project.target("RunnerCloud")
        embed = next(identity for identity in cloud["buildPhases"]
                     if self.data["objects"][identity].get("name") == "Embed App Extensions")
        cloud["buildPhases"].remove(embed)
        cloud["buildPhases"].append(embed)
        with self.assertRaisesRegex(ValueError, "before Flutter Thin Binary"):
            check_ios_cloud.check_project(data=self.data)


class PreviewBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.products = self.root / "products"
        self.environment = {"TARGET_NAME": "BridgeNotificationService", "CONFIGURATION": "Release-cloud",
                            "PLATFORM_NAME": "iphoneos", "ARCHS": "arm64", "BUILT_PRODUCTS_DIR": str(self.products),
                            "PATH": os.environ["PATH"]}
        self.commands = []

    def run_command(self, command, **kwargs):
        self.commands.append(command)
        if "--target" in command:
            target = command[command.index("--target") + 1]
            folder = Path(command[command.index("--target-dir") + 1])
            library = folder / target / ("release" if "--release" in command else "debug") / "libbridge_preview.a"
            library.parent.mkdir(parents=True, exist_ok=True)
            library.write_bytes(b"synthetic archive")
        if "-output" in command:
            Path(command[command.index("-output") + 1]).write_bytes(b"synthetic universal archive")

    def invoke(self, run=None, version=None):
        version = version or (lambda command, **_: f"{Path(command[0]).name} 1.99.1 (fixture)")

        def capture(command, **kwargs):
            return command[-1] if "which" in command else version(command, **kwargs)

        with patch.dict(os.environ, self.environment, clear=True), patch.object(build_ios_preview, "ROOT", self.root), \
             patch.object(build_ios_preview, "command", return_value=["rustup"]), \
             patch.object(build_ios_preview.subprocess, "check_output", side_effect=capture), \
             patch.object(build_ios_preview.subprocess, "run", side_effect=run or self.run_command):
            build_ios_preview.main()

    def test_architecture_mapping_and_deduplication(self):
        self.assertEqual(build_ios_preview.rust_targets("iphoneos", ["arm64", "arm64"]), ["aarch64-apple-ios"])
        self.assertEqual(build_ios_preview.rust_targets("iphonesimulator", ["arm64", "x86_64"]),
                         ["aarch64-apple-ios-sim", "x86_64-apple-ios"])
        for platform, architectures in [("macosx", ["arm64"]), ("iphoneos", ["x86_64"]), ("iphoneos", [])]:
            with self.subTest(platform=platform), self.assertRaises(ValueError):
                build_ios_preview.rust_targets(platform, architectures)

    def test_release_build_is_locked_atomic_and_preview_only(self):
        self.invoke()
        cargo = self.commands[0]
        self.assertIn("--locked", cargo)
        self.assertIn(str(self.root / "rust_preview/Cargo.toml"), cargo)
        self.assertIn("--release", cargo)
        self.assertEqual((self.products / "bridge-preview/libbridge_preview.a").read_bytes(), b"synthetic universal archive")
        self.assertFalse(list((self.products / "bridge-preview").glob(".libbridge_preview-*.a")))

    def test_debug_simulator_build_combines_both_architectures(self):
        self.environment.update(CONFIGURATION="Debug-cloud", PLATFORM_NAME="iphonesimulator", ARCHS="arm64 x86_64")
        self.invoke()
        self.assertEqual(len(self.commands), 3)
        self.assertTrue(all("--release" not in command for command in self.commands[:2]))
        self.assertIn("aarch64-apple-ios-sim", self.commands[0])
        self.assertIn("x86_64-apple-ios", self.commands[1])

    def test_future_stable_compilers_are_not_rejected_by_an_old_pin(self):
        self.invoke(version=lambda command, **_: f"{command[0]} 1.100.0 (fixture)")
        self.assertEqual(self.commands[0][0], "cargo")

    def test_lipo_failure_preserves_old_output_and_cleans_temporary(self):
        library = self.products / "bridge-preview/libbridge_preview.a"
        library.parent.mkdir(parents=True)
        library.write_bytes(b"old good archive")

        def fail_lipo(command, **kwargs):
            self.run_command(command, **kwargs)
            if "lipo" in command:
                raise subprocess.CalledProcessError(1, command)

        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke(run=fail_lipo)
        self.assertEqual(library.read_bytes(), b"old good archive")
        self.assertFalse(list(library.parent.glob(".libbridge_preview-*.a")))

    def test_wrong_target_configuration_path_and_compiler_fail_closed(self):
        for change in [{"TARGET_NAME": "Runner"}, {"CONFIGURATION": "Release"},
                       {"BUILT_PRODUCTS_DIR": "relative"}, {"BUILT_PRODUCTS_DIR": self.root.anchor}]:
            with self.subTest(change=change), patch.dict(self.environment, change), self.assertRaises(SystemExit):
                self.invoke()
        with self.assertRaisesRegex(SystemExit, "matching stable"):
            self.invoke(version=lambda command, **_: f"{command[0]} {'1.99.1' if command[0] == 'cargo' else '1.98.0'}")
        self.assertEqual(self.commands, [])


if __name__ == "__main__":
    unittest.main()
