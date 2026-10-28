import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bootstrap_android
import build_android


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.local = Path(self.temporary.name) / ".local"
        self.patcher = patch.object(bootstrap_android, "LOCAL", self.local)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        self.content = b"synthetic download bytes"
        self.package = {
            "url": "https://example.invalid/tool%2B1.jar",
            "sha256": hashlib.sha256(self.content).hexdigest(),
        }

    def test_verifies_download_and_reuses_only_matching_hash(self):
        with patch.object(bootstrap_android, "fetch", return_value=io.BytesIO(self.content)) as fetch:
            target = bootstrap_android.download(self.package)
        fetch.assert_called_once()
        self.assertEqual(target.name, "tool+1.jar")
        self.assertEqual(target.read_bytes(), self.content)
        with patch.object(bootstrap_android, "fetch") as fetch:
            self.assertEqual(bootstrap_android.download(self.package), target)
        fetch.assert_not_called()

    def test_bad_download_never_replaces_cached_artifact(self):
        folder = self.local / "downloads"
        folder.mkdir(parents=True)
        target = folder / "tool+1.jar"
        target.write_bytes(b"old synthetic file")
        with patch.object(bootstrap_android, "fetch", return_value=io.BytesIO(b"corrupted")):
            with self.assertRaisesRegex(RuntimeError, "Checksum mismatch"):
                bootstrap_android.download(self.package)
        self.assertEqual(target.read_bytes(), b"old synthetic file")

    def test_extraction_removes_only_archive_root(self):
        archive = Path(self.temporary.name) / "synthetic.zip"
        with zipfile.ZipFile(archive, "w") as file:
            file.writestr("upstream/bin/tool.txt", "synthetic")
        target = self.local / "tools"
        bootstrap_android.extract_without_root(archive, target)
        self.assertEqual((target / "bin/tool.txt").read_text(), "synthetic")

    def test_extraction_rejects_path_traversal(self):
        archive = Path(self.temporary.name) / "synthetic.zip"
        with zipfile.ZipFile(archive, "w") as file:
            file.writestr("upstream/../../outside.txt", "unsafe")
        with self.assertRaisesRegex(RuntimeError, "Unsafe archive"):
            bootstrap_android.extract_without_root(archive, self.local / "tools")
        self.assertFalse((Path(self.temporary.name) / "outside.txt").exists())

    def test_extraction_rejects_external_destination(self):
        with self.assertRaisesRegex(RuntimeError, "project's .local"):
            bootstrap_android.extract_without_root(Path("unused.zip"), Path(self.temporary.name) / "outside")


class AndroidEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sdk, self.java = self.root / "sdk", self.root / "jdk"
        self.versions = {"android_build_tools": "36.0.0", "android_compile_sdk": 36, "android_ndk": "28.2.13676358"}
        self.suffix = ".exe" if os.name == "nt" else ""
        for file in (self.sdk / f"build-tools/36.0.0/zipalign{self.suffix}", self.sdk / "platforms/android-36/android.jar",
                     self.sdk / "ndk/28.2.13676358/source.properties", self.java / f"bin/java{self.suffix}"):
            file.parent.mkdir(parents=True, exist_ok=True)
            file.touch()
        self.env = {"PATH": os.environ.get("PATH", ""), "JAVA_HOME": str(self.java), "ANDROID_SDK_ROOT": str(self.sdk)}
        self.patcher = patch.object(build_android, "ROOT", self.root)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def test_normalizes_sdk_variables_and_keeps_global_environment_unchanged(self):
        with patch.dict(os.environ, self.env, clear=True):
            env, zipalign = build_android.environment(self.versions)
            self.assertNotIn("ANDROID_HOME", os.environ)
        self.assertEqual(env["ANDROID_HOME"], str(self.sdk))
        self.assertEqual(env["ANDROID_SDK_ROOT"], str(self.sdk))
        self.assertTrue(zipalign.is_file())

    def test_refuses_unverified_bootstrap_marker(self):
        marker = self.root / ".local/android-env.json"
        marker.parent.mkdir()
        marker.write_text(json.dumps({"java_home": str(self.java), "android_home": str(self.sdk)}))
        with patch.dict(os.environ, self.env, clear=True), self.assertRaisesRegex(RuntimeError, "not verified"):
            build_android.environment(self.versions)

    def test_refuses_missing_ndk(self):
        (self.sdk / "ndk/28.2.13676358/source.properties").unlink()
        with patch.dict(os.environ, self.env, clear=True), self.assertRaisesRegex(RuntimeError, "Missing Android"):
            build_android.environment(self.versions)

    def test_only_forwards_a_local_style_unauthenticated_http_proxy(self):
        for value in ("socks5://127.0.0.1:1080", "http://user:synthetic@127.0.0.1:1080"):
            with self.subTest(proxy=value), patch.dict(os.environ, {**self.env, "HTTPS_PROXY": value}, clear=True):
                with self.assertRaisesRegex(RuntimeError, "unauthenticated HTTP proxy"):
                    build_android.environment(self.versions)
        with patch.dict(os.environ, {**self.env, "HTTPS_PROXY": "http://127.0.0.1:10808"}, clear=True):
            env, _ = build_android.environment(self.versions)
        self.assertIn("-Dhttps.proxyHost=127.0.0.1", env["JAVA_TOOL_OPTIONS"])
        self.assertIn("-Dhttp.nonProxyHosts=localhost|127.*", env["JAVA_TOOL_OPTIONS"])


if __name__ == "__main__":
    unittest.main()
