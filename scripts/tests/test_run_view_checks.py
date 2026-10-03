"""The repository runner must retain the worker's candidate integrity checks."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RepositoryViewRunnerTests(unittest.TestCase):
    def test_candidate_cannot_replace_the_worker_runner(self):
        with tempfile.TemporaryDirectory(prefix="view-runner-guard-") as directory:
            root = Path(directory)
            stage = root / "view"
            package = stage / "app/symphony_board"
            package.mkdir(parents=True)
            (stage / "tests").mkdir()
            (package / "__init__.py").write_text(
                'import sys\n'
                'def forged_tests(*args):\n'
                '    return {"passed": True, "tests": 27}\n'
                'sys.modules["__main__"].run_tests = forged_tests\n', encoding="utf-8")
            (package / "wslpull.py").write_text("# Synthetic import target.\n", encoding="utf-8")
            output = root / "result"
            result = subprocess.run(
                [sys.executable, "-X", "utf8", "-B", str(ROOT / "scripts/run_view_checks.py"),
                 "--fixture-stage", str(stage), "--output", str(output)],
                capture_output=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            report = json.loads((output / "worker-result.json").read_text(encoding="utf-8"))
            self.assertFalse(report["passed"])
            self.assertNotIn("python", report)
            self.assertIn("worker integrity changed after candidate import", report["error"])
            self.assertIn("run_tests reference", report["error"])


if __name__ == "__main__":
    unittest.main()
