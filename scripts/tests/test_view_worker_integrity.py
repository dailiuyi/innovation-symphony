"""Regression tests for the bounded same-interpreter worker integrity guard."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest



ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from view_validation import validator
WORKER = ROOT / 'scripts' / 'view_validation' / 'worker.py'
FIXTURE = ROOT / 'scripts' / 'view_validation' / 'fixtures' / 'acceptance.json'


class ViewWorkerIntegrityTests(unittest.TestCase):
    def run_worker(self, package_init: str = '', test_source: str | None = None,
                   render: bool = False) -> tuple[subprocess.CompletedProcess[bytes], dict]:
        temporary = tempfile.TemporaryDirectory(prefix='view-worker-integrity-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        stage = root / 'stage'
        package = stage / 'app' / 'symphony_board'
        package.mkdir(parents=True)
        tests = stage / 'tests'
        tests.mkdir()
        (package / '__init__.py').write_text(package_init, encoding='utf-8')
        (package / 'wslpull.py').write_text('# Synthetic import target.\n', encoding='utf-8')
        if test_source is not None:
            (tests / 'test_fixture.py').write_text(test_source, encoding='utf-8')
        evidence = root / 'evidence'
        evidence.mkdir()
        argv = [sys.executable, '-I', '-B', str(WORKER), '--stage', str(stage),
                '--fixture', str(FIXTURE), '--evidence', str(evidence)]
        if render:
            argv.append('--render')
        process = subprocess.run(argv, cwd=stage, capture_output=True, timeout=30, check=False)
        report = json.loads((evidence / 'worker-result.json').read_text(encoding='utf-8'))
        return process, report

    def test_exact_import_hook_forgery_is_rejected_before_fake_reports_run(self) -> None:
        # This matches the reviewer reproduction: an empty tests directory and
        # package initialization that replaces both trusted worker entrypoints.
        baseline = json.loads((ROOT / 'scripts' / 'view_validation' / 'frozen' / 'baseline.json')
                              .read_text(encoding='utf-8'))
        fixture = json.loads(FIXTURE.read_text(encoding='utf-8'))
        identities = baseline['python_identities']
        pages = sorted('context-' + item['id'] + '.html' for item in fixture['sessions'])
        hook = f'''
import sys
main = sys.modules["__main__"]
def fake_run_tests(stage, integrity, guard):
    return {{"tests": 16, "identities": {identities!r}, "failures": [], "errors": [],
            "skipped": [], "expected_failures": [], "unexpected_successes": [], "passed": True}}
def fake_render_fixture(stage, fixture_path, evidence, integrity, guard):
    return {{"passed": True, "self_check_rendered": True, "tasks": 1, "rounds": 19,
            "review_retries": 4, "unassigned_sessions": 1,
            "html_pages": {pages!r}, "wsl_executed": False, "fixture_only": True}}
main.run_tests = fake_run_tests
main.render_fixture = fake_render_fixture
'''
        # Confirm this exact forged shape satisfied the downstream validators.
        forged_report = {
            'passed': True,
            'python': {'tests': 16, 'identities': identities, 'failures': [], 'errors': [],
                       'skipped': [], 'expected_failures': [], 'unexpected_successes': [],
                       'passed': True},
            'render': {'passed': True, 'self_check_rendered': True, 'tasks': 1, 'rounds': 19,
                       'review_retries': 4, 'unassigned_sessions': 1,
                       'html_pages': pages, 'wsl_executed': False, 'fixture_only': True},
        }
        validator.validate_python_report(forged_report, 16, identities)
        validator.validate_render(forged_report)
        process, report = self.run_worker(hook, render=True)

        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(report['passed'])
        self.assertNotIn('python', report)
        self.assertNotIn('render', report)
        self.assertIn('worker integrity changed after candidate import', report['error'])
        self.assertIn('run_tests reference', report['error'])
        self.assertIn('render_fixture reference', report['error'])
        self.assertEqual(report['worker_integrity']['stage_test_inputs'], {})

    def test_mutating_captured_run_tests_code_is_rejected(self) -> None:
        hook = '''
import sys
main = sys.modules["__main__"]
def fake_run_tests(stage, integrity, guard):
    return {"tests": 16, "identities": [], "failures": [], "errors": [],
            "skipped": [], "expected_failures": [], "unexpected_successes": [], "passed": True}
main.run_tests.__code__ = fake_run_tests.__code__
'''
        process, report = self.run_worker(hook)

        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(report['passed'])
        self.assertIn('run_tests code', report['error'])
        self.assertNotIn('python', report)

    def test_render_entrypoint_replacement_is_rejected(self) -> None:
        hook = '''
import sys
main = sys.modules["__main__"]
def fake_render_fixture(stage, fixture_path, evidence, integrity, guard):
    return {"passed": True, "self_check_rendered": True}
main.render_fixture = fake_render_fixture
'''
        process, report = self.run_worker(hook, render=True)

        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(report['passed'])
        self.assertIn('render_fixture reference', report['error'])
        self.assertNotIn('render', report)

    def test_unittest_runner_replacement_is_rejected(self) -> None:
        hook = '''
import unittest
def forged_run(self, test):
    return unittest.TextTestResult(self.stream, True, self.verbosity)
unittest.TextTestRunner.run = forged_run
'''
        process, report = self.run_worker(hook)

        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(report['passed'])
        self.assertIn('unittest.runner_run', report['error'])
        self.assertNotIn('python', report)

    def test_captured_runner_executes_nonempty_test_and_allows_discover_sys_path(self) -> None:
        test_source = '''
import unittest
class RunnerWasReallyUsed(unittest.TestCase):
    def test_real_assertion(self):
        self.assertEqual(21 * 2, 42)
'''
        process, report = self.run_worker(test_source=test_source)

        self.assertIn('python', report, report)
        python_report = report['python']
        self.assertEqual(python_report['tests'], 1)
        self.assertEqual(python_report['identities'], ['test_fixture.RunnerWasReallyUsed.test_real_assertion'])
        self.assertTrue(python_report['passed'])
        # The pinned Viewer wheel is installed only in the isolated preparation
        # runtime; a local unit run may stop at the final dependency report.
        if process.returncode != 0:
            self.assertIn('codex-transcript-viewer', report.get('error', ''))


if __name__ == '__main__':
    unittest.main()
