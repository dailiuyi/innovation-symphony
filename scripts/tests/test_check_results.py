"""Strict report validation, classification and complete subprocess evidence."""
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_candidate
import check_results

FORMAT = "** (Mix) mix format failed due to --check-formatted.\nThe following files are not formatted:\nlib/example.ex\n"
COVERAGE = "Coverage test failed, threshold not met:\n    Coverage: 99.93%\n    Threshold: 100.00%\n"
COMPILE = "== Compilation error in file lib/example.ex ==\n** (CompileError) lib/example.ex:3: undefined function missing/0\n"
SPECS = "lib/example.ex:4 missing @spec for Example.run/0\n** (Mix) specs.check failed with 1 missing @spec declaration(s)\n"
IDENTITY = dict(run_id="fresh", candidate_sha="a" * 40, stage="test", runner_digest="b" * 64, formatter_digest="c" * 64)


def events_for(states):
    counts = dict(total=len(states), passed=0, failed=0, skipped=0, excluded=0, invalid=0)
    events = [dict(event="suite_started")]
    for index, (state, errors) in enumerate(states):
        counts[state] += 1
        events.append(dict(event="test_finished", test_id=f"Example:test {index}", state=state,
                           failures=[dict(kind="error", type=error) for error in errors]))
    events.append(dict(event="suite_finished", counts=counts))
    return [dict(event, sequence=index, identity=IDENTITY) for index, event in enumerate(events)]


def valid_report(states):
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "report.jsonl"
        path.write_text("".join(json.dumps(event) + "\n" for event in events_for(states)), encoding="utf-8")
        return check_results.read_report(path, IDENTITY)


