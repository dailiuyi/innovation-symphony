"""Pinned Mix diagnostic fixtures and complete subprocess output regression."""

import io
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_candidate
import check_results

FORMAT = """** (Mix) mix format failed due to --check-formatted.
The following files are not formatted:
lib/example.ex
"""
ASSERTION = """  1) test candidate behavior (ExampleTest)
     test/example_test.exs:4
     Assertion with == failed
     code: assert actual == expected
     left: 1
     right: 2
Finished in 0.1 seconds
1 test, 1 failure
"""
COVERAGE = """1 test, 0 failures
Coverage test failed, threshold not met:

    Coverage:   99.93%
    Threshold: 100.00%
"""
COMPILE = """== Compilation error in file lib/example.ex ==
** (CompileError) lib/example.ex:3: undefined function missing/0
"""
SPECS = """lib/example.ex:4 missing @spec for Example.run/0
** (Mix) specs.check failed with 1 missing @spec declaration(s)
"""


class CheckResultsTest(unittest.TestCase):
    def test_recognized_stage_code_and_diagnostic(self):
        for stage, code, output in [
            ("format", 1, FORMAT), ("test", 2, ASSERTION),
            ("baseline_test", 2, ASSERTION), ("test", 3, COVERAGE),
            ("lint", 1, SPECS), ("lint", 1, COMPILE),
            ("baseline_test", 1, COMPILE), ("build", 1, COMPILE),
        ]:
            with self.subTest(stage=stage, code=code, output=output):
                self.assertEqual(check_results.classify(stage, code, output), 10)

    def test_unknown_or_wrong_stage_or_wrong_exit_stops(self):
        for stage, code, output in [
            ("test", 1, "failed"), ("test", 2, "1 test, 1 failure"),
            ("test", 1, ASSERTION), ("deps", 2, ASSERTION),
            ("build", 1, FORMAT), ("format", 1, "mix format failed"),
            ("baseline_test", 3, COVERAGE), ("test", 3, COVERAGE.replace("99.93", "100.00")),
            ("lint", 1, "Credo crashed"), ("dialyzer", 1, COMPILE),
            ("test", 1, COMPILE.replace("lib/example.ex", "deps/example/lib/example.ex")),
        ]:
            with self.subTest(stage=stage, code=code, output=output):
                self.assertEqual(check_results.classify(stage, code, output), 1)

    def test_infrastructure_takes_precedence_over_assertions(self):
        for error in [
            "failed to open a TCP socket, reason: :eperm", "permission denied",
            "** (ExUnit.TimeoutError) test timed out after 60000ms",
            "** (Mix) Could not start application symphony_elixir",
            "Unchecked dependencies for environment test", "mix: command not found",
            "Failed to fetch record from repo", "No space left on device",
        ]:
            with self.subTest(error=error):
                self.assertEqual(check_results.classify("test", 2, ASSERTION + error), 1)

    def test_mixed_unknown_test_failure_is_not_explained_by_one_assertion(self):
        unknown = "  2) test unknown failure (ExampleTest)\n     ** (RuntimeError) unexpected\n"
        self.assertEqual(check_results.classify("test", 2, ASSERTION.replace(
            "1 test, 1 failure", unknown + "2 tests, 2 failures"
        )), 1)
        self.assertEqual(check_results.classify("test", 3, COVERAGE.replace(
            "1 test, 0 failures", unknown + "1 test, 1 failure"
        )), 1)
        self.assertEqual(check_results.classify("test", 3, COVERAGE.replace(
            "1 test, 0 failures", "1 test, 0 failures, 1 invalid"
        )), 1)

    def test_signals_deadlines_and_child_exit10_never_become_repairable(self):
        for code in [-15, -9, 10, 124, 137, 143, 255]:
            with self.subTest(code=code):
                self.assertEqual(check_results.classify("test", code, ASSERTION), 1)

    def test_success_and_ansi_diagnostics(self):
        self.assertEqual(check_results.classify("test", 0, ASSERTION), 0)
        self.assertEqual(check_results.classify("test", 2, "\x1b[31m" + ASSERTION + "\x1b[0m"), 10)

    def test_candidate_stops_after_repairable_failure(self):
        with patch.object(sys, "argv", ["check_candidate.py", "/fixture"]), patch.object(
            check_candidate, "run_check", side_effect=[0, 10]
        ) as run:
            self.assertEqual(check_candidate.main(), 10)
        self.assertEqual([call.args[0] for call in run.call_args_list], ["deps", "format"])

    def test_stream_preserves_first_error_and_all_stdout_stderr(self):
        output = io.BytesIO()
        stream = io.TextIOWrapper(output, encoding="utf-8", write_through=True)
        first = ASSERTION + "\n" + "x" * 9000
        last = "\nSTDERR-END\n"
        program = "import os; os.write(1, " + repr(first.encode()) + "); os.write(2, " + repr(last.encode()) + "); raise SystemExit(2)"
        with patch.object(sys, "stdout", stream):
            result = check_results.run_check("test", [sys.executable, "-c", program], Path.cwd(), dict(os.environ))
        self.assertEqual(result, 10)
        logged = output.getvalue().decode()
        self.assertIn(first + last, logged)
        self.assertIn("child_exit=2 outcome=10", logged)

    def test_missing_executable_stops(self):
        with patch.object(check_results.subprocess, "Popen", side_effect=FileNotFoundError("missing tool")), patch(
            "sys.stdout", io.StringIO()
        ):
            self.assertEqual(check_results.run_check("test", ["mix"], Path.cwd(), {}), 1)


if __name__ == "__main__":
    unittest.main()
