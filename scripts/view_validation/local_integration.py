#!/usr/bin/env python3
"""Independent Linux subprocess integration on authorized synthetic runtimes.

Never run inside the frozen worker: its no-subprocess policy stays unchanged.
Only this test's HTTP server is started, bound to a random loopback port.
"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

SID = '00000007-0000-4000-8000-000000000040'
SECOND = '00000007-0000-4000-8000-000000000041'
SECRET = 'SYNTHETIC_ENCRYPTED_REASONING_MUST_NOT_LEAK'


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def manifest(root):
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(root.rglob('*')) if path.is_file()}


def make_runtime(root, sid, sandbox=False):
    root.mkdir(parents=True)
    session_dir = root / ('sandboxes/run-1/codex-home/sessions' if sandbox else 'codex-home/sessions')
    session_dir.mkdir(parents=True)
    rows = [
        {'type': 'session_meta', 'timestamp': '2026-10-03T01:00:00Z',
         'payload': {'id': sid, 'cwd': str(root / 'workspaces/GH-7'), 'model': 'fixture-model'}},
        {'type': 'response_item', 'payload': {'type': 'message', 'role': 'user',
         'content': [{'type': 'input_text', 'text': "Implement only this repository's issue: GH-7 Linux integration"}]}},
        {'type': 'response_item', 'payload': {'type': 'reasoning', 'summary': [], 'encrypted_content': SECRET}},
    ]
    for index in range(120):
        rows.append({'type': 'response_item', 'timestamp': '2026-10-03T01:01:00Z',
                     'payload': {'type': 'message', 'role': 'assistant', 'content': [
                         {'type': 'output_text', 'text': 'SYNTHETIC_VISIBLE_OUTPUT_' + str(index)}]}})
    path = session_dir / 'rollout-same.jsonl'
    path.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows), encoding='utf-8')
    state = root / 'state'
    state.mkdir()
    receipt = state / '7.json'
    receipt.write_text(json.dumps({'issue': '7', 'repository': 'fixture/repo',
                                   'workspace': str(root / 'workspaces/GH-7'), 'status': 'coding',
                                   'command': 'touch MUST_NOT_EXECUTE_RECEIPT'}))
    evidence = state / '7.json.evidence/round-1'
    evidence.mkdir(parents=True)
    (evidence / 'check-1.log').write_text('SYNTHETIC_CHECK_LOG\n')
    logdir = root / 'logs/log'
    logdir.mkdir(parents=True)
    (logdir / 'symphony.log').write_text('2026-10-03T01:00:00Z info: SYNTHETIC_CONTROLLER_LOG\n')
    return path, receipt


def integration(stage, output):
    sys.path.insert(0, str(stage / 'app'))
    import run as entry
    from symphony_board import api, collector, context, runtime_source as source
    from symphony_board.config import BoardConfig
    from symphony_board.state import BoardState
    from symphony_board.store import BoardStore
    # Linux-specific descriptor tests live outside cross-platform frozen discovery.
    sys.path.insert(0, str(stage / 'tests'))
    from local_runtime_cases import LocalRuntimeSourceTests
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(LocalRuntimeSourceTests)
    identities = [test.id() for test in suite]
    units = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    require(units.testsRun == len(identities) and units.testsRun > 0 and units.wasSuccessful()
            and not units.skipped, 'independent Linux unit cases must all execute successfully')
    report = {'passed': False, 'fixture_only': True, 'formal_acceptance': False,
              'real_windows_wsl': False, 'browser_ui': False, 'commands': [], 'checks': [],
              'local_unit_tests': {'tests': units.testsRun, 'identities': identities, 'skipped': [], 'passed': True}}
    with tempfile.TemporaryDirectory(prefix='view-linux-source-') as directory:
        private = Path(directory)
        fixtures = private / "fixtures 中文 'space"
        root = fixtures / "runtime 中文 'one"
        other = fixtures / 'runtime-two'
        path, receipt = make_runtime(root, SID)
        make_runtime(other, SECOND, sandbox=True)
        original_manifest = manifest(fixtures)
        cfg = BoardConfig(runtime_glob=str(fixtures / 'runtime*'), transport='local')
        state, raw = BoardState(), api.RawRef()
        store = BoardStore(str(private / 'board.db'))
        server = None
        real_run = subprocess.run
        def allowed_scan(argv, **kwargs):
            require(isinstance(argv, list) and argv[:3] == [sys.executable, '-I', '-B'] and
                    Path(argv[3]).resolve() == (stage / 'app/symphony_board/local_scan.py').resolve(),
                    'only the fixed local scanner subprocess is permitted')
            report['commands'].append(argv)
            return real_run(argv, **kwargs)
        with patch.object(collector, 'BUILD_ROLLOUTS', str(private / 'cache')), \
                patch.object(context, 'BUILD_ROLLOUTS', str(private / 'cache')), \
                patch.object(entry, 'ROOT', str(private)), \
                patch.object(api, 'PROTOTYPE_DIR', str(private / 'prototypes')), \
                patch.object(entry, 'enrich_pulls'), \
                patch.object(source.subprocess, 'run', side_effect=allowed_scan):
            try:
                literal_root, decoy_root = private / '__LOCAL__', private / 'True'
                literal_root.mkdir(); decoy_root.mkdir()
                literal = source.pull_snapshot([str(literal_root)], 'local')
                require([runtime['root'] for runtime in literal['runtimes']] == [str(literal_root)],
                        'literal template-marker root must not select its True decoy')
                report['checks'].append('literal __LOCAL__ root survives real subprocess template generation')
                result = entry.run_cycle(cfg, store, state, raw)
                require(len(result[2]) == 2 and len(result[1]) == 2, 'both Linux runtimes must derive tasks/sessions')
                require(raw.health['status'] == 'ok' and raw.health['source'] == 'local', 'actual source health')
                require(store.history_counts()['sessions'] == 2, 'SQLite stores parsed Linux sessions')
                require(len({session['local'] for session in result[-1]}) == 2, 'same basenames cannot collide')
                require(entry.write_context_pages(cfg, result[-1]), 'real third-party viewer renders Linux copies')
                require(manifest(fixtures) == original_manifest, 'collection leaves source fixture hashes unchanged')
                require(not Path('MUST_NOT_EXECUTE_RECEIPT').exists(), 'receipt commands must never run')
                report['checks'].append('real subprocess -> scan -> immutable copy -> parse -> SQLite -> HTML')
                server = api.BoardHTTPServer(('127.0.0.1', 0), api.make_handler(state, cfg, raw, store))
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                origin = 'http://127.0.0.1:' + str(server.server_address[1])
                def get(route):
                    with urlopen(origin + route, timeout=5) as response:
                        return json.load(response)
                boot = get('/api/bootstrap')
                require(boot['collection']['source'] == 'local', 'HTTP reports actual transport')
                with urlopen(origin + '/api/snapshot', timeout=5) as response:
                    etag = response.headers['ETag']
                    payload = json.load(response)
                require(len(payload['sessions']) == 2, 'HTTP snapshot has both Linux sessions')
                try:
                    urlopen(Request(origin + '/api/snapshot', headers={'If-None-Match': etag}), timeout=5)
                    raise AssertionError('matching ETag must return 304')
                except HTTPError as exc:
                    require(exc.code == 304, 'ETag 304 contract')
                context_route = '/api/sessions/' + SID + '/context?limit=2'
                first = get(context_route)
                require(first['status'] == 'ok' and first['page']['hasOlder'], 'bounded Linux context pagination')
                older = get(context_route + '&before=' + str(first['page']['nextBefore']))
                require(older['page']['nextBefore'] < first['page']['nextBefore'], 'context cursor moves older')
                require(SECRET not in json.dumps(first) + json.dumps(older), 'hidden reasoning is not returned')
                with urlopen(origin + '/prototypes/context-' + SID + '.html', timeout=5) as response:
                    html = response.read().decode()
                require('SYNTHETIC_VISIBLE_OUTPUT_119' in html and SECRET not in html, 'HTTP serves correct sanitized HTML')
                report['checks'].append('loopback HTTP/bootstrap/snapshot/ETag/context pagination/hidden reasoning/HTML')
                previous = state.snapshot()
                old_sources = collector.context_sources(SID)
                old_cache = Path(old_sources[0]['path']).read_bytes()
                old_success = raw.health['lastSuccess']
                receipt_original = receipt.read_bytes()
                for fault in ('bad-json', 'permission', 'timeout', 'disappeared'):
                    if fault == 'bad-json':
                        receipt.write_text('{broken')
                    elif fault == 'permission':
                        path.chmod(0)
                    elif fault == 'disappeared':
                        snapshot = source.pull_snapshot(cfg.globs(), 'local')
                        rollout_original = path.read_bytes()
                        path.unlink()
                    else:
                        snapshot = None
                    manager = patch.object(source, 'TIMEOUT_SECONDS', 0) if fault == 'timeout' else \
                        patch.object(entry, 'pull_snapshot', return_value=snapshot) if fault == 'disappeared' else contextlib.nullcontext()
                    with manager:
                        try:
                            entry.run_cycle(cfg, store, state, raw)
                        except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired):
                            pass
                        else:
                            raise AssertionError('fault must fail collection: ' + fault)
                    require(raw.health['status'] == 'error' and raw.health['lastSuccess'] == old_success,
                            'fault preserves last successful health timestamp')
                    require(state.snapshot() == previous and collector.context_sources(SID) == old_sources,
                            'fault preserves published snapshot and context registry')
                    require(Path(old_sources[0]['path']).read_bytes() == old_cache, 'fault preserves last cache bytes')
                    require(get('/api/bootstrap')['collection']['status'] == 'error', 'HTTP exposes collection failure')
                    if fault == 'bad-json':
                        receipt.write_bytes(receipt_original)
                    elif fault == 'permission':
                        path.chmod(0o644)
                    elif fault == 'disappeared':
                        path.write_bytes(rollout_original)
                entry.run_cycle(cfg, store, state, raw)
                require(raw.health['status'] == 'ok' and raw.health['lastError'] == '', 'collection recovers normally')
                require(manifest(fixtures) == original_manifest, 'final source hashes remain unchanged')
                report['checks'].append('real bad JSON/permission/timeout/disappearance -> preserved snapshot/context/cache -> recovery')
                report['source_sha256_before'] = original_manifest
                report['source_sha256_after'] = manifest(fixtures)
                report['source_unchanged'] = True
                report['passed'] = True
            finally:
                if server:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)
                    report['loopback_service_stopped'] = not thread.is_alive()
                store.close()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {'passed': False}
    try:
        report = integration(args.stage.resolve(), output)
    except Exception as exc:
        report['error'] = f'{type(exc).__name__}: {exc}'
    (output / 'local-integration-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
