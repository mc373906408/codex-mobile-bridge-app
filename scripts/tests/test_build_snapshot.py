import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_build_snapshot


class BuildSnapshotTests(unittest.TestCase):
    def test_verification_records_versions_without_upgrade_or_regeneration(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            calls = []
            def capture(arguments, **kwargs):
                calls.append(arguments)
                return json.dumps({'frameworkVersion': 'fixture'}) if arguments[0] == 'flutter' else 'fixture'
            with patch.object(verify_build_snapshot, 'ROOT', root), \
                 patch.object(verify_build_snapshot, 'check', return_value=0), \
                 patch.object(verify_build_snapshot, 'manifest', return_value={'file': 'hash'}), \
                 patch.object(verify_build_snapshot, 'output', side_effect=capture), \
                 patch.object(verify_build_snapshot, 'run', side_effect=lambda args, **_: calls.append(args)):
                verify_build_snapshot.main()
            self.assertTrue((root / 'build/reports/build-snapshot.json').is_file())
            self.assertTrue(any('--enforce-lockfile' in call for call in calls))
            self.assertEqual(sum('--locked' in call for call in calls), 2)
            self.assertFalse(any(word in call for call in calls for word in ('upgrade', 'update', 'generate')))

    def test_changed_dependency_snapshot_fails_before_a_success_report(self):
        with patch.object(verify_build_snapshot, 'check', return_value=0), \
             patch.object(verify_build_snapshot, 'manifest', side_effect=[{'file': 'old'}, {'file': 'new'}]), \
             patch.object(verify_build_snapshot, 'run'), patch.object(verify_build_snapshot, 'output', return_value='{}'):
            with self.assertRaisesRegex(RuntimeError, 'changed during snapshot'):
                verify_build_snapshot.main()
