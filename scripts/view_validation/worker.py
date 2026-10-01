"""Trusted fixture worker. Only synthetic, copied source is executed here."""
from __future__ import annotations

import argparse
import ast
import importlib.metadata
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True


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


def run_tests(stage):
    suite = unittest.defaultTestLoader.discover(str(stage / 'tests'), pattern='test_*.py')
    identities = [test.id() for test in flattened(suite)]
    result = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    return {'tests': result.testsRun, 'identities': identities,
            'failures': [test.id() for test, _ in result.failures],
            'errors': [test.id() for test, _ in result.errors],
            'skipped': [{'id': test.id(), 'reason': reason} for test, reason in result.skipped],
            'expected_failures': [test.id() for test, _ in result.expectedFailures],
            'unexpected_successes': [test.id() for test in result.unexpectedSuccesses],
            'passed': result.wasSuccessful() and result.testsRun > 0 and not result.skipped}


def render_fixture(stage, fixture_path, evidence):
    from symphony_board import collector, context, pagegen, wslpull
    from symphony_board.derive import build_stories, build_tasks
    from symphony_board.selfcheck import self_check

    require(importlib.metadata.version('codex-transcript-viewer') == '0.5.0',
            'frozen rendering dependency must be codex-transcript-viewer==0.5.0')
    self_check()  # Includes an actual third-party HTML render; never substitute once.
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
    with patch.object(subprocess, 'run', fake_run):
        require(wslpull.pull_snapshot(['/fixture-unused']) == {'runtimes': []}, 'mock WSL snapshot decode')
    require(len(calls) == 1 and calls[0][:3] == ['wsl.exe', '-e', 'python3'], 'Windows-to-WSL argv contract')
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
    try:
        from symphony_board import wslpull
        wslpull.wsl = deny_process
        with patch.object(subprocess, 'run', deny_process), patch.object(subprocess, 'Popen', deny_process), \
                patch.object(socket.socket, 'connect', loopback_connect(socket.socket.connect)):
            report['python'] = run_tests(args.stage)
            require(report['python']['passed'], 'Python suite failed, skipped, errored, or executed zero tests')
            if args.render:
                report['render'] = render_fixture(args.stage, args.fixture, args.evidence)
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
