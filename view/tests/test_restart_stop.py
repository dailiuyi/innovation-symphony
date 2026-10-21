"""Read-only presentation of durable restart stops, including unverified journals."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from test_runtime_source import scan
from symphony_board import derive


class RestartStopTests(unittest.TestCase):
    def test_exact_receipt_bound_stop_is_displayed_without_rewriting_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'runtime'
            receipt = root / 'state/task.json'
            receipt.parent.mkdir(parents=True)
            raw = json.dumps({'repository': 'owner/repo', 'issue': '42', 'status': 'checking',
                              'issue_identifier': 'GH-42', 'restart_recovery': {'enabled': True}})
            receipt.write_text(raw)
            journal = Path(str(receipt) + '.restart-blocked.json')
            record = {'schema': 1, 'status': 'blocked', 'receipt_before': raw,
                      'receipt_sha256': hashlib.sha256(raw.encode()).hexdigest(),
                      'reason': ':mvp_restart_model_call_uncertain', 'stopped_at': '2026-10-20T09:00:00Z'}
            journal.write_text(json.dumps(record))
            snapshot = scan([str(root)])
            self.assertEqual(len(snapshot['runtimes'][0]['receipts']), 1)
            task = derive.build_tasks(snapshot, [], {})[0]
            self.assertEqual(task['status'], 'blocked')
            self.assertEqual(task['statusLabel'], '自动恢复已停止')
            self.assertTrue(task['executionHealth']['verified'])
            self.assertEqual(task['executionHealth']['receiptStatus'], 'checking')
            self.assertEqual(task['reason'], ':mvp_restart_model_call_uncertain')
            self.assertEqual(receipt.read_text(), raw)

            for invalid in ['broken', json.dumps(dict(record, receipt_sha256='other')),
                            json.dumps(dict(record, receipt_before=raw + '\n'))]:
                journal.write_text(invalid)
                task = derive.build_tasks(scan([str(root)]), [], {})[0]
                self.assertEqual(task['status'], 'blocked')
                self.assertEqual(task['statusLabel'], '恢复停止记录待核对')
                self.assertFalse(task['executionHealth']['verified'])
                self.assertEqual(receipt.read_text(), raw)


if __name__ == '__main__':
    unittest.main()
