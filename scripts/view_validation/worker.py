"""Trusted fixture worker. Only synthetic, copied source is executed here."""
from __future__ import annotations

import argparse
import ast
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
WORKER_PATH = Path(__file__).resolve()
_WORKER_MODULE = sys.modules[__name__]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def deny_process(*args, **kwargs):
    raise RuntimeError('fixture worker forbids real subprocess/collector execution')


def loopback_connect(original):
    def connect(sock, address):
        if not isinstance(address, tuple) or address[0] not in ('127.0.0.1', '::1', 'localhost'):
            raise RuntimeError('fixture worker forbids external network connections')
        return original(sock, address)
    return connect


def flattened(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from flattened(test)
        else:
            yield test


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def function_code(value):
    function = getattr(value, '__func__', value)
    return getattr(function, '__code__', None)


def file_digest(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
        raise RuntimeError('trusted worker input is missing, linked, special, or oversized')
    return sha256(path.read_bytes())


def stage_test_inventory(stage):
    """Bind just test inputs; generated build/_tmp/fixture-runtime files are allowed."""
    root = Path(stage) / 'tests'
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError('Python test input directory is missing or linked')
    rows = {}
    for base, directories, files in os.walk(root, followlinks=False):
        base_path = Path(base)
        for name in list(directories):
            path = base_path / name
            if path.is_symlink():
                raise RuntimeError('Python test input contains a symlink')
            if name == '__pycache__':
                directories.remove(name)
        for name in files:
            path = base_path / name
            if '__pycache__' in path.parts or path.suffix == '.pyc':
                continue
            mode = path.lstat().st_mode
            if not stat.S_ISREG(mode) or path.stat().st_size > 16 * 1024 * 1024:
                raise RuntimeError('Python test input contains a special or oversized file')
            rows[path.relative_to(root).as_posix()] = file_digest(path)
    return dict(sorted(rows.items()))


def frozen_input_inventory():
    baseline_path = HERE / 'frozen' / 'baseline.json'
    baseline_data = baseline_path.read_bytes()
    baseline = json.loads(baseline_data)
    files = {}
    for row in baseline['files']:
        path = HERE / 'frozen' / row['path']
        actual = file_digest(path)
        if actual != row['sha256']:
            raise RuntimeError('trusted frozen test differs from its baseline digest')
        files[row['path']] = actual
    return {'baseline.json': sha256(baseline_data), 'files': dict(sorted(files.items()))}


def test_runner_hooks():
    loader = unittest.defaultTestLoader
    runner = unittest.TextTestRunner
    suite = unittest.TestSuite
    result = unittest.TestResult
    text_result = unittest.TextTestResult
    methods = {
        'loader_discover': unittest.TestLoader.discover,
        'runner_init': runner.__init__,
        'runner_run': runner.run,
        'runner_make_result': runner._makeResult,
        'suite_iter': suite.__iter__,
        'suite_run': suite.run,
        'case_run': unittest.TestCase.run,
        'result_was_successful': result.wasSuccessful,
        'text_result_add_success': text_result.addSuccess,
        'text_result_add_failure': text_result.addFailure,
        'text_result_add_error': text_result.addError,
        'text_result_add_skip': text_result.addSkip,
    }
    return {'loader': loader, 'runner_class': runner, 'suite_class': suite,
            'result_class': result, 'text_result_class': text_result, 'methods': methods,
            'method_codes': {name: function_code(value) for name, value in methods.items()},
            'loader_discover_bound': loader.discover}


def capture_worker_integrity(stage, trusted_functions):
    module_globals = _WORKER_MODULE.__dict__
    function_names = ('require', 'deny_process', 'loopback_connect', 'flattened', 'sha256',
                      'function_code', 'file_digest', 'stage_test_inventory', 'frozen_input_inventory',
                      'test_runner_hooks', 'capture_worker_integrity', 'activate_sandbox_hooks', 'assert_worker_integrity',
                      'run_tests', 'render_fixture')
    function_refs = {name: module_globals[name] for name in function_names}
    module_names = ('argparse', 'ast', 'hashlib', 'importlib', 'json', 'os', 'Path',
                    're', 'socket', 'stat', 'subprocess', 'sys', 'tempfile', 'unittest', 'patch')
    module_refs = {name: module_globals[name] for name in module_names}
    constant_names = ('HERE', 'WORKER_PATH', '_WORKER_MODULE')
    constant_refs = {name: module_globals[name] for name in constant_names}
    trusted_services = {'metadata_version': importlib.metadata.version}
    return {
        'module': _WORKER_MODULE,
        'module_name': module_globals['__name__'],
        'module_globals': module_globals,
        'function_refs': function_refs,
        'function_codes': {name: function_code(value) for name, value in function_refs.items()},
        'module_refs': module_refs,
        'constant_refs': constant_refs,
        'trusted_services': trusted_services,
        'framework': test_runner_hooks(),
        'worker_sha256': file_digest(WORKER_PATH),
        'frozen_inputs': frozen_input_inventory(),
        'stage_test_inputs': stage_test_inventory(stage),
        'sys_path': tuple(sys.path),
        'expected_sys_path': tuple(sys.path),
        'runtime_hooks': None,
        'trusted_run_tests': trusted_functions['run_tests'],
        'trusted_render_fixture': trusted_functions['render_fixture'],
        'trusted_guard': trusted_functions['guard'],
    }


def activate_sandbox_hooks(integrity, guarded_connect):
    integrity['runtime_hooks'] = {
        'subprocess_run': deny_process,
        'subprocess_popen': deny_process,
        'socket_connect': guarded_connect,
    }


def assert_worker_integrity(integrity, stage, phase):
    """Reject changes to the trusted runner or the exact test inputs it executes."""
    changed = []
    module_globals = integrity['module_globals']
    if sys.modules.get(integrity['module_name']) is not integrity['module']:
        changed.append('worker module identity')
    if module_globals.get('__file__') != str(integrity['constant_refs']['WORKER_PATH']):
        changed.append('worker source path')
    for name, expected in integrity['constant_refs'].items():
        if module_globals.get(name) is not expected:
            changed.append(name + ' constant')
    for name, expected in integrity['function_refs'].items():
        actual = module_globals.get(name)
        if actual is not expected:
            changed.append(name + ' reference')
        elif function_code(actual) is not integrity['function_codes'][name]:
            changed.append(name + ' code')
    for name, expected in integrity['module_refs'].items():
        if module_globals.get(name) is not expected:
            changed.append(name + ' module reference')
    if importlib.metadata.version is not integrity['trusted_services']['metadata_version']:
        changed.append('package version reader')
    framework = integrity['framework']
    if (unittest.defaultTestLoader is not framework['loader']
            or unittest.TextTestRunner is not framework['runner_class']
            or unittest.TestSuite is not framework['suite_class']
            or unittest.TestResult is not framework['result_class']
            or unittest.TextTestResult is not framework['text_result_class']):
        changed.append('unittest runner object')
    for name, expected in framework['methods'].items():
        owner, attribute = {
            'loader_discover': (unittest.TestLoader, 'discover'),
            'runner_init': (unittest.TextTestRunner, '__init__'),
            'runner_run': (unittest.TextTestRunner, 'run'),
            'runner_make_result': (unittest.TextTestRunner, '_makeResult'),
            'suite_iter': (unittest.TestSuite, '__iter__'),
            'suite_run': (unittest.TestSuite, 'run'),
            'case_run': (unittest.TestCase, 'run'),
            'result_was_successful': (unittest.TestResult, 'wasSuccessful'),
            'text_result_add_success': (unittest.TextTestResult, 'addSuccess'),
            'text_result_add_failure': (unittest.TextTestResult, 'addFailure'),
            'text_result_add_error': (unittest.TextTestResult, 'addError'),
            'text_result_add_skip': (unittest.TextTestResult, 'addSkip'),
        }[name]
        actual = getattr(owner, attribute)
        if actual is not expected or function_code(actual) is not framework['method_codes'][name]:
            changed.append('unittest.' + name)
    if framework['loader'].discover.__func__ is not framework['methods']['loader_discover']:
        changed.append('unittest default loader binding')
    if file_digest(integrity['constant_refs']['WORKER_PATH']) != integrity['worker_sha256']:
        changed.append('worker source bytes')
    if frozen_input_inventory() != integrity['frozen_inputs']:
        changed.append('trusted frozen test inputs')
    if stage_test_inventory(stage) != integrity['stage_test_inputs']:
        changed.append('stage test inputs')
    if tuple(sys.path) != integrity['expected_sys_path']:
        changed.append('module search path')
    runtime = integrity['runtime_hooks']
    if runtime is not None and (subprocess.run is not runtime['subprocess_run']
                                or subprocess.Popen is not runtime['subprocess_popen']
                                or socket.socket.connect is not runtime['socket_connect']):
        changed.append('process/network isolation hook')
    if changed:
        raise RuntimeError('worker integrity changed ' + phase + ': ' + ', '.join(sorted(set(changed))))


def run_tests(stage, integrity, guard):
    guard(integrity, stage, 'before test discovery')
    stage_tests = str((stage / 'tests').resolve())
    expected_after_discovery = integrity['sys_path']
    if stage_tests not in expected_after_discovery:
        expected_after_discovery = (stage_tests,) + expected_after_discovery
    suite = integrity['framework']['loader_discover_bound'](
        str(stage / 'tests'), pattern='test_*.py')
    # unittest.TestLoader.discover legitimately prepends its top-level test
    # directory to sys.path. Permit only that exact standard-library change;
    # candidate imports cannot add, remove, or reorder any other entries.
    if tuple(sys.path) != expected_after_discovery:
        raise RuntimeError('worker integrity changed after candidate test import: module search path')
    integrity['expected_sys_path'] = expected_after_discovery
    # Importing test modules is candidate code execution; validate before any
    # discovered TestCase or reporting function is called.
    guard(integrity, stage, 'after candidate test import')
    identities = [test.id() for test in integrity['function_refs']['flattened'](suite)]
    guard(integrity, stage, 'after test identity collection')
    runner = integrity['framework']['runner_class'](stream=sys.stderr, verbosity=2)
    result = runner.run(suite)
    guard(integrity, stage, 'after candidate test execution')
    if not isinstance(result, integrity['framework']['text_result_class']) or result.testsRun != len(identities):
        raise RuntimeError('captured unittest runner returned an incomplete result')
    return {'tests': result.testsRun, 'identities': identities,
            'failures': [test.id() for test, _ in result.failures],
            'errors': [test.id() for test, _ in result.errors],
            'skipped': [{'id': test.id(), 'reason': reason} for test, reason in result.skipped],
            'expected_failures': [test.id() for test, _ in result.expectedFailures],
            'unexpected_successes': [test.id() for test in result.unexpectedSuccesses],
            'passed': result.wasSuccessful() and result.testsRun > 0 and not result.skipped}


def render_fixture(stage, fixture_path, evidence, integrity, guard):
    guard(integrity, stage, 'before fixture imports')
    from symphony_board import collector, context, pagegen, wslpull
    from symphony_board.derive import build_stories, build_tasks
    from symphony_board.selfcheck import self_check
    guard(integrity, stage, 'after fixture imports')

    require(importlib.metadata.version('codex-transcript-viewer') == '0.5.0',
            'frozen rendering dependency must be codex-transcript-viewer==0.5.0')
    self_check()  # Includes an actual third-party HTML render; never substitute once.
    guard(integrity, stage, 'after self_check rendering')
    fixture = json.loads(fixture_path.read_text(encoding='utf-8'))
    cache = stage / 'build' / 'rollouts'
    cache.mkdir(parents=True, exist_ok=True)
    collector.BUILD_ROLLOUTS = str(cache)
    context.BUILD_ROLLOUTS = str(cache)
    sessions, events = [], []
    evidence_dir = stage / 'fixture-runtime' / 'receipt.json.evidence'
    evidence_dir.mkdir(parents=True)
    for spec in fixture['sessions']:
        sid = spec['id']
        role = spec['role']
        prompt = fixture['issuedInstruction'] if role == 'coder' else 'Independently review GH-7: synthetic validation.'
        rows = [
            {'timestamp': fixture['timestamp'], 'type': 'session_meta', 'payload': {
                'id': sid, 'session_id': sid, 'cwd': fixture['workspace'], 'cli_version': 'fixture'}},
            {'timestamp': fixture['timestamp'], 'type': 'turn_context', 'payload': {'model': 'fixture-model', 'cwd': '/workspace'}},
            {'timestamp': fixture['timestamp'], 'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
                'type': 'UserMessage', 'content': [{'type': 'text', 'text': prompt}]}}},
            {'timestamp': fixture['timestamp'], 'type': 'response_item', 'payload': {'type': 'reasoning', 'summary': [],
                'encrypted_content': fixture['encryptedMarker']}},
            {'timestamp': fixture['timestamp'], 'type': 'response_item', 'payload': {'type': 'custom_tool_call',
                'name': 'fixture_tool', 'input': 'FIXTURE_TOOL_INPUT'}},
            {'timestamp': fixture['timestamp'], 'type': 'response_item', 'payload': {'type': 'custom_tool_call_output',
                'output': 'FIXTURE_TOOL_OUTPUT'}},
            {'timestamp': fixture['timestamp'], 'type': 'response_item', 'payload': {'type': 'message', 'role': 'assistant',
                'phase': 'final_answer', 'content': [{'type': 'output_text', 'text': spec['text']}]}}
        ]
        rollout = cache / ('rollout-' + sid + '.jsonl')
        rollout.write_text(''.join(json.dumps(row) + '\n' for row in rows), encoding='utf-8')
        parsed = collector.parse_rollout(str(rollout))
        parsed.update(local=str(rollout), remote='/fixture/rollout-' + sid + '.jsonl', bytes=rollout.stat().st_size)
        sessions.append(parsed)
        attempt = spec['attempt']
        if attempt is None:
            continue
        attempt_dir = evidence_dir / 'round-19' / ('agent-attempt-' + str(attempt))
        attempt_dir.mkdir(parents=True)
        turn = '00000000-0000-4000-8000-' + f'{attempt:012d}'
        (attempt_dir / 'messages.log').write_text(
            f'%{{session_id: "{sid}-{turn}", event: :session_started, thread_id: "{sid}"}}\n', encoding='utf-8')
        usage = role + '_attempt_' + str(attempt)
        events.append({'role': role, 'attempt': attempt, 'stage_attempt': spec['stageAttempt'], 'status': 'started',
                       'usage_key': usage, 'evidence': str(attempt_dir)})
        outcome = ('{:error, :mvp_invalid_review}' if spec['outcome'] == 'invalid_review' else
                   '{:ok, %{session_id: "' + sid + '-' + turn + '", output_text: "' + fixture['outcomeProseMarker'] + '"}}')
        events.append({'role': role, 'status': 'finished', 'usage_key': usage, 'outcome': outcome})

    # Execute only the pure helper prefix of the remote script on synthetic files.
    namespace = {}
    exec(compile(wslpull.remote_script(['/fixture-unused']).split('roots = sorted(', 1)[0], '<fixture-remote-helpers>', 'exec'), namespace)
    attempts = namespace['_agent_attempts']({'recovery': {'events': events}}, str(evidence_dir))
    receipt = {'issue': fixture['issue'], 'repository': fixture['repository'], 'workspace': fixture['workspace'],
               'status': 'reviewing', 'reason': '', 'candidate_sha': fixture['candidateSha'],
               'rounds': [{'round': n, 'status': 'reviewing'} for n in range(1, 20)], '_agent_attempts': attempts,
               '_path': '/fixture/receipt.json'}
    snapshot = {'runtimes': [{'root': fixture['runtimeRoot'], 'receipts': [receipt], 'evidence': [], 'logs': []}]}
    tasks = build_tasks(snapshot, sessions, {})
    require(len(tasks) == 1 and tasks[0]['issueLabel'] == 'GH-7', 'one synthetic GH-7 task must be derived')
    task = tasks[0]
    require(task['roundsAuthority'] == 'controller' and len(task['rounds']) == 19, 'controller round authority/count')
    reviews = [s for s in task['sessions'] if s['role'] == 'Review' and s['round'] == 19]
    require([s['attempt'] for s in reviews] == [41, 42, 43, 44], 'review retries must remain in round 19')
    require([s['stageAttempt'] for s in reviews] == [1, 2, 3, 1], 'stage retry identities must be retained')
    require([s['attemptOutcome'] for s in reviews] == ['invalid_review'] * 3 + ['completed'], 'review outcome classification')
    require(task['sessions'][-1]['round'] is None and task['sessions'][-1]['roundSource'] == 'unassigned', 'unmapped session cannot invent a round')
    require(fixture['outcomeProseMarker'] not in json.dumps(attempts), 'raw outcome prose must not leak')
    require(len(build_stories(tasks)) == 1, 'task must produce a story')
    html_pages = pagegen.viewer_pages(sessions, 5, back_url='/#/board')
    expected = {'context-' + s['id'] + '.html' for s in fixture['sessions']}
    require({name for name, _ in html_pages} == expected and len(html_pages) == len(expected), 'all six full-ID pages must render without collisions')
    html_root = evidence / 'rendered'
    html_root.mkdir()
    for name, html in html_pages:
        spec = next(s for s in fixture['sessions'] if name == 'context-' + s['id'] + '.html')
        require(spec['text'] in html and 'GH-7' in html, 'HTML must contain the matching fixture session')
        require('id="messages"' in html and 'id="tree-container"' in html, 'real viewer HTML shell is required')
        require(html.count('href="/#/board"') >= 2 and 'refreshSilent' in html, 'board backlinks and silent refresh')
        require(re.search(r'data-transcript="[0-9a-f]{20}"', html), 'rendered page must carry a transcript token')
        require(fixture['encryptedMarker'] not in html and 'http-equiv="refresh"' not in html, 'encrypted reasoning/reload must be absent')
        pagegen.write_if_changed(str(html_root / name), html)
    first = collector.public_session(sessions[0])
    response = context.read_session_context(first['id'], first, ({'path': sessions[0]['local'], 'name': 'fixture.jsonl'},), limit=50)
    require(response['status'] == 'ok' and response['session']['issuedInstruction'] == fixture['issuedInstruction'], 'context API must preserve fixture instruction')
    require(response['session']['model'] == 'fixture-model' and response['session']['workdir'] == '/workspace', 'context model/workdir provenance')
    require(fixture['encryptedMarker'] not in json.dumps(response), 'context response must not expose encrypted reasoning')
    public_task = {key: value for key, value in task.items() if key not in ('receipt', '_matched')}
    payload = {'generated': '生成 Fixture', 'interval': 3600, 'tasks': [public_task],
               'stories': build_stories([public_task]), 'sessions': [collector.public_session(s) for s in sessions],
               'logs': [], 'runtimes': [{'name': 'fixture', 'root': fixture['runtimeRoot']}]}
    contexts = {}
    for session in sessions:
        public = collector.public_session(session)
        contexts[public['id']] = context.read_session_context(public['id'], public,
            ({'path': session['local'], 'name': 'fixture.jsonl'},), limit=100)
    (evidence / 'fixture-snapshot.json').write_text(json.dumps(payload, ensure_ascii=False), encoding='utf-8')
    (evidence / 'fixture-contexts.json').write_text(json.dumps(contexts, ensure_ascii=False), encoding='utf-8')

    # Exercise Windows command construction without executing wsl.exe or reading WSL.
    calls = []
    def fake_run(args, **kwargs):
        calls.append(args)
        return type('Result', (), {'returncode': 0, 'stdout': b'{"runtimes": []}', 'stderr': b''})()
    # This test exercises Windows argv construction, not Windows path semantics.
    # Linux has no drive-letter cwd, so map the fixture path before calling it.
    with patch.object(wslpull, 'to_wsl_path', return_value='/mnt/z/fixture-unused.py'), \
            patch.object(subprocess, 'run', fake_run):
        require(wslpull.pull_snapshot(['Z:/fixture-unused.py']) == {'runtimes': []}, 'mock WSL snapshot decode')
    require(len(calls) == 1 and calls[0][:3] == ['wsl.exe', '-e', 'python3'], 'Windows-to-WSL argv contract')
    require(calls[0][3] == '/mnt/z/fixture-unused.py', 'Windows-to-WSL path translation')
    source = ast.parse((stage / 'app' / 'run.py').read_text(encoding='utf-8'))
    once = [n for n in ast.walk(source) if isinstance(n, ast.If) and isinstance(n.test, ast.Name) and n.test.id == 'once']
    require(len(once) == 1 and not any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'write_context_pages'
            for stmt in once[0].body for n in ast.walk(stmt)), 'normal once must not be substituted for render')
    return {'passed': True, 'self_check_rendered': True, 'tasks': len(tasks), 'rounds': 19, 'review_retries': 4,
            'unassigned_sessions': 1, 'html_pages': sorted(expected), 'wsl_executed': False, 'fixture_only': True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--render', action='store_true')
    args = parser.parse_args()
    sys.path.insert(0, str(args.stage / 'app'))
    os.chdir(args.stage)
    private_tmp = args.stage / '_tmp'
    private_tmp.mkdir()
    tempfile.tempdir = str(private_tmp)
    report = {'passed': False, 'fixture_only': True, 'formal_acceptance': False}
    # Keep callable references and their fingerprints before any candidate
    # module can import into this interpreter or edit __main__.
    trusted_run_tests = run_tests
    trusted_render_fixture = render_fixture
    trusted_guard = assert_worker_integrity
    try:
        integrity = capture_worker_integrity(args.stage, {
            'run_tests': trusted_run_tests,
            'render_fixture': trusted_render_fixture,
            'guard': trusted_guard,
        })
        report['worker_integrity'] = {
            'worker_sha256': integrity['worker_sha256'],
            'frozen_inputs': integrity['frozen_inputs'],
            'stage_test_inputs': integrity['stage_test_inputs'],
            'captured_runner': True,
        }
        trusted_guard(integrity, args.stage, 'before candidate import')
        guarded_connect = loopback_connect(socket.socket.connect)
        with patch.object(subprocess, 'run', deny_process), \
                patch.object(subprocess, 'Popen', deny_process), \
                patch.object(socket.socket, 'connect', guarded_connect) as patched_connect:
            activate_sandbox_hooks(integrity, patched_connect)
            trusted_guard(integrity, args.stage, 'before candidate import')
            from symphony_board import wslpull
            trusted_guard(integrity, args.stage, 'after candidate import')
            wslpull.wsl = deny_process
            report['python'] = trusted_run_tests(args.stage, integrity, trusted_guard)
            require(report['python']['passed'], 'Python suite failed, skipped, errored, or executed zero tests')
            if args.render:
                trusted_guard(integrity, args.stage, 'before captured render')
                report['render'] = trusted_render_fixture(args.stage, args.fixture, args.evidence,
                                                          integrity, trusted_guard)
            trusted_guard(integrity, args.stage, 'after candidate execution')
        report['dependencies'] = {'python': sys.version, 'executable': sys.executable,
                                  'codex-transcript-viewer': importlib.metadata.version('codex-transcript-viewer')}
        report['passed'] = True
    except Exception as exc:
        report['error'] = f'{type(exc).__name__}: {exc}'
        print(report['error'], file=sys.stderr)
    (args.evidence / 'worker-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
