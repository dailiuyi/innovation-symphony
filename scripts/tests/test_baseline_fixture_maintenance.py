"""Trusted repair changes a known temporary fixture, never the frozen source."""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_isolated as gate


class BaselineFixtureMaintenanceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base, self.harness = self.root / 'base', self.root / 'harness'
        self.original = (gate.BASELINE_FIXTURE_ANCHOR + '    assert :tamper_still_rejected\n').encode()
        for root in (self.base, self.harness):
            path = root / gate.BASELINE_FIXTURE_PATH
            path.parent.mkdir(parents=True)
            path.write_bytes(self.original)
        self.pin = hashlib.sha256(self.original).hexdigest()

    def repair(self, kind='baseline'):
        with patch.object(gate, 'BASELINE_FIXTURE_SHA256', self.pin):
            return gate.maintain_baseline_fixture(self.base, self.harness, kind)

    def test_known_fixture_repaired_only_in_temporary_harness_and_audited(self):
        reports = self.repair()
        frozen = self.base / gate.BASELINE_FIXTURE_PATH
        effective = self.harness / gate.BASELINE_FIXTURE_PATH
        self.assertEqual(frozen.read_bytes(), self.original)
        self.assertEqual(effective.read_bytes(), self.original.replace(
            gate.BASELINE_FIXTURE_ANCHOR.encode(),
            (gate.BASELINE_FIXTURE_ANCHOR + gate.BASELINE_FIXTURE_INSERT).encode(), 1))
        self.assertEqual(reports[0]['frozen_sha256'], self.pin)
        self.assertEqual(reports[0]['effective_sha256'], hashlib.sha256(effective.read_bytes()).hexdigest())
        self.assertFalse(reports[0]['assertions_removed'])

    def test_candidate_mode_and_unknown_frozen_input_are_not_changed(self):
        self.assertEqual(self.repair('candidate'), [])
        self.assertEqual((self.harness / gate.BASELINE_FIXTURE_PATH).read_bytes(), self.original)
        (self.base / gate.BASELINE_FIXTURE_PATH).write_bytes(b'unrecognized test')
        self.assertEqual(self.repair(), [])

    def test_changed_or_linked_target_and_duplicate_anchor_refuse_repair(self):
        target = self.harness / gate.BASELINE_FIXTURE_PATH
        target.write_bytes(b'candidate-controlled input')
        with self.assertRaisesRegex(ValueError, 'differs'):
            self.repair()
        target.unlink()
        target.symlink_to(self.base / gate.BASELINE_FIXTURE_PATH)
        with self.assertRaisesRegex(ValueError, 'differs'):
            self.repair()
        target.unlink()
        duplicate = self.original + gate.BASELINE_FIXTURE_ANCHOR.encode()
        target.write_bytes(duplicate)
        (self.base / gate.BASELINE_FIXTURE_PATH).write_bytes(duplicate)
        self.pin = hashlib.sha256(duplicate).hexdigest()
        with self.assertRaisesRegex(ValueError, 'not unique'):
            self.repair()


if __name__ == '__main__':
    unittest.main()
