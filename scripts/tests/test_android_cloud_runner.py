import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("android_cloud_native_runner", SCRIPTS / "test_android_cloud.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class AndroidCloudRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "toolchains.json").write_text(json.dumps({"fixture": True}))
        self.source = {key: "must-not-reach-gradle" for key in (
            "UMENG_PRODUCTION_APP_KEY", "UMENG_PRODUCTION_MESSAGE_SECRET", "UMENG_PRODUCTION_CHANNEL",
            "UMENG_PUSH_APP_KEY", "UMENG_PUSH_MESSAGE_SECRET", "UMENG_PUSH_CHANNEL",
            "BRIDGE_KEYSTORE_PATH", "BRIDGE_KEYSTORE_PASSWORD", "BRIDGE_KEY_ALIAS", "BRIDGE_KEY_PASSWORD")}
        self.source.update(BRIDGE_ANDROID_PUSH="umeng", PATH="fixture-path")
        self.calls = []

    def invoke(self, failed=False):
        def run(command, **kwargs):
            self.calls.append((command, kwargs["env"].copy()))
            self.assertTrue(kwargs["check"])
            self.assertEqual(kwargs["cwd"], self.root / "android")
            if failed:
                raise subprocess.CalledProcessError(1, command)

        with patch.object(runner, "ROOT", self.root), \
             patch.object(runner, "environment", return_value=(self.source.copy(), None)), \
             patch.object(runner, "command", return_value=["gradle"]), \
             patch.object(runner.subprocess, "run", side_effect=run), patch("builtins.print"):
            runner.main()

    def test_default_then_opt_in_never_forward_real_credentials(self):
        self.invoke()
        default, opt_in = self.calls
        self.assertIn(":app:testDebugUnitTest", default[0])
        self.assertIn(":app:compileReleaseKotlin", default[0])
        self.assertNotIn("BRIDGE_ANDROID_PUSH", default[1])
        self.assertEqual(default[1], {"PATH": "fixture-path"})
        self.assertEqual(opt_in[1]["UMENG_PRODUCTION_APP_KEY"], "local-build-fixture-only")
        self.assertEqual(opt_in[1]["UMENG_PRODUCTION_MESSAGE_SECRET"], "local-build-fixture-only")
        self.assertIn(":app:compileProfileKotlin", opt_in[0])
        self.assertNotIn("must-not-reach-gradle", opt_in[1].values())
        self.assertEqual(self.source["UMENG_PRODUCTION_APP_KEY"], "must-not-reach-gradle")

    def test_first_failure_prevents_the_opt_in_check(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke(failed=True)
        self.assertEqual(len(self.calls), 1)


if __name__ == "__main__":
    unittest.main()
