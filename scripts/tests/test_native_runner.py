import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_native


class NativeRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        target = self.root / "target"
        (target / "debug").mkdir(parents=True)
        for name in ("bridge_native.dll", "libbridge_native.dylib", "libbridge_native.so"):
            (target / "debug" / name).touch()
        for mock in (patch.object(test_native, "ROOT", self.root),
                     patch.object(test_native, "environment", return_value={}),
                     patch.object(test_native, "output", return_value=json.dumps({"target_directory": str(target)}))):
            mock.start()
            self.addCleanup(mock.stop)

    def report(self):
        return json.loads((self.root / "build/reports/native-ffi/phases.json").read_text())

    def test_startup_budget_is_separate_from_individual_test_timeout(self):
        with patch.object(test_native, "run") as execute:
            test_native.main()
        prepare, tests = execute.call_args_list[-2:]
        self.assertIn("--enforce-lockfile", prepare.args[0])
        self.assertIn("--no-pub", tests.args[0])
        self.assertIn("--timeout=60s", tests.args[0])
        self.assertGreater(tests.kwargs["timeout"], 60)
        self.assertEqual([row["status"] for row in self.report()], ["passed"] * 3)

    def test_dependency_failure_stops_before_native_test_execution(self):
        def execute(arguments, **kwargs):
            if "pub" in arguments:
                raise subprocess.CalledProcessError(1, arguments)
            self.assertNotIn("test", arguments)
        with patch.object(test_native, "run", side_effect=execute), self.assertRaises(subprocess.CalledProcessError):
            test_native.main()
        self.assertEqual(self.report()[-1]["phase"], "flutter-dependencies")
        self.assertEqual(self.report()[-1]["status"], "failed")

    def test_timeout_is_not_retried_and_preserves_partial_test_events(self):
        events = self.root / "build/reports/native-ffi/tests.jsonl"
        attempts = []
        def execute(arguments, **kwargs):
            if "test" in arguments:
                attempts.append(arguments)
                events.write_text('{"type":"testStart","test":{"name":"blocked FFI"}}\n')
                raise subprocess.TimeoutExpired(arguments, kwargs["timeout"])
        with patch.object(test_native, "run", side_effect=execute), self.assertRaises(subprocess.TimeoutExpired):
            test_native.main()
        self.assertEqual(len(attempts), 1)
        self.assertEqual(self.report()[-1]["status"], "timeout")
        self.assertIn("blocked FFI", events.read_text())

    def test_failing_test_remains_a_failure_and_stale_report_is_removed(self):
        events = self.root / "build/reports/native-ffi/tests.jsonl"
        events.parent.mkdir(parents=True)
        events.write_text('{"success":true}\n')
        def execute(arguments, **kwargs):
            if "test" in arguments:
                self.assertFalse(events.exists())
                raise subprocess.CalledProcessError(1, arguments)
        with patch.object(test_native, "run", side_effect=execute), self.assertRaises(subprocess.CalledProcessError):
            test_native.main()
        self.assertEqual(self.report()[-1]["status"], "failed")
