"""Real Mix/ExUnit integration. Run with RUN_MIX_INTEGRATION=1 under Linux/WSL.

Fixtures use tiny, dependency-free Mix projects and actual Git candidate identities.
"""
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_results
import install_rootless_bridge
from check_environment import isolated_environment


@unittest.skipUnless(os.environ.get("RUN_MIX_INTEGRATION") == "1" and shutil.which("mix"), "opt-in real Mix integration")
class MixReportIntegrationTest(unittest.TestCase):
    def run_fixture(self, test_body, *, cover=False, helper="ExUnit.start()", source=None, stage="test", environment_hook=None, formatter=None):
        with tempfile.TemporaryDirectory(prefix="symphony-report-fixture-") as temporary:
            root = Path(temporary)
            project, evidence = root / "candidate", root / "evidence"
            (project / "test").mkdir(parents=True)
            (project / "lib").mkdir()
            (project / "mix.exs").write_text('''defmodule CheckFixture.MixProject do
  use Mix.Project
  def project, do: [app: :check_fixture, version: "0.1.0", test_coverage: [summary: [threshold: 100]]]
  def application, do: []
end
''', encoding="utf-8")
            if source:
                (project / "lib/fixture.ex").write_text(source, encoding="utf-8")
            (project / "test/test_helper.exs").write_text(helper + "\n", encoding="utf-8")
            (project / "test/fixture_test.exs").write_text("defmodule CheckFixtureTest do\n  use ExUnit.Case\n" + test_body + "\nend\n", encoding="utf-8")
            for args in (["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"]):
                subprocess.run(["git", "-C", str(project), *args], check=True, capture_output=True)
            arguments = ["mix", "test"] + (["--cover"] if cover else [])
            environment = isolated_environment()
            verify_environment = environment_hook(root, project, environment) if environment_hook else None
            output = io.BytesIO()
            with patch.object(check_results, "FORMATTER", formatter or check_results.FORMATTER), patch.object(sys, "stdout", io.TextIOWrapper(output, encoding="utf-8", write_through=True)):
                result = check_results.run_check(stage, arguments, project, environment, candidate_root=project, evidence_root=evidence)
                logged = output.getvalue().decode()
            if verify_environment:
                verify_environment()
            run = next(evidence.iterdir())
            details = json.loads((run / "result.json").read_text())
            report_path = run / "report.jsonl"
            report = report_path.read_text() if report_path.exists() else ""
            return result, details, report, logged

    def test_passing_suite_with_cli_output(self):
        result, detail, report, output = self.run_fixture('test "pass", do: assert(1 == 1)')
        self.assertEqual(result, 0, output)
        self.assertEqual(detail["child_exit"], 0)
        self.assertIn('"suite_finished"', report)
        self.assertIn("1 test, 0 failures", output)

    def test_project_compilation_before_test_execution_is_repairable(self):
        for stage in ("test", "baseline_test"):
            for body, source in (
                ('test "unused", do: assert(true)', 'defmodule CheckFixture do\n  def broken, do: missing_function()\nend\n'),
                ('test "compile error", do: missing_function()', None),
            ):
                with self.subTest(stage=stage, source="lib" if source else "test"):
                    result, detail, report, output = self.run_fixture(body, source=source, stage=stage)
                    self.assertEqual((result, detail["child_exit"]), (10, 1), output)
                    if source:
                        self.assertEqual(report, "", output)
                    else:
                        events = [json.loads(line) for line in report.splitlines()]
                        self.assertEqual(events, [{"event": "suite_started", "identity": detail["identity"], "sequence": 0}], output)
                    self.assertIn("before test execution", detail["reason"])

    def test_compilation_does_not_override_a_damaged_report(self):
        helper = 'ExUnit.start()\nFile.write!(System.fetch_env!("SYMPHONY_CHECK_REPORT"), "damaged report\\n")'
        result, detail, report, output = self.run_fixture('test "compile error", do: missing_function()', helper=helper)
        self.assertEqual((result, detail["child_exit"]), (1, 1), output)
        self.assertEqual(report, "damaged report\n")

    def test_plain_and_custom_assertions_are_repairable(self):
        for expression in ('assert 1 == 2', 'assert 1 == 2, "custom path_canonicalize_failed :enotdir"'):
            result, detail, report, output = self.run_fixture('test "assertion" do\n' + expression + '\nend')
            self.assertEqual((result, detail["child_exit"]), (10, 2), output)
            self.assertIn("ExUnit.AssertionError", report)

    def test_mixed_unknown_and_timeout_stop(self):
        for body in ('test "assertion", do: assert(1 == 2)\ntest "unknown", do: raise("unexpected")',
                     '@tag timeout: 10\ntest "timeout", do: Process.sleep(200)'):
            result, detail, report, output = self.run_fixture(body)
            self.assertEqual(result, 1, output)
            self.assertEqual(detail["child_exit"], 2, output)
            self.assertIn('"suite_finished"', report)

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux protected sysfs")
    def test_real_protected_filesystem_failure_stops(self):
        result, detail, report, output = self.run_fixture('test "permission", do: File.write!("/sys/symphony-check-fixture-no-write", "fixture")')
        self.assertEqual((result, detail["child_exit"]), (1, 2), output)
        self.assertIn("File.Error", report)

    def test_killed_formatter_stops_without_complete_report(self):
        body = '''test "formatter killed during suite" do
  formatter = Enum.find(Process.list(), fn pid ->
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        Keyword.get(dictionary, :"$initial_call") == {SymphonyChecks.Formatter, :init, 1}
      _ -> false
    end
  end)
  assert is_pid(formatter), "external formatter process must exist"
  monitor = Process.monitor(formatter)
  Process.exit(formatter, :kill)
  assert_receive {:DOWN, ^monitor, :process, ^formatter, :killed}, 1000
end'''
        result, _, report, output = self.run_fixture(body)
        self.assertEqual(result, 1, output)
        self.assertIn('"suite_started"', report, output)
        self.assertNotIn('"suite_finished"', report, output)

    def test_exit_zero_interruption_stops_without_complete_report(self):
        result, detail, report, output = self.run_fixture('test "interrupt", do: System.halt(0)')
        self.assertEqual((result, detail["child_exit"]), (1, 0), output)
        self.assertNotIn('"suite_finished"', report, output)

    def test_zero_execution_and_setup_all_failure_stop(self):
        for body in ('', '@tag :skip\ntest "skip", do: assert(true)',
                     'setup_all do\nraise "setup failed"\nend\ntest "invalid", do: assert(true)'):
            result, _, _, output = self.run_fixture(body)
            self.assertEqual(result, 1, output)

    def test_passing_report_preserves_skip_and_exclusion_reasons(self):
        body = '''test "pass", do: assert(true)
@tag skip: "requires authorized external platform"
test "skip", do: assert(false)
@tag :external
test "exclude", do: assert(false)'''
        result, detail, _, output = self.run_fixture(body, helper='ExUnit.start(exclude: [:external])')
        self.assertEqual(result, 0, output)
        tests = {item['state']: item for item in detail['tests']}
        self.assertEqual(set(tests), {'passed', 'skipped', 'excluded'})
        self.assertIn('requires authorized external platform', tests['skipped']['reason'])
        self.assertTrue(tests['excluded']['reason'])
        self.assertEqual(detail['counts']['passed'], 1)
        self.assertIn('skipped=1, excluded=1', detail['reason'])

    def test_coverage_below_100_is_repairable(self):
        source = 'defmodule CheckFixture do\n  def hit, do: :ok\n  def missed, do: :missed\nend\n'
        result, detail, _, output = self.run_fixture('test "hit", do: assert(CheckFixture.hit() == :ok)', cover=True, source=source)
        self.assertEqual((result, detail["child_exit"]), (10, 3), output)
        self.assertEqual(detail["reason"], "coverage below required 100%")
        self.assertIn("100.00%", output)

    def test_recipe_mix_configuration_cannot_lower_frozen_coverage(self):
        def poison(root, project, environment):
            mix_home = root / 'recipe-mix-home'
            mix_home.mkdir()
            marker = root / 'configuration-loaded'
            config = mix_home / 'config.exs'
            config.write_text('File.write!(' + json.dumps(str(marker)) + ', "loaded")\n'
                              'Mix.ProjectStack.post_config(test_coverage: [summary: [threshold: 0]])\n')
            original = config.read_bytes()
            environment['MIX_HOME'] = str(mix_home)
            raw = subprocess.run(['mix', 'test', '--cover'], cwd=project, env=environment, capture_output=True, text=True)
            self.assertEqual(raw.returncode, 0, raw.stdout + raw.stderr)
            self.assertTrue(marker.exists(), raw.stdout + raw.stderr)
            marker.unlink()
            # Run the actual fixed runner with the same poisoned environment.
            def verify():
                self.assertFalse(marker.exists(), 'formal checker loaded recipe Mix config')
                self.assertEqual(config.read_bytes(), original, 'checker modified recipe configuration')
            return verify

        source = 'defmodule CheckFixture do\n  def hit, do: :ok\n  def missed, do: :missed\nend\n'
        result, detail, _, output = self.run_fixture('test "hit", do: assert(CheckFixture.hit() == :ok)', cover=True, source=source, environment_hook=poison)
        self.assertEqual((result, detail['child_exit']), (10, 3), output)
        self.assertEqual(detail['reason'], 'coverage below required 100%')
        self.assertNotIn('Threshold:   0.00%', output)

    def test_installed_formatter_starts_real_exunit_and_produces_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            install_rootless_bridge.copy_check_payload(Path(__file__).resolve().parents[1], destination)
            result, _, report, output = self.run_fixture('test "pass", do: assert(true)', formatter=destination / 'check_formatter.exs')
            self.assertEqual(result, 0, output)
            self.assertIn('"suite_finished"', report)

    def test_full_coverage_passes(self):
        result, _, _, output = self.run_fixture('test "hit", do: assert(CheckFixture.hit() == :ok)', cover=True,
                                                source='defmodule CheckFixture do\n  def hit, do: :ok\nend\n')
        self.assertEqual(result, 0, output)


if __name__ == "__main__":
    unittest.main()
