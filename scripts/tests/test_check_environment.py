"""Regression coverage for controller configuration leaking into checks."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_baseline
import check_candidate
from check_environment import isolated_environment


class CheckEnvironmentTest(unittest.TestCase):
    def setUp(self):
        self.variables = {
            "GITHUB_REPO": "fixture/repository",
            "GITHUB_TOKEN": "fixture-controller-token",
            "GH_TOKEN": "fixture-cli-token",
            "MIX_HOME": "/fixture/mix-cache",
        }
        environment = patch.dict(os.environ, self.variables)
        environment.start()
        self.addCleanup(environment.stop)

    def assert_isolated(self, environment):
        for name in ("GITHUB_REPO", "GITHUB_TOKEN", "GH_TOKEN"):
            self.assertNotIn(name, environment)
            self.assertEqual(os.environ[name], self.variables[name])
        self.assertEqual(environment["MIX_HOME"], self.variables["MIX_HOME"])
        self.assertEqual(environment.get("PATH"), os.environ.get("PATH"))

    def test_real_child_cannot_observe_controller_configuration(self):
        environment = isolated_environment()
        self.assert_isolated(environment)
        result = subprocess.run(
            [sys.executable, "-c", "import os; print([k for k in ('GITHUB_REPO', 'GITHUB_TOKEN', 'GH_TOKEN') if k in os.environ])"],
            env=environment, capture_output=True, text=True, check=True,
        )
        self.assertEqual(result.stdout.strip(), "[]")

    def test_every_candidate_step_uses_isolation_and_preserves_check_order(self):
        with patch.object(sys, "argv", ["check_candidate.py", "/fixture/candidate"]), patch.object(
            check_candidate, "run_check", return_value=0
        ) as run:
            check_candidate.main()
        self.assertEqual([call.args[1] for call in run.call_args_list], [
            ["mix", "deps", "get"], ["mix", "format", "--check-formatted"],
            ["mix", "lint"], ["mix", "test", "--cover"],
            ["mix", "dialyzer", "--format", "short"], ["mix", "build"],
        ])
        for call in run.call_args_list:
            self.assert_isolated(call.args[3])
            self.assertEqual(call.args[2], Path("/fixture/candidate").resolve() / "elixir")

    def test_failure_stops_later_candidate_steps(self):
        with patch.object(sys, "argv", ["check_candidate.py", "/fixture/candidate"]), patch.object(
            check_candidate, "run_check", return_value=1
        ) as run:
            self.assertEqual(check_candidate.main(), 1)
        self.assertEqual(run.call_count, 1)

    def test_frozen_baseline_check_uses_isolation_and_propagates_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline, candidate = root / "baseline", root / "candidate"
            for path in (baseline / "elixir/lib", baseline / "elixir/priv", baseline / ".github",
                         candidate / "elixir/lib", candidate / "elixir/priv", candidate / "elixir/deps"):
                path.mkdir(parents=True)
            (baseline / ".github/pull_request_template.md").write_text("fixture", encoding="utf-8")
            with patch.object(sys, "argv", ["check_baseline.py", str(candidate)]), patch.object(
                check_baseline, "__file__", str(baseline / "scripts/check_baseline.py")
            ), patch.object(check_baseline, "run_check", return_value=10) as run:
                self.assertEqual(check_baseline.main(), 10)
            self.assert_isolated(run.call_args.args[3])
            self.assertEqual(run.call_args.args[:2], ("baseline_test", ["mix", "test"]))
            self.assertFalse(run.call_args.args[2].exists())

    @unittest.skipUnless(os.name == "posix", "check entrypoints require Linux/WSL")
    def test_archived_entrypoints_do_not_write_to_frozen_baseline(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline, candidate = root / "baseline", root / "candidate"
            scripts = baseline / "scripts"
            scripts.mkdir(parents=True)
            for name in ("check_candidate.py", "check_baseline.py", "check_environment.py", "check_results.py"):
                shutil.copy2(Path(__file__).resolve().parents[1] / name, scripts / name)
            for path in (baseline / "elixir/lib", baseline / "elixir/priv", baseline / ".github",
                         candidate / "elixir/lib", candidate / "elixir/priv", candidate / "elixir/deps"):
                path.mkdir(parents=True)
            (baseline / ".github/pull_request_template.md").write_text("fixture", encoding="utf-8")
            mix = root / "mix"
            mix.write_text(f"#!{sys.executable}\n", encoding="utf-8")
            mix.chmod(0o700)
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"])
            environment.pop("PYTHONDONTWRITEBYTECODE", None)
            before = {str(path.relative_to(baseline)): path.read_bytes() for path in baseline.rglob("*") if path.is_file()}
            for name in ("check_candidate.py", "check_baseline.py"):
                subprocess.run([sys.executable, str(scripts / name), str(candidate)], env=environment, check=True)
                after = {str(path.relative_to(baseline)): path.read_bytes() for path in baseline.rglob("*") if path.is_file()}
                self.assertEqual(before, after, f"{name} mutated the frozen baseline")


if __name__ == "__main__":
    unittest.main()
