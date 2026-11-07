import json
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import package_release

EXECUTABLE_MODE = 0o755
REGULAR_MODE = 0o644
ZIP_MODE_SHIFT = 16
ZIP_UNIX_SYSTEM = 3


class IOSPackagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.artifact = self.root / "bridge.ipa"
        self.info = {"CFBundleIdentifier": "dev.waken.bridgeMobile", "CFBundleExecutable": "Runner",
                     "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1.0"}
        environment = patch.dict("os.environ", {"GITHUB_REF_TYPE": "branch", "GITHUB_SHA": "fixture-commit"})
        environment.start()
        self.addCleanup(environment.stop)

    def archive(self, *, extra=None, mode=EXECUTABLE_MODE, include_info=True):
        with zipfile.ZipFile(self.artifact, "w") as archive:
            if include_info:
                archive.writestr("Payload/Runner.app/Info.plist", plistlib.dumps(self.info))
            executable = zipfile.ZipInfo("Payload/Runner.app/Runner")
            executable.create_system = ZIP_UNIX_SYSTEM
            executable.external_attr = (stat.S_IFREG | mode) << ZIP_MODE_SHIFT
            archive.writestr(executable, b"synthetic executable; not a signing test")
            if extra:
                archive.writestr(extra, b"unexpected entry")

    def test_clean_payload_is_accepted(self):
        self.archive()
        package_release.verify_ios_archive(self.artifact, "Runner")

    def test_appledouble_and_finder_metadata_are_rejected(self):
        for name in ("Payload/._Runner.app", "__MACOSX/Payload/._Runner.app",
                     "Payload/Runner.app/._Info.plist", "Payload/Runner.app/.DS_Store"):
            with self.subTest(name=name):
                self.archive(extra=name)
                with self.assertRaisesRegex(ValueError, "macOS metadata"):
                    package_release.verify_ios_archive(self.artifact, "Runner")

    def test_extra_apps_and_files_outside_payload_are_rejected(self):
        for name in ("Payload/Other.app/Info.plist", "Runner.app/Info.plist", "unexpected.txt"):
            with self.subTest(name=name):
                self.archive(extra=name)
                with self.assertRaisesRegex(ValueError, "only Payload/Runner.app"):
                    package_release.verify_ios_archive(self.artifact, "Runner")

    def test_unsafe_paths_are_rejected(self):
        for name in ("/outside.txt", "Payload/Runner.app/../../outside.txt"):
            with self.subTest(name=name):
                self.archive(extra=name)
                with self.assertRaisesRegex(ValueError, "Unsafe IPA"):
                    package_release.verify_ios_archive(self.artifact, "Runner")

    def test_missing_plist_and_executable_permissions_are_rejected(self):
        self.archive(include_info=False)
        with self.assertRaisesRegex(ValueError, "missing Info.plist"):
            package_release.verify_ios_archive(self.artifact, "Runner")
        self.archive(mode=REGULAR_MODE)
        with self.assertRaisesRegex(ValueError, "executable permissions"):
            package_release.verify_ios_archive(self.artifact, "Runner")

    def test_payload_root_cannot_be_a_regular_file(self):
        for name in ("Payload", "Payload/Runner.app"):
            with self.subTest(name=name):
                self.archive(extra=name)
                with self.assertRaisesRegex(ValueError, "directory is a file"):
                    package_release.verify_ios_archive(self.artifact, "Runner")

    def source_app(self):
        app = self.root / "build/ios/iphoneos/Runner.app"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps(self.info))
        (app / "Runner").write_bytes(b"synthetic executable; not a signing test")
        (app / "Runner").chmod(EXECUTABLE_MODE)
        return app

    def release_files(self):
        (self.root / "pubspec.yaml").write_text("version: 0.1.0+1\n")
        snapshot = self.root / "build/reports/build-snapshot.json"
        snapshot.parent.mkdir(parents=True)
        snapshot.write_text("{}\n")

    def test_rejected_archive_does_not_get_a_build_report(self):
        self.source_app()
        self.release_files()
        self.archive(extra="Payload/._Runner.app")

        def write_invalid_archive(source, artifact, execute):
            shutil.copyfile(self.artifact, artifact)

        with patch.object(package_release, "ROOT", self.root), \
             patch.object(package_release, "write_ios_archive", write_invalid_archive), \
             self.assertRaisesRegex(ValueError, "macOS metadata"):
            package_release.package_ios()
        self.assertFalse((self.root / "build/release-assets/ios-build.json").exists())

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS ditto and extended attributes")
    def test_real_ditto_reproduces_the_sidestore_failure_and_fixed_packaging_preserves_files(self):
        app = self.source_app()
        (app / "RunnerAlias").symlink_to("Runner")
        for path in (app, app / "Runner"):
            subprocess.run(["xattr", "-w", "com.bridge.ipa-test", "fixture", str(path)], check=True)
        payload = self.root / "Payload"
        payload.mkdir()
        shutil.copytree(app, payload / "Runner.app", symlinks=True)
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(payload), str(self.artifact)], check=True)
        with zipfile.ZipFile(self.artifact) as archive:
            self.assertIn("Payload/._Runner.app", archive.namelist())
        with self.assertRaisesRegex(ValueError, "macOS metadata"):
            package_release.verify_ios_archive(self.artifact, "Runner")

        package_release.write_ios_archive(app, self.artifact, subprocess.run)
        package_release.verify_ios_archive(self.artifact, "Runner")
        with zipfile.ZipFile(self.artifact) as archive:
            self.assertEqual(archive.read("Payload/Runner.app/Runner"), (app / "Runner").read_bytes())
            self.assertEqual(archive.read("Payload/Runner.app/Info.plist"), (app / "Info.plist").read_bytes())
            alias = archive.getinfo("Payload/Runner.app/RunnerAlias")
            self.assertTrue(stat.S_ISLNK(alias.external_attr >> ZIP_MODE_SHIFT))
            self.assertEqual(archive.read(alias), b"Runner")

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS ditto")
    def test_release_entrypoint_records_verified_artifact(self):
        self.source_app()
        self.release_files()
        with patch.object(package_release, "ROOT", self.root), patch("builtins.print"):
            package_release.package_ios()
        artifact = self.root / "build/release-assets/bridge-mobile-v0.1.0-ios-unsigned.ipa"
        package_release.verify_ios_archive(artifact, "Runner")
        report = json.loads((artifact.parent / "ios-build.json").read_text())
        self.assertEqual(report["sha256"], package_release.sha256(artifact))
        self.assertEqual(report["signing"], "unsigned-requires-user-signing")


if __name__ == "__main__":
    unittest.main()