class CheckResultsTest(unittest.TestCase):
    def setUp(self):
        self.passing = valid_report([("passed", [])])
        self.assertion = valid_report([("failed", ["ExUnit.AssertionError"])])

    def test_recognized_format_spec_and_compilation_failures(self):
        for stage, output in [("format", FORMAT), ("lint", SPECS), ("lint", COMPILE), ("build", COMPILE)]:
            with self.subTest(stage=stage):
                self.assertEqual(check_results.classify(stage, 1, output), 10)
        self.assertEqual(check_results.classify("test", 1, COMPILE), 1)

    def test_pre_execution_compilation_exception_is_narrow(self):
        for stage in ("test", "baseline_test"):
            result, reason = check_results.classify_result(stage, 1, COMPILE, test_execution_not_started=True)
            self.assertEqual(result, 10)
            self.assertIn("before test execution", reason)
            for code, output, not_started in (
                (2, COMPILE, True), (0, COMPILE, True), (1, COMPILE, False),
                (1, "unknown compiler crash", True), (1, COMPILE + "permission denied", True),
                (1, COMPILE.replace("lib/example.ex", "deps/example/lib/example.ex"), True),
            ):
                result, _ = check_results.classify_result(stage, code, output, test_execution_not_started=not_started)
                self.assertEqual(result, 1)

    def test_only_one_valid_bound_start_allows_compile_exception(self):
        start = events_for([("passed", [])])[0]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.jsonl"
            self.assertTrue(check_results._before_test_execution(path, IDENTITY))
            path.write_bytes(b"")
            self.assertTrue(check_results._before_test_execution(path, IDENTITY))
            path.write_text(json.dumps(start) + "\n", encoding="utf-8")
            self.assertTrue(check_results._before_test_execution(path, IDENTITY))
            variants = [[dict(start, identity=dict(IDENTITY, run_id="old"))],
                        [dict(start, sequence=1)], [dict(start, sequence=False)],
                        [start, start], [dict(start, event="test_finished")],
                        events_for([("passed", [])])[:-1]]
            for events in variants:
                path.write_text("".join(json.dumps(event) + "\n" for event in events), encoding="utf-8")
                with self.subTest(events=events):
                    self.assertFalse(check_results._before_test_execution(path, IDENTITY))
            for raw in (json.dumps(start), "{invalid}\n", '{"event":"suite_started","event":"suite_started"}\n'):
                path.write_text(raw, encoding="utf-8")
                with self.assertRaises(ValueError):
                    check_results._before_test_execution(path, IDENTITY)

    def test_assertions_require_no_english_message(self):
        for stage in ("test", "baseline_test"):
            self.assertEqual(check_results.classify(stage, 2, "任意自定义失败信息", self.assertion), 10)
            self.assertEqual(check_results.classify(stage, 2, "", self.assertion), 10)
            self.assertEqual(check_results.classify(stage, 2, "Assertion with == failed"), 1)

    def test_coverage_requires_complete_report_and_original_threshold(self):
        for report in (self.passing, self.assertion):
            self.assertEqual(check_results.classify("test", 3, COVERAGE, report), 10)
        for output in (COVERAGE.replace("100.00", "90.00"), COVERAGE.replace("99.93", "100.00"), "coverage failed"):
            self.assertEqual(check_results.classify("test", 3, output, self.passing), 1)
        self.assertEqual(check_results.classify("test", 3, COVERAGE), 1)
        self.assertEqual(check_results.classify("baseline_test", 3, COVERAGE, self.passing), 1)

    def test_mixed_unknown_exception_always_stops(self):
        mixed = valid_report([("failed", ["ExUnit.AssertionError"]), ("failed", ["RuntimeError"])])
        for code in (0, 2, 3):
            self.assertEqual(check_results.classify("test", code, COVERAGE, mixed), 1)
        for name in ("ExUnit.TimeoutError", "File.Error", "ErlangError"):
            report = valid_report([("failed", [name])])
            self.assertEqual(check_results.classify("test", 2, "", report), 1)

    def test_environment_failures_take_precedence(self):
        for output in ("reason: :eperm", "permission denied", "No space left on device", "test timed out", "Unchecked dependencies"):
            self.assertEqual(check_results.classify("test", 2, output, self.assertion), 1)

    def test_exit_contradictions_and_missing_report_stop(self):
        for code in (-15, -9, 1, 10, 124, 137, 143, 255):
            self.assertEqual(check_results.classify("test", code, "", self.assertion), 1)
        self.assertEqual(check_results.classify("test", 0, "", self.assertion), 1)
        self.assertEqual(check_results.classify("test", 2, "", self.passing), 1)
        self.assertEqual(check_results.classify("test", 0, ""), 1)
        self.assertEqual(check_results.classify("test", 0, "", self.passing), 0)
        self.assertEqual(check_results.classify("test", 0, COVERAGE, self.passing), 1)

    def test_corrupt_stale_duplicate_and_zero_execution_reports_stop(self):
        original = events_for([("passed", [])])
        variants = []
        for key in IDENTITY:
            events = copy.deepcopy(original)
            events[1]["identity"][key] = "wrong"
            variants.append(events)
        for field, value in (("total", 2), ("passed", True), ("failed", 1)):
            events = copy.deepcopy(original)
            events[-1]["counts"][field] = value
            variants.append(events)
        variants += [original[:-1], original + [original[-1]], [original[0], original[1], original[1], original[-1]],
                     events_for([]), events_for([("skipped", [])]),
                     events_for([("invalid", [])]), [1, 2], events_for([("failed", [])])]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.jsonl"
            for events in variants:
                path.write_text("".join(json.dumps(event) + "\n" for event in events), encoding="utf-8")
                with self.subTest(events=events), self.assertRaises((ValueError, KeyError, TypeError)):
                    check_results.read_report(path, IDENTITY)
            path.write_text(json.dumps(original[0]), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "truncated"):
                check_results.read_report(path, IDENTITY)
            path.write_text('{"event":"suite_started","event":"suite_started"}\n{}\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate JSON field"):
                check_results.read_report(path, IDENTITY)

    def test_candidate_stops_after_repairable_failure(self):
        with patch.object(sys, "argv", ["check_candidate.py", "/fixture"]), patch.object(check_candidate, "run_check", side_effect=[0, 10]) as run:
            self.assertEqual(check_candidate.main(), 10)
        self.assertEqual([call.args[0] for call in run.call_args_list], ["deps", "format"])

    def test_stream_preserves_all_output_and_independent_evidence(self):
        first, last = FORMAT + "x" * 9000, "\nSTDERR-END\n"
        program = f"import os; os.write(1, {first.encode()!r}); os.write(2, {last.encode()!r}); raise SystemExit(1)"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for _ in range(2):
                buffer = io.BytesIO()
                stream = io.TextIOWrapper(buffer, encoding="utf-8", write_through=True)
                with patch.object(sys, "stdout", stream), patch.object(check_results.subprocess, "check_output", return_value="a" * 40):
                    self.assertEqual(check_results.run_check("format", [sys.executable, "-c", program], Path.cwd(), dict(os.environ), evidence_root=root), 10)
                self.assertIn(first + last, buffer.getvalue().decode())
            directories = list(root.iterdir())
            self.assertEqual(len(directories), 2)
            identities = []
            for directory in directories:
                self.assertEqual((directory / "output.log").read_text(), first + last)
                result = json.loads((directory / "result.json").read_text())
                self.assertEqual((result["child_exit"], result["outcome"]), (1, 10))
                identities.append(result["identity"])
            self.assertNotEqual(identities[0]["run_id"], identities[1]["run_id"])
            self.assertEqual(len(identities[0]["runner_digest"]), 64)

    def test_missing_formatter_or_wrong_head_stops_before_spawn(self):
        for kwargs in ({"candidate_sha": "wrong"}, {}):
            with tempfile.TemporaryDirectory() as temporary, patch.object(sys, "stdout", io.StringIO()), patch.object(
                check_results.subprocess, "check_output", return_value="a" * 40
            ), patch.object(check_results, "FORMATTER", Path(temporary) / "missing.exs"), patch.object(check_results.subprocess, "Popen") as spawn:
                self.assertEqual(check_results.run_check("test", ["mix", "test"], Path.cwd(), {}, evidence_root=Path(temporary), **kwargs), 1)
                spawn.assert_not_called()


if __name__ == "__main__":
    unittest.main()
