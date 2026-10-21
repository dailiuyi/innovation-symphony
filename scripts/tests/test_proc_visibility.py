"""The diagnostic reports the calling process and separates unreadable descriptors."""
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import proc_visibility


class ProcVisibilityTest(unittest.TestCase):
    @unittest.skipUnless(Path("/proc/self/fd").is_dir(), "requires Linux procfs")
    def test_snapshot_lists_this_process_with_a_readable_descriptor_table(self):
        report = proc_visibility.snapshot()
        mine = next(item for item in report["processes"] if item["pid"] == os.getpid())
        self.assertTrue(mine["fd"].startswith("ok:"))
        self.assertEqual(report["uid"], os.getuid())

    def test_denied_descriptor_table_is_reported_by_errno_name(self):
        real = os.listdir

        def listdir(path):
            if str(path) == f"/proc/{os.getpid()}/fd":
                raise PermissionError(13, "denied")
            return real(path)

        with patch.object(proc_visibility.os, "listdir", side_effect=listdir):
            report = proc_visibility.snapshot()
        self.assertIn({"pid": os.getpid(), "fd": "EACCES"},
                      [{"pid": item["pid"], "fd": item["fd"]} for item in report["unreadable"]])


if __name__ == "__main__":
    unittest.main()
