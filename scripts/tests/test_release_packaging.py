import base64
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_release_android
import package_release


class ReleasePackagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "pubspec.yaml").write_text("version: 0.1.0+1\n")
        self.patch = patch.object(package_release, "ROOT", self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.env = patch.dict(os.environ, {"GITHUB_SHA": "fixture-commit", "GITHUB_REF_TYPE": "branch"})
        self.env.start()
        self.addCleanup(self.env.stop)

    def fixtures(self):
        for platform, suffix, signing in (("android", "android.apk", "release"),
                                          ("ios", "ios-unsigned.ipa", "unsigned-requires-user-signing")):
            artifact = package_release.assets() / f"bridge-mobile-v0.1.0-{suffix}"
            artifact.write_bytes(b"synthetic package")
            report = {"tag": "v0.1.0", "commit": "fixture-commit", "artifact": artifact.name,
                      "signing": signing, "sha256": package_release.sha256(artifact)}
            (package_release.assets() / f"{platform}-build.json").write_text(json.dumps(report))

    def test_tag_cannot_publish_a_different_package_version(self):
        with patch.dict(os.environ, {"GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": "v0.2.0"}):
            with self.assertRaisesRegex(ValueError, "Git tag"):
                package_release.version()

    def test_manifest_requires_both_artifacts_from_this_commit(self):
        self.fixtures()
        with patch("builtins.print"):
            package_release.manifest()
        sums = (package_release.assets() / "SHA256SUMS.txt").read_text()
        self.assertEqual(len(sums.splitlines()), 4)
        with patch.dict(os.environ, {"GITHUB_SHA": "another-commit"}):
            with self.assertRaisesRegex(ValueError, "does not match"):
                package_release.manifest()

    def test_changed_artifact_cannot_reuse_a_build_report(self):
        self.fixtures()
        (package_release.assets() / "bridge-mobile-v0.1.0-ios-unsigned.ipa").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "ios artifact"):
            package_release.manifest()

    def test_missing_platform_prevents_publication(self):
        self.fixtures()
        (package_release.assets() / "bridge-mobile-v0.1.0-ios-unsigned.ipa").unlink()
        with self.assertRaises(FileNotFoundError):
            package_release.manifest()

    def test_missing_signing_secret_stops_before_android_build(self):
        calls = []
        with self.assertRaisesRegex(RuntimeError, "all four"):
            build_release_android.build({"BRIDGE_PUBLISH": "true"}, lambda *a, **kw: calls.append(a))
        self.assertFalse(calls)

    def test_ordinary_ci_does_not_pass_release_secrets_to_build(self):
        env = {name: "fixture" for name in build_release_android.SIGNING}
        env["BRIDGE_KEYSTORE_PATH"] = "unrelated"
        calls = []
        build_release_android.build(env, lambda *a, **kw: calls.append(kw["env"]))
        self.assertFalse(any(key.startswith("BRIDGE_KEY") for key in calls[0]))

    def test_release_key_exists_only_for_build_and_is_not_logged(self):
        env = {name: "fixture" for name in build_release_android.SIGNING}
        env.update(BRIDGE_PUBLISH="true", BRIDGE_KEYSTORE_BASE64=base64.b64encode(b"test key").decode())
        keys = []

        def execute(*args, **kwargs):
            key = Path(kwargs["env"]["BRIDGE_KEYSTORE_PATH"])
            self.assertEqual(key.read_bytes(), b"test key")
            self.assertNotIn("BRIDGE_KEYSTORE_BASE64", kwargs["env"])
            keys.append(key)

        with patch.object(build_release_android, "package_android") as package:
            build_release_android.build(env, execute)
            package.assert_called_once_with()
        self.assertFalse(keys[0].exists())

    def ios_fixture(self, cloud=False):
        app = self.root / "build/ios/iphoneos/Runner.app"
        info = {"CFBundleIdentifier": "dev.waken.bridgeMobile", "CFBundleExecutable": "Runner",
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}
        if cloud:
            info.update(BridgeCloudAppGroup="group.dev.waken.bridgeMobile.cloud",
                        BridgePreviewKeychainGroup="FIXTURE.dev.waken.bridgeMobile.preview")
        self.write_bundle(app, info)
        framework = app / "Frameworks/App.framework"
        self.write_bundle(framework, {**info, "CFBundleExecutable": "App", "CFBundlePackageType": "FMWK"})
        if cloud:
            self.write_bundle(app / "PlugIns/BridgeNotificationService.appex", {
                **info, "CFBundleIdentifier": "dev.waken.bridgeMobile.BridgeNotificationService",
                "CFBundleExecutable": "BridgeNotificationService", "CFBundlePackageType": "XPC!",
                "NSExtension": {"NSExtensionPointIdentifier": "com.apple.usernotifications.service"},
            })
        report = self.root / "build/reports/build-snapshot.json"
        report.parent.mkdir(parents=True)
        report.write_text(json.dumps({"fixture": True}))
        return app

    @staticmethod
    def write_bundle(bundle, info):
        bundle.mkdir(parents=True)
        (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
        (bundle / info["CFBundleExecutable"]).write_bytes(b"synthetic executable")

    @staticmethod
    def fake_ditto(arguments, check):
        payload, output = Path(arguments[-2]), Path(arguments[-1])
        with zipfile.ZipFile(output, "w") as archive:
            for path in payload.rglob("*"):
                if path.is_file():
                    entry = zipfile.ZipInfo(path.relative_to(payload.parent).as_posix())
                    entry.external_attr = (0o100644 if path.suffix == ".plist" or path.name == "App" else 0o100755) << 16
                    archive.writestr(entry, path.read_bytes())

    def test_cloud_ipa_keeps_notification_extension_and_identifies_unsigned_variant(self):
        self.ios_fixture(cloud=True)
        with patch.object(package_release.subprocess, "run", side_effect=self.fake_ditto), patch("builtins.print"):
            package_release.package_ios("cloud")
        report = json.loads((package_release.assets() / "ios-cloud-build.json").read_text())
        self.assertEqual(report["artifact"], "bridge-mobile-v0.1.0-ios-cloud-unsigned.ipa")
        self.assertEqual(report["signing"], "unsigned-requires-user-signing")
        self.assertEqual(report["flavor"], "cloud")
        self.assertEqual(report["commit"], "fixture-commit")
        self.assertEqual(report["app_verification"]["extensions"], 1)
        artifact = package_release.assets() / report["artifact"]
        self.assertEqual(report["sha256"], package_release.sha256(artifact))
        with zipfile.ZipFile(artifact) as archive:
            for executable in ("Runner",
                               "PlugIns/BridgeNotificationService.appex/BridgeNotificationService"):
                entry = archive.getinfo("Payload/Runner.app/" + executable)
                self.assertTrue((entry.external_attr >> 16) & 0o111)
            self.assertEqual(archive.getinfo("Payload/Runner.app/Frameworks/App.framework/App").external_attr >> 16,
                             0o100644)

    def test_ordinary_ipa_cannot_be_mislabeled_as_cloud(self):
        self.ios_fixture()
        with patch.object(package_release.subprocess, "run") as ditto:
            with self.assertRaisesRegex(ValueError, "Cloud iOS artifact"):
                package_release.package_ios("cloud")
            ditto.assert_not_called()
        with patch.object(package_release.subprocess, "run", side_effect=self.fake_ditto), patch("builtins.print"):
            package_release.package_ios()
        self.assertTrue((package_release.assets() / "bridge-mobile-v0.1.0-ios-unsigned.ipa").is_file())

    def test_cloud_cannot_be_packaged_as_ordinary_and_versions_must_match(self):
        app = self.ios_fixture(cloud=True)
        with patch.object(package_release.subprocess, "run") as ditto:
            with self.assertRaisesRegex(ValueError, "Ordinary"):
                package_release.package_ios()
            for bundle in (app, app / "PlugIns/BridgeNotificationService.appex"):
                info = plistlib.loads((bundle / "Info.plist").read_bytes())
                info["CFBundleVersion"] = "99"
                (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, "identity/version"):
                package_release.package_ios("cloud")
            ditto.assert_not_called()

    def test_extension_executable_permissions_are_required(self):
        self.ios_fixture(cloud=True)

        def broken_ditto(arguments, check):
            self.fake_ditto(arguments, check)
            output = Path(arguments[-1])
            with zipfile.ZipFile(output) as archive:
                entries = [(entry, archive.read(entry)) for entry in archive.infolist()]
            with zipfile.ZipFile(output, "w") as archive:
                for entry, data in entries:
                    if entry.filename.endswith(".appex/BridgeNotificationService"):
                        entry.external_attr = 0o100644 << 16
                    archive.writestr(entry, data)

        with patch.object(package_release.subprocess, "run", side_effect=broken_ditto):
            with self.assertRaisesRegex(ValueError, "executable permissions"):
                package_release.package_ios("cloud")
        self.assertFalse((package_release.assets() / "ios-cloud-build.json").exists())


if __name__ == "__main__":
    unittest.main()
