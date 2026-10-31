from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_ios_artifact


class IOSArtifactTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.app = Path(temporary.name) / "Runner.app"
        self.main = {"CFBundleIdentifier": "dev.example.bridge", "CFBundleExecutable": "Runner",
                     "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"}
        self.write(self.app, self.main)

    def write(self, bundle, value):
        bundle.mkdir(parents=True, exist_ok=True)
        (bundle / value["CFBundleExecutable"]).write_bytes(b"synthetic executable, not a Mach-O test")
        with (bundle / "Info.plist").open("wb") as stream:
            plistlib.dump(value, stream)

    def cloud(self):
        self.main.update(BridgeCloudAppGroup="group.dev.example.bridge.cloud",
                         BridgePreviewKeychainGroup="fixture.dev.example.bridge.preview")
        self.write(self.app, self.main)
        self.extension = self.app / "PlugIns/BridgeNotificationService.appex"
        self.preview = {**self.main, "CFBundleIdentifier": "dev.example.bridge.BridgeNotificationService",
                        "CFBundleExecutable": "BridgeNotificationService", "CFBundlePackageType": "XPC!",
                        "NSExtension": {"NSExtensionPointIdentifier": "com.apple.usernotifications.service"}}
        self.write(self.extension, self.preview)

    def test_ordinary_and_cloud_structure(self):
        self.assertEqual(check_ios_artifact.check_app(self.app)["extensions"], 0)
        self.cloud()
        self.assertEqual(check_ios_artifact.check_app(self.app, cloud=True)["extensions"], 1)
        with self.assertRaisesRegex(ValueError, "Ordinary"):
            check_ios_artifact.check_app(self.app)

    def test_cloud_extension_is_required_and_cannot_embed_flutter(self):
        with self.assertRaisesRegex(ValueError, "exactly"):
            check_ios_artifact.check_app(self.app, cloud=True)
        self.cloud()
        (self.extension / "Frameworks/Flutter.framework").mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "Flutter"):
            check_ios_artifact.check_app(self.app, cloud=True)

    def test_versions_groups_and_extension_identity_must_match(self):
        self.cloud()
        for key, value in [("CFBundleIdentifier", "dev.other.extension"), ("CFBundleVersion", "2"),
                           ("BridgeCloudAppGroup", "group.other"), ("BridgePreviewKeychainGroup", "$(UNRESOLVED)"),
                           ("NSExtension", {"NSExtensionPointIdentifier": "other"})]:
            with self.subTest(key=key):
                self.write(self.extension, {**self.preview, key: value})
                with self.assertRaises(ValueError):
                    check_ios_artifact.check_app(self.app, cloud=True)

    def test_missing_executable_and_unresolved_versions_fail(self):
        (self.app / "Runner").unlink()
        with self.assertRaisesRegex(ValueError, "executable"):
            check_ios_artifact.check_app(self.app)
        self.write(self.app, {**self.main, "CFBundleVersion": "$(FLUTTER_BUILD_NUMBER)"})
        with self.assertRaisesRegex(ValueError, "unresolved"):
            check_ios_artifact.check_app(self.app)


if __name__ == "__main__":
    unittest.main()
