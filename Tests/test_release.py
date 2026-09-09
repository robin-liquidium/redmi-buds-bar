import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', Path(__file__).parents[1] / 'script/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseSafetyTests(unittest.TestCase):
    def test_ambiguous_submission_persists_intent_without_retrying(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'notary-app.zip'
            archive.write_bytes(b'signed archive')
            state = {}
            events = []
            def save(tag, current):
                events.append(current.copy())
            with patch.object(release, 'save', side_effect=save), patch.object(release, 'notary', side_effect=subprocess.CalledProcessError(1, 'notarytool')) as api:
                with self.assertRaises(subprocess.CalledProcessError):
                    release.submit('v0.1.0', state, 'app', archive)
            self.assertEqual(events[0]['phase'], 'app_submitting')
            self.assertEqual(events[0]['app_sha256'], release.digest(archive))
            self.assertNotIn('app_submission_id', state)
            self.assertEqual(api.call_count, 1)

    def test_processing_is_not_acceptance(self):
        state = {'app_submission_id': 'submission', 'phase': 'app_pending'}
        with patch.object(release, 'notary', return_value={'status': 'In Progress'}):
            self.assertFalse(release.accepted('v0.1.0', state, 'app'))
        self.assertEqual(state['phase'], 'app_pending')

    def test_rejection_blocks_publication_and_is_saved(self):
        state = {'app_submission_id': 'submission', 'phase': 'app_pending'}
        with patch.object(release, 'notary', return_value={'status': 'Invalid'}), patch.object(release, 'save') as save:
            with self.assertRaises(RuntimeError):
                release.accepted('v0.1.0', state, 'app')
            self.assertEqual(state['phase'], 'app_rejected')
            save.assert_called_once()

    def test_resumed_archive_must_match_saved_checksum(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'notary-app.zip'
            path.write_bytes(b'changed archive')
            with patch.object(release, 'OUT', Path(tmp)), patch.object(release, 'gh'):
                with self.assertRaisesRegex(RuntimeError, 'Checksum mismatch'):
                    release.download('v0.1.0', path.name, '0' * 64)


if __name__ == '__main__':
    unittest.main()
