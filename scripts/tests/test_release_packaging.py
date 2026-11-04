import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
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


if __name__ == "__main__":
    unittest.main()
