"""Regression coverage for controller configuration leaking into checks."""

import os
import json
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
import check_environment
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
            (baseline / "elixir/frozen-marker").write_text("original baseline", encoding="utf-8")
            def check_original_snapshot(*args, **kwargs):
                self.assertEqual((args[2] / "frozen-marker").read_text(), "original baseline")
                self.assertEqual(kwargs["candidate_root"], candidate)
                return 10

            with patch.object(sys, "argv", ["check_baseline.py", str(candidate), "--baseline", str(baseline)]), patch.object(
                check_baseline, "run_check", side_effect=check_original_snapshot
            ) as run:
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
            for name in ("check_candidate.py", "check_baseline.py", "check_environment.py", "check_results.py", "check_formatter.exs"):
                shutil.copy2(Path(__file__).resolve().parents[1] / name, scripts / name)
            for path in (baseline / "elixir/lib", baseline / "elixir/priv", baseline / ".github",
                         candidate / "elixir/lib", candidate / "elixir/priv", candidate / "elixir/deps"):
                path.mkdir(parents=True)
            (baseline / ".github/pull_request_template.md").write_text("fixture", encoding="utf-8")
            for arguments in (["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "fixture"]):
                subprocess.run(["git", "-C", str(candidate), *arguments], check=True, capture_output=True)
            mix = root / "mix"
            mix.write_text(f"#!{sys.executable}\n", encoding="utf-8")
            mix.chmod(0o700)
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"])
            environment.pop("PYTHONDONTWRITEBYTECODE", None)
            before = {str(path.relative_to(baseline)): path.read_bytes() for path in baseline.rglob("*") if path.is_file()}
            for name in ("check_candidate.py", "check_baseline.py"):
                result = subprocess.run([sys.executable, str(scripts / name), str(candidate)], env=environment, capture_output=True)
                # A fake mix exits 0 without a report: fail closed, still no baseline writes.
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                after = {str(path.relative_to(baseline)): path.read_bytes() for path in baseline.rglob("*") if path.is_file()}
                self.assertEqual(before, after, f"{name} mutated the frozen baseline")


class ResourceEnvironmentTest(unittest.TestCase):
    def test_trusted_cpu_and_pid_limits_override_inherited_scheduler_settings(self):
        with patch.dict(os.environ, {
            'SYMPHONY_CHECK_CPUS': '4', 'SYMPHONY_CHECK_PIDS': '64',
            'ERL_FLAGS': '+S 32:32 +SP 200:200 +SDPcpu 300:300 -kernel net_ticktime 60',
            'ERL_ZFLAGS': '+SDio 10 +SP 300:300 +SDPcpu 200:200 -kernel inet_dist_listen_min 9100',
        }):
            budget = check_environment.check_resource_budget()
            environment = isolated_environment()
            self.assertEqual((budget['cpus'], budget['pids'], budget['schedulers']), (4, 64, 2))
            self.assertIn('-kernel net_ticktime 60', environment['ERL_FLAGS'])
            self.assertIn('-kernel inet_dist_listen_min 9100', environment['ERL_ZFLAGS'])
            for name in ('ERL_FLAGS', 'ERL_ZFLAGS'):
                self.assertTrue(environment[name].endswith(
                    '+S 2:2 +SDcpu 1:1 +SDio 1 +SP 100:100 +SDPcpu 100:100'
                ))
            probe = 'import os,json; print(json.dumps([os.environ["ERL_FLAGS"],os.environ["ERL_ZFLAGS"]]))'
            program = f'import subprocess,sys; print(subprocess.check_output([sys.executable,"-c",{probe!r}],text=True).strip())'
            output = subprocess.check_output([sys.executable, '-c', program], env=environment, text=True)
            self.assertEqual(json.loads(output), [environment['ERL_FLAGS'], environment['ERL_ZFLAGS']])
            self.assertEqual(os.environ['ERL_FLAGS'],
                             '+S 32:32 +SP 200:200 +SDPcpu 300:300 -kernel net_ticktime 60')
            self.assertEqual(os.environ['ERL_ZFLAGS'],
                             '+SDio 10 +SP 300:300 +SDPcpu 200:200 -kernel inet_dist_listen_min 9100')

    def test_inherited_argument_controls_fail_closed_in_appended_erl_flag_variables(self):
        controls = (
            '-extra inherited-marker', "'-extra' inherited-marker", '"-extra" inherited-marker',
            '-args_file /tmp/inherited.args', "'-args_file' /tmp/inherited.args",
            '"-args_file" /tmp/inherited.args',
        )
        for name in ('ERL_FLAGS', 'ERL_ZFLAGS'):
            for value in controls:
                with self.subTest(name=name, value=value), patch.dict(os.environ, {
                    'SYMPHONY_CHECK_CPUS': '2', 'SYMPHONY_CHECK_PIDS': '256', name: value,
                }, clear=True):
                    with self.assertRaisesRegex(ValueError, 'Erlang resource configuration rejects'):
                        isolated_environment()
                    self.assertEqual(os.environ[name], value)

    def test_invalid_inherited_quotes_raise_fixed_resource_diagnostics(self):
        for name in ('ERL_FLAGS', 'ERL_ZFLAGS'):
            for value in ('-kernel cafile "unterminated', "-kernel cafile 'unterminated", '-kernel cafile trailing\\'):
                with self.subTest(name=name, value=value), patch.dict(os.environ, {
                    'SYMPHONY_CHECK_CPUS': '2', 'SYMPHONY_CHECK_PIDS': '256', name: value,
                }, clear=True):
                    with self.assertRaisesRegex(ValueError,
                                                f'^Erlang resource configuration rejects invalid quoted flags in {name}$'):
                        isolated_environment()
                    self.assertEqual(os.environ[name], value)

    @unittest.skipUnless(shutil.which('erl'), 'requires preinstalled OTP')
    def test_actual_erl_preserves_aflags_without_overriding_appended_budget(self):
        runtime = shutil.which('erl')
        info = ('{erlang:system_info(schedulers),erlang:system_info(schedulers_online),'
                'erlang:system_info(dirty_cpu_schedulers),'
                'erlang:system_info(dirty_cpu_schedulers_online),'
                'erlang:system_info(dirty_io_schedulers)}')
        with tempfile.TemporaryDirectory() as temporary:
            arguments = Path(temporary) / 'inherited.args'
            arguments.write_text('+S 3:3 +SDcpu 1:1 +SDio 1 +SP 200:200 +SDPcpu 200:200 '
                                 '-extra inherited-marker\n')
            for aflags in (
                '-kernel net_ticktime 60',
                '+S 3:3 +SDcpu 1:1 +SDio 1 +SP 200:200 +SDPcpu 200:200 -kernel net_ticktime 60',
                f'-args_file "{arguments}"',
            ):
                with self.subTest(aflags=aflags), patch.dict(os.environ, {
                    'SYMPHONY_CHECK_CPUS': '2', 'SYMPHONY_CHECK_PIDS': '256',
                    'ERL_AFLAGS': aflags,
                }, clear=True):
                    environment = isolated_environment()
                    self.assertEqual(environment['ERL_AFLAGS'], aflags)
                    result = subprocess.run([runtime, '-noshell', '-eval',
                                             f'io:format("~p~n", [{info}]),halt().'], env=environment,
                                            capture_output=True, text=True, timeout=20)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(result.stdout.splitlines(), ['{2,2,1,1,1}'])
                    self.assertEqual(os.environ['ERL_AFLAGS'], aflags)

    def test_partial_invalid_or_out_of_range_trusted_limits_fail_closed(self):
        for cpus, pids in [('4', None), (None, '256'), ('0', '256'), ('65', '256'),
                           ('1', '0'), ('1', '65537'), ('bad', '256'), ('1.5', '256')]:
            with self.subTest(cpus=cpus, pids=pids), patch.dict(os.environ, {}, clear=True):
                for name, value in [('SYMPHONY_CHECK_CPUS', cpus), ('SYMPHONY_CHECK_PIDS', pids)]:
                    if value is not None:
                        os.environ[name] = value
                with self.assertRaisesRegex(ValueError, '^Erlang resource configuration rejects '):
                    isolated_environment()

    def test_host_detects_tightest_cgroup_ancestor_without_using_machine_cpu_count(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            group = root / 'groups/parent/task'
            group.mkdir(parents=True)
            membership = root / 'membership'
            membership.write_text('0::/parent/task\n')
            (group / 'cpu.max').write_text('400000 100000\n')
            (group / 'pids.max').write_text('256\n')
            (group.parent / 'cpu.max').write_text('200000 100000\n')
            (group.parent / 'pids.max').write_text('64\n')
            (root / 'groups/cpu.max').write_text('max 100000\n')
            (root / 'groups/pids.max').write_text('max\n')
            self.assertEqual(check_environment._cgroup_limits(root / 'groups', membership), (2, 64))
            with patch.dict(os.environ, {}, clear=True), patch.object(
                check_environment, '_cgroup_limits', return_value=(2, 64)
            ), patch.object(os, 'sched_getaffinity', return_value=set(range(64))):
                budget = check_environment.check_resource_budget()
                self.assertEqual((budget['cpus'], budget['pids'], budget['schedulers']), (2, 64, 2))
            with patch.dict(os.environ, {}, clear=True), patch.object(
                check_environment, '_cgroup_limits', return_value=(None, None)
            ), patch.object(os, 'sched_getaffinity', return_value=set(range(64))):
                budget = check_environment.check_resource_budget()
                self.assertEqual((budget['cpus'], budget['pids'], budget['schedulers']), (4, 256, 4))

    @unittest.skipUnless(shutil.which('erl') and shutil.which('escript'), 'requires preinstalled OTP')
    def test_actual_erl_escript_and_nested_erl_use_budget_despite_oversized_cli_flags(self):
        info = ('{erlang:system_info(schedulers),erlang:system_info(schedulers_online),'
                'erlang:system_info(dirty_cpu_schedulers),'
                'erlang:system_info(dirty_cpu_schedulers_online),'
                'erlang:system_info(dirty_io_schedulers)}')
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
            'SYMPHONY_CHECK_CPUS': '2', 'SYMPHONY_CHECK_PIDS': '256',
            'ERL_FLAGS': '+S 16:16 +SDcpu 16:16 +SDio 10 +SP 200:200 +SDPcpu 200:200',
            'ERL_ZFLAGS': '+S 8:8 +SP 300:300 +SDPcpu 300:300',
        }):
            script = Path(temporary) / 'threads.escript'
            script.write_text('#!/usr/bin/env escript\n'
                              '%%! +S 16:16 +SDcpu 16:16 +SDio 10 +SP 200:200 +SDPcpu 200:200\n'
                              f'main(_) -> io:format("~p~n", [{info}]), '
                              'io:format("~s", [os:cmd(os:getenv("RESOURCE_CHILD_COMMAND"))]).\n')
            environment = isolated_environment()
            import shlex
            child_command = [
                shutil.which('erl'), '+S', '16:16', '+SDcpu', '16:16', '+SDio', '10',
                '+SP', '200:200', '+SDPcpu', '200:200',
                '-noshell', '-eval', f'io:format("~p~n", [{info}]),halt().',
            ]
            direct = subprocess.run(child_command, env=environment,
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(direct.returncode, 0, direct.stdout + direct.stderr)
            self.assertEqual(direct.stdout.splitlines(), ['{2,2,1,1,1}'])
            environment['RESOURCE_CHILD_COMMAND'] = shlex.join(child_command)
            result = subprocess.run([shutil.which('escript'), str(script)], env=environment,
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.splitlines(), ['{2,2,1,1,1}', '{2,2,1,1,1}'])


if __name__ == "__main__":
    unittest.main()
