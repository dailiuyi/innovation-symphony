"""Frozen policy remains effective when the candidate attempts to weaken its gate."""
from pathlib import Path
from contextlib import redirect_stderr
import io
import json
import multiprocessing
import os
import queue
import fcntl
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_isolated
import check_results


class IsolatedPolicyTest(unittest.TestCase):
    def test_candidate_aliases_threshold_and_filters_do_not_become_effective(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline, candidate, harness, deps = (root / name for name in ('base', 'candidate', 'check', 'deps'))
            deps.mkdir()
            for tree in (baseline, candidate):
                for folder in ('lib', 'priv', 'config', 'test'):
                    (tree / 'elixir' / folder).mkdir(parents=True)
                    (tree / 'elixir' / folder / 'source.txt').write_text(tree.name)
                for name in check_isolated.POLICY_FILES:
                    (tree / 'elixir' / name).write_text('frozen policy')
            (candidate / 'elixir/mix.exs').write_text('lint=[]; coverage=0; exclude=all')
            (baseline / 'elixir/.credo.exs').unlink()
            original_path = check_isolated.Path
            with patch.object(check_isolated, 'Path', side_effect=lambda p: deps if p == '/opt/deps' else original_path(p)):
                changes = check_isolated.prepare_harness(candidate, baseline, harness, 'candidate')
            self.assertEqual((harness / 'elixir/mix.exs').read_text(), 'frozen policy')
            self.assertEqual((harness / 'elixir/test/source.txt').read_text(), 'candidate')
            self.assertEqual((harness / 'elixir/config/source.txt').read_text(), 'base')
            self.assertEqual(changes[0]['path'], 'elixir/mix.exs')
            self.assertFalse((harness / 'elixir/.credo.exs').exists())
            self.assertEqual(changes[1]['effective_policy'], 'frozen_default')

    def test_candidate_symlink_is_rejected_before_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            source.mkdir()
            try:
                (source / 'escape').symlink_to(root)
            except OSError:
                self.skipTest('OS cannot create a test symlink')
            with self.assertRaisesRegex(ValueError, 'unsupported candidate'):
                check_isolated.copy_regular_tree(source, root / 'target')
            self.assertFalse((root / 'target').exists())

    def test_static_findings_repairable_but_unknown_exit_and_environment_stop(self):
        for code in (4, 8, 12):
            self.assertEqual(check_results.classify('credo', code, 'found 1 refactoring opportunity'), 10)
            self.assertEqual(check_results.classify('credo', code, 'unexplained failure'), 1)
        text = 'Total errors: 3\ndone (warnings were emitted)'
        self.assertEqual(check_results.classify('dialyzer', 2, text), 10)
        self.assertEqual(check_results.classify('dialyzer', 2, text + '\npermission denied'), 1)


class HeavyCheckQueueTest(unittest.TestCase):
    def test_actual_candidate_and_baseline_processes_queue_entire_harness_and_stages(self):
        context = multiprocessing.get_context('fork')
        events, release = context.Queue(), context.Event()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = root / 'candidate'
            candidate.mkdir()
            lock = root / 'private-tmp-check.lock'
            original_path = check_isolated.Path

            def check(kind):
                def prepare(*args):
                    events.put((kind, 'prepare'))
                    return []

                def run(stage, argv, cwd, environment, **kwargs):
                    if not environment['ERL_ZFLAGS'].endswith('+S 2:2 +SDcpu 1:1 +SDio 1 +SP 100:100 +SDPcpu 100:100'):
                        raise AssertionError('child VM budget missing')
                    events.put((kind, stage))
                    if kind == 'candidate' and stage == 'format' and not release.wait(10):
                        raise AssertionError('fixture release timeout')
                    return 0

                with patch.object(sys, 'argv', ['check_isolated.py', kind]), patch.object(
                    check_isolated, 'Path', side_effect=lambda path: candidate if path == '/workspace' else original_path(path)
                ), patch.object(check_isolated, 'CHECK_LOCK', lock), patch.object(
                    check_isolated, 'prepare_harness', side_effect=prepare
                ), patch.object(check_isolated, 'native_client', return_value={'version': '0.160.0'}), patch.object(check_isolated, 'run_check', side_effect=run), patch.dict(os.environ, {
                    'SYMPHONY_CHECK_CPUS': '2', 'SYMPHONY_CHECK_PIDS': '256',
                }):
                    events.put((kind, 'starting'))
                    events.put((kind, 'exit', check_isolated.main()))

            first = context.Process(target=check, args=('candidate',))
            second = context.Process(target=check, args=('baseline',))
            first.start()
            try:
                self.assertEqual(events.get(timeout=5), ('candidate', 'starting'))
                self.assertEqual(events.get(timeout=5), ('candidate', 'prepare'))
                self.assertEqual(events.get(timeout=5), ('candidate', 'format'))
                second.start()
                self.assertEqual(events.get(timeout=5), ('baseline', 'starting'))
                with self.assertRaises(queue.Empty):
                    events.get(timeout=0.2)
                release.set()
                expected = [('candidate', stage) for stage in ('lint', 'credo', 'test', 'dialyzer', 'build')]
                expected += [('candidate', 'exit', 0), ('baseline', 'prepare'), ('baseline', 'baseline_test'),
                             ('baseline', 'exit', 0)]
                observed = [events.get(timeout=5) for _ in expected]
                # The first process may report its exit just after the second obtains
                # the slot, but every candidate stage precedes baseline preparation.
                candidate_events = [event for event in observed if event[0] == 'candidate']
                baseline_events = [event for event in observed if event[0] == 'baseline']
                self.assertEqual(candidate_events, expected[:6])
                self.assertEqual(baseline_events, expected[6:])
                self.assertLess(observed.index(('candidate', 'build')), observed.index(('baseline', 'prepare')))
                first.join(5)
                second.join(5)
                self.assertEqual((first.exitcode, second.exitcode), (0, 0))
                resources = [json.loads(path.read_text()) for path in candidate.glob('.check-evidence/*/resources.json')]
                self.assertEqual(len(resources), 2)
                self.assertTrue(all(item['schedulers'] == 2 for item in resources))
                self.assertGreaterEqual(max(item['queue_wait_ms'] for item in resources), 100)
            finally:
                release.set()
                for process in (first, second):
                    if process.pid is not None:
                        process.join(2)
                        if process.is_alive():
                            process.terminate()
                            process.join(2)
                events.close()
                events.join_thread()

    def test_queue_releases_after_failure_and_never_replaces_lock_inode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, first, second = (root / name for name in ('lock', 'first', 'second'))
            first.mkdir()
            second.mkdir()
            with patch.object(check_isolated, 'CHECK_LOCK', lock), self.assertRaisesRegex(ValueError, 'fixture'):
                with check_isolated.heavy_check_slot(first):
                    raise ValueError('fixture failure')
            inode = lock.stat().st_ino
            with patch.object(check_isolated, 'CHECK_LOCK', lock), check_isolated.heavy_check_slot(second):
                self.assertEqual(lock.stat().st_ino, inode)
                self.assertTrue((second / 'resources.json').is_file())

    def test_queue_rejects_a_link(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target, link = root / 'target', root / 'link'
            target.write_text('unchanged')
            link.symlink_to(target)
            with patch.object(check_isolated, 'CHECK_LOCK', link), self.assertRaises(OSError):
                with check_isolated.heavy_check_slot(root):
                    self.fail('link must not be locked')
            self.assertEqual(target.read_text(), 'unchanged')

    def test_running_check_retains_slot_when_checker_process_is_terminated(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, evidence, ready, release = (root / name for name in ('lock', 'evidence', 'ready', 'release'))
            evidence.mkdir()
            worker = (f'import os,time; from pathlib import Path; Path({str(ready)!r}).write_text(str(os.getpid())); '
                      f'\nwhile not Path({str(release)!r}).exists(): time.sleep(0.01)\n')

            def check():
                with patch.object(check_isolated, 'CHECK_LOCK', lock), patch.object(
                    check_results.subprocess, 'check_output', return_value='a' * 40
                ), check_isolated.heavy_check_slot(evidence) as descriptor:
                    check_results.run_check('build', [sys.executable, '-c', worker], root, dict(os.environ),
                                            evidence_root=evidence, serialization_fd=descriptor)

            process = multiprocessing.get_context('fork').Process(target=check)
            process.start()
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and process.is_alive() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists(), 'actual check child did not start')
                process.terminate()
                process.join(5)
                with lock.open('rb') as waiting:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(waiting, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    release.touch()
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            fcntl.flock(waiting, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            break
                        except BlockingIOError:
                            self.assertLess(time.monotonic(), deadline, 'exited child retained the queue lock')
                            time.sleep(0.01)
            finally:
                release.touch()
                if process.is_alive():
                    process.terminate()
                process.join(5)


class HarnessTemporaryDirectoryTest(unittest.TestCase):
    def test_every_stage_and_nested_process_inherit_private_tmp_and_cleanup_on_exit(self):
        child = (
            'import json,os,subprocess,sys,tempfile; '
            'nested=subprocess.check_output([sys.executable,"-c",'
            '"import tempfile; print(tempfile.gettempdir())"],text=True).strip(); '
            'print(json.dumps([os.environ["TMPDIR"],tempfile.gettempdir(),nested]))'
        )
        for kind, failure_stage in (('candidate', None), ('baseline', None), ('candidate', 'credo')):
            with self.subTest(kind=kind, failure_stage=failure_stage), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                evidence = root / 'evidence'
                evidence.mkdir()
                inherited_tmp = root / 'shared-tmp'
                inherited_tmp.mkdir()
                observed = []

                def prepare(candidate, baseline, harness, kind):
                    (harness / 'elixir').mkdir()
                    return []

                def run(stage, argv, cwd, environment, **kwargs):
                    runtime_tmp = Path(environment['TMPDIR'])
                    self.assertFalse(runtime_tmp.is_relative_to(cwd.parent),
                                     'state/workspace fixtures must remain outside the source harness')
                    self.assertEqual(runtime_tmp.parent, cwd.parent.parent)
                    self.assertEqual(runtime_tmp.stat().st_mode & 0o777, 0o700)
                    self.assertNotEqual(runtime_tmp, inherited_tmp)
                    actual = json.loads(subprocess.check_output(
                        [sys.executable, '-c', child], cwd=cwd, env=environment, text=True, timeout=10,
                    ))
                    self.assertEqual(actual, [str(runtime_tmp)] * 3)
                    observed.append((stage, runtime_tmp, kwargs['serialization_fd']))
                    return 1 if stage == failure_stage else 0

                with patch.dict(os.environ, {'TMPDIR': str(inherited_tmp)}), \
                     patch.object(sys, 'argv', ['check_isolated', kind]), \
                     patch.object(check_isolated, 'CHECK_LOCK', root / 'queue.lock'), \
                     patch.object(check_isolated, '_evidence_root', return_value=evidence), \
                     patch.object(check_isolated, 'native_client', return_value={'version': '0.160.0'}), \
                     patch.object(check_isolated, 'prepare_harness', side_effect=prepare), \
                     patch.object(check_isolated, 'run_check', side_effect=run):
                    self.assertEqual(check_isolated.main(), 1 if failure_stage else 0)
                expected = (['baseline_test'] if kind == 'baseline' else
                            ['format', 'lint', 'credo'] if failure_stage else
                            ['format', 'lint', 'credo', 'test', 'dialyzer', 'build'])
                self.assertEqual([stage for stage, _, _ in observed], expected)
                self.assertEqual(len({(path, descriptor) for _, path, descriptor in observed}), 1)
                self.assertFalse(observed[0][1].exists(), 'completed temporary fixtures must be removed')
                self.assertTrue(inherited_tmp.exists())

    @unittest.skipUnless(shutil.which('elixir'), 'requires a real Elixir VM on PATH')
    def test_real_elixir_vm_names_isolate_repeated_checks_after_checker_sigkill(self):
        # This is the same fixture naming/reservation shape as AttemptsTest.
        # The nested VM also proves that TMPDIR crosses an actual VM boundary.
        code = '''
root = Path.join(System.tmp_dir!(), "mvp-attempts-#{System.unique_integer([:positive, :monotonic])}")
File.mkdir_p!(root)
IO.puts(root)
IO.puts(inspect(File.mkdir(Path.join(root, "agent-attempt-1"))))
{nested, 0} = System.cmd(System.find_executable("elixir"), ["-e", "IO.puts(System.tmp_dir!())"])
IO.puts(String.trim(nested))
'''
        elixir = shutil.which('elixir')
        context = multiprocessing.get_context('fork')
        events = context.Queue()
        left_harness = None
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shared = root / 'shared-tmp'
            shared.mkdir()
            vm_environment = dict(os.environ, TMPDIR=str(shared),
                                  ERL_FLAGS='+S 2:2 +SDcpu 1:1 +SDio 1', ERL_ZFLAGS='')

            def vm(environment):
                return subprocess.check_output([elixir, '-e', code], env=environment,
                                               stderr=subprocess.PIPE, text=True, timeout=15).splitlines()

            first, repeated = vm(vm_environment), vm(vm_environment)
            self.assertEqual(first[0], repeated[0], 'independent VMs must reproduce the fixture-name collision')
            self.assertEqual(first[1], ':ok')
            self.assertEqual(repeated[1], '{:error, :eexist}')
            self.assertEqual(first[2], str(shared))
            self.assertEqual(repeated[2], str(shared))

            def check(leave_running):
                def prepare(candidate, baseline, harness, kind):
                    (harness / 'elixir').mkdir()
                    return []

                def run(stage, argv, cwd, environment, **kwargs):
                    events.put(('vm', vm(environment) + [str(cwd.parent)]))
                    if leave_running:
                        # Do not hold a multiprocessing synchronization object
                        # across the deliberate SIGKILL.
                        time.sleep(20)
                    return 0

                with patch.dict(os.environ, vm_environment), \
                     patch.object(sys, 'argv', ['check_isolated', 'baseline']), \
                     patch.object(check_isolated, 'CHECK_LOCK', root / 'queue.lock'), \
                     patch.object(check_isolated, '_evidence_root', return_value=root), \
                     patch.object(check_isolated, 'native_client', return_value={'version': '0.160.0'}), \
                     patch.object(check_isolated, 'prepare_harness', side_effect=prepare), \
                     patch.object(check_isolated, 'run_check', side_effect=run):
                    events.put(('exit', check_isolated.main()))

            first_check = context.Process(target=check, args=(True,))
            next_check = context.Process(target=check, args=(False,))
            try:
                first_check.start()
                event, previous = events.get(timeout=20)
                self.assertEqual(event, 'vm')
                left_tmp = Path(previous[2])
                left_harness = (left_tmp, Path(previous[3]))
                self.assertEqual(previous[1], ':ok')
                self.assertEqual(Path(previous[0]).parent, left_tmp)
                first_check.kill()
                first_check.join(5)
                self.assertEqual(first_check.exitcode, -9)
                self.assertTrue((Path(previous[0]) / 'agent-attempt-1').is_dir(), 'killed checker must leave its fixture')

                next_check.start()
                event, current = events.get(timeout=20)
                self.assertEqual(event, 'vm')
                self.assertEqual(events.get(timeout=5), ('exit', 0))
                next_check.join(5)
                self.assertEqual(next_check.exitcode, 0)
                self.assertEqual(Path(previous[0]).name, Path(current[0]).name)
                self.assertNotEqual(previous[2], current[2])
                self.assertEqual(Path(current[0]).parent, Path(current[2]))
                self.assertEqual(current[1], ':ok', 'new harness must not consume previous VM evidence')
                self.assertFalse(Path(current[2]).exists(), 'normal exit must clean temporary fixtures')
                self.assertFalse(Path(current[3]).exists(), 'normal exit must clean the source harness')
                self.assertTrue((Path(previous[0]) / 'agent-attempt-1').is_dir())
            finally:
                for process in (first_check, next_check):
                    if process.pid is not None:
                        process.join(2)
                        if process.is_alive():
                            process.kill()
                            process.join(2)
                if left_harness is not None:
                    for path in left_harness:
                        shutil.rmtree(path)
                events.close()
                events.join_thread()


class ResourceSetupFailureTest(unittest.TestCase):
    def test_resource_setup_failure_stops_before_stage_dispatch(self):
        for settings in ({'SYMPHONY_CHECK_CPUS': 'invalid', 'SYMPHONY_CHECK_PIDS': '256'},
                         {'SYMPHONY_CHECK_CPUS': '2', 'SYMPHONY_CHECK_PIDS': '256',
                          'ERL_FLAGS': '-extra inherited-marker'}):
            with self.subTest(settings=settings), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                errors = io.StringIO()
                with patch.dict(os.environ, settings, clear=True), patch.object(sys, 'argv', ['check_isolated', 'candidate']), \
                     patch.object(check_isolated, 'CHECK_LOCK', root / 'queue.lock'), \
                     patch.object(check_isolated, '_evidence_root', return_value=root), \
                     patch.object(check_isolated, 'native_client', return_value={'version': '0.160.0'}), \
                     patch.object(check_isolated, 'prepare_harness', return_value=[]), \
                     patch.object(check_isolated, 'run_check') as dispatch, redirect_stderr(errors):
                    self.assertEqual(check_isolated.main(), 1)
                dispatch.assert_not_called()
                output = errors.getvalue()
                self.assertIn('Isolated check setup failed: Erlang resource configuration rejects ', output)
                self.assertEqual(check_results.classify('credo', 4, 'found 1 warning\n' + output), 1)


if __name__ == '__main__':
    unittest.main()
