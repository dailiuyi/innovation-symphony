"""Synthetic transport regressions; real subprocess checks run separately."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

APP = str(Path(__file__).resolve().parents[1] / 'app')
if APP not in sys.path:
    sys.path.insert(0, APP)
import run as entry
from symphony_board import api, collector, config, local_files, runtime_source as source, wslpull
from symphony_board.state import BoardState
from symphony_board.store import BoardStore

SID = '00000007-0000-4000-8000-000000000040'


def rollout(path, output='OUTPUT_A'):
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = [
        {'type': 'session_meta', 'payload': {'id': SID, 'cwd': '/workspace/GH-7'}},
        {'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': [
            {'type': 'input_text', 'text': "Implement only this repository's issue: GH-7 synthetic"}]}},
        {'type': 'response_item', 'payload': {'type': 'message', 'role': 'assistant', 'content': [
            {'type': 'output_text', 'text': output}]}},
    ]
    path.write_text(''.join(json.dumps(row) + '\n' for row in rows), encoding='utf-8')
    return path.stat()


def scan(globs, local=True):
    # Execute either embedded scanner branch on synthetic files, without WSL.
    import contextlib
    import io
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        exec(compile(wslpull.remote_script(globs, local=local), '<synthetic-runtime-scan>', 'exec'), {})
    result = json.loads(output.getvalue())
    result['_transport'] = 'local' if local else 'wsl'
    return result


class RuntimeSourceTests(unittest.TestCase):
    def tearDown(self):
        collector.load_sessions({})

    def test_scanner_excludes_operator_audits_without_changing_files_or_legacy_receipts(self):
        for name in ('innovation--luca--GL-4.json', 'legacy-receipt.json'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                state = root / 'state'
                state.mkdir()
                primary = {'issue': 'GL-4', 'issue_identifier': 'GL-4', 'tracker_kind': 'gitlab',
                           'repository': 'innovation/luca', 'status': 'coding'}
                raw = json.dumps(primary, ensure_ascii=False, indent=2) + '\n'
                (state / name).write_text(raw, encoding='utf-8')
                for index, action in enumerate(('operator_prepare_retry', 'operator_runtime_retry')):
                    journal = {'schema': 1, 'issue': 'GL-4', 'action': action, 'receipt_before': raw}
                    (state / f'audit-round-{index + 1}.json').write_text(
                        json.dumps(journal, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
                before = {path.relative_to(root): path.read_bytes() for path in root.rglob('*') if path.is_file()}
                for local in (True, False):
                    with self.subTest(local=local):
                        snapshot = scan([str(root)], local=local)
                        self.assertEqual(len(snapshot['runtimes']), 1)
                        receipts = snapshot['runtimes'][0]['receipts']
                        self.assertEqual(len(receipts), 1)
                        self.assertEqual(receipts[0]['_path'], str(state / name))
                        for key, value in primary.items():
                            self.assertEqual(receipts[0][key], value)
                        after = {path.relative_to(root): path.read_bytes() for path in root.rglob('*') if path.is_file()}
                        self.assertEqual(after, before)

    def test_scanner_preserves_task_receipts_with_only_one_audit_field(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = root / 'state'
            state.mkdir()
            for index, extra in enumerate(({'action': 'historical-task-action'},
                                           {'receipt_before': 'historical-task-field'},
                                           {'metadata': {'action': 'nested', 'receipt_before': 'nested'}})):
                (state / f'legacy-{index}.json').write_text(json.dumps(
                    {'issue': f'GH-{index + 1}', 'status': 'blocked', **extra}), encoding='utf-8')
            for local in (True, False):
                with self.subTest(local=local):
                    receipts = scan([str(root)], local=local)['runtimes'][0]['receipts']
                    self.assertEqual({rec['issue'] for rec in receipts}, {'GH-1', 'GH-2', 'GH-3'})

    def test_platform_auto_and_explicit_override_reject_unsupported(self):
        for platform, expected in [('win32', 'wsl'), ('linux', 'local'), ('linux2', 'local')]:
            self.assertEqual(source.resolve_transport('auto', platform), expected)
            self.assertEqual(source.resolve_transport(expected, platform), expected)
        for mode, platform in [('wsl', 'linux'), ('local', 'win32'), ('auto', 'darwin'),
                               ('invalid', 'linux'), ('', 'linux'), (None, 'linux')]:
            with self.subTest(mode=mode, platform=platform), self.assertRaises(ValueError):
                source.resolve_transport(mode, platform)

    def test_old_config_and_toml_json_transport_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = root / 'old.json'
            old.write_text('{"board":{"interval":9}}')
            self.assertEqual(config.load_config(str(old)).transport, 'auto')
            for platform, mode in [('linux', 'local'), ('win32', 'wsl')]:
                with patch.object(source.sys, 'platform', platform):
                    for suffix, text in [('json', '{"board":{"transport":"' + mode + '"}}'),
                                         ('toml', '[board]\ntransport="' + mode + '"\n')]:
                        path = root / ('config.' + suffix)
                        path.write_text(text)
                        self.assertEqual(config.load_config(str(path)).transport, mode)
                        path.write_text(text.replace(mode, 'invalid'))
                        with self.assertRaises(ValueError):
                            config.load_config(str(path))

    def test_local_argv_is_fixed_array_bounded_and_json_validated(self):
        globs = ["/fixture/中文 space'*/", '/fixture/other*']
        with patch.object(source.sys, 'platform', 'linux'), patch.object(source.subprocess, 'run', return_value=SimpleNamespace(
                returncode=0, stdout=b'{"runtimes":[]}', stderr=b'')) as run:
            self.assertEqual(source.pull_snapshot(globs)['_transport'], 'local')
            argv = run.call_args.args[0]
            self.assertEqual(argv[:3], [sys.executable, '-I', '-B'])
            self.assertEqual(json.loads(argv[-1]), globs)
            self.assertEqual(Path(argv[3]).name, 'local_scan.py')
            self.assertEqual(run.call_args.kwargs['timeout'], 30)
            self.assertNotIn('shell', run.call_args.kwargs)
        cases = [(1, b'{}'), (0, b'{bad'), (0, b'[]'), (0, b'{"runtimes":null}')]
        for code, data in cases:
            with patch.object(source.sys, 'platform', 'linux'), patch.object(source.subprocess, 'run', return_value=SimpleNamespace(
                    returncode=code, stdout=data, stderr=b'fixture failure')), self.assertRaises((RuntimeError, ValueError)):
                source.pull_snapshot(globs)
        with patch.object(source.sys, 'platform', 'linux'), patch.object(source.subprocess, 'run', side_effect=subprocess.TimeoutExpired('scan', 30)), \
                self.assertRaises(subprocess.TimeoutExpired):
            source.pull_snapshot(globs)

    def test_explicit_wsl_preserves_public_snapshot_entrypoint(self):
        with patch.object(source.sys, 'platform', 'win32'), \
                patch.object(wslpull, 'pull_snapshot', return_value={'runtimes': []}) as pull:
            self.assertEqual(source.pull_snapshot(['/fixture'], 'wsl')['_transport'], 'wsl')
            pull.assert_called_once_with(['/fixture'])
        with patch.object(source.sys, 'platform', 'linux'), patch.object(wslpull, 'pull_snapshot') as pull, \
                self.assertRaises(ValueError):
            source.pull_snapshot(['/fixture'], 'wsl')
        pull.assert_not_called()

    def test_wsl_cache_mtime_refresh_atomic_failure_and_safe_quoting(self):
        with tempfile.TemporaryDirectory() as cache:
            remote = "/fixture/quoted' path/rollout-one.jsonl"
            with patch.object(wslpull, 'wsl', return_value='AAAA') as read:
                local = source.copy_session(remote, 4, cache, 'wsl', 1)
                source.copy_session(remote, 4, cache, 'wsl', 1)
                self.assertEqual(read.call_count, 1)
                self.assertIn("'\"'\"'", read.call_args.args[0])
            with patch.object(wslpull, 'wsl', return_value='BBBB'):
                self.assertEqual(source.copy_session(remote, 4, cache, 'wsl', 2), local)
            self.assertEqual(Path(local).read_text(), 'BBBB')
            with patch.object(wslpull, 'wsl', side_effect=RuntimeError('synthetic read failure')), self.assertRaises(RuntimeError):
                source.copy_session(remote, 4, cache, 'wsl', 3)
            self.assertEqual(Path(local).read_text(), 'BBBB')
            with patch.object(wslpull, 'wsl', return_value='CCCC'), \
                    patch.object(source.os, 'replace', side_effect=KeyboardInterrupt()), self.assertRaises(KeyboardInterrupt):
                source.copy_session(remote, 4, cache, 'wsl', 3)
            self.assertEqual(Path(local).read_text(), 'BBBB')
            self.assertFalse(list(Path(cache).glob('.rollout-*.tmp')))


    def test_template_markers_in_globs_remain_literal(self):
        import ast
        globs = ['/fixture/__LOCAL__', '/fixture/__GLOBS__', '/fixture/True']
        for local in (True, False):
            tree = ast.parse(wslpull.remote_script(globs, local=local))
            roots = next(node for node in tree.body if isinstance(node, ast.Assign)
                         and any(isinstance(target, ast.Name) and target.id == 'roots' for target in node.targets))
            self.assertEqual(ast.literal_eval(roots.value.args[0].generators[0].iter), globs)

    def test_failed_wsl_cycle_preserves_old_http_context_and_canonical_keys(self):
        from http.client import HTTPConnection
        from symphony_board import context
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            path = directory / 'fixture.jsonl'
            rollout(path, 'OUTPUT_A'); old_a = path.read_text()
            rollout(path, 'OUTPUT_X'); new_a = path.read_text()
            second_id = '00000007-0000-4000-8000-000000000041'
            old_b = old_a.replace(SID, second_id).replace('OUTPUT_A', 'OUTPUT_B')
            snapshot = {'_transport': 'wsl', 'runtimes': [{'root': '/fixture/runtime', 'receipts': [], 'logs': [],
                        'sessions': [{'path': '/fixture/runtime/codex-home/sessions/rollout-a.jsonl',
                                      'bytes': len(old_a.encode()), 'mtime_ns': 1},
                                     {'path': '/fixture/runtime/codex-home/sessions/rollout-b.jsonl',
                                      'bytes': len(old_b.encode()), 'mtime_ns': 1}]}]}
            newer = json.loads(json.dumps(snapshot))
            for item in newer['runtimes'][0]['sessions']:
                item['mtime_ns'] = 2
            cfg = config.BoardConfig(transport='wsl')
            store = BoardStore(str(directory / 'board.db'))
            state, raw = BoardState(), api.RawRef()
            server = None
            cache = str(directory / 'cache')
            with patch.object(source.sys, 'platform', 'win32'), \
                    patch.object(collector, 'BUILD_ROLLOUTS', cache), \
                    patch.object(context, 'BUILD_ROLLOUTS', cache), patch.object(entry, 'enrich_pulls'):
                try:
                    with patch.object(entry, 'pull_snapshot', return_value=snapshot), \
                            patch.object(wslpull, 'wsl', side_effect=[old_a, old_b]):
                        entry.run_cycle(cfg, store, state, raw)
                    previous = state.snapshot()
                    old_sources = collector.context_sources(SID)
                    old_cache = Path(old_sources[0]['path']).read_bytes()
                    legacy = hashlib.sha256(snapshot['runtimes'][0]['sessions'][0]['path'].encode()).hexdigest()[:16]
                    canonical = Path(cache) / (legacy + '-rollout-a.jsonl')
                    self.assertTrue(canonical.is_file())
                    with patch.object(entry, 'pull_snapshot', return_value=newer), \
                            patch.object(wslpull, 'wsl', side_effect=[new_a, RuntimeError('second synthetic WSL read failed')]), \
                            self.assertRaises(RuntimeError):
                        entry.run_cycle(cfg, store, state, raw)
                    self.assertEqual(state.snapshot(), previous)
                    self.assertEqual(collector.context_sources(SID), old_sources)
                    self.assertEqual(Path(old_sources[0]['path']).read_bytes(), old_cache)
                    self.assertEqual(raw.health['status'], 'error')
                    server = api.BoardHTTPServer(('127.0.0.1', 0), api.make_handler(state, cfg, raw, store))
                    thread = threading.Thread(target=server.serve_forever, daemon=True)
                    thread.start()
                    def http_context():
                        connection = HTTPConnection('127.0.0.1', server.server_address[1], timeout=5)
                        try:
                            connection.request('GET', '/api/sessions/' + SID + '/context')
                            response = connection.getresponse()
                            self.assertEqual(response.status, 200)
                            return json.loads(response.read())
                        finally:
                            connection.close()
                    payload = http_context()
                    self.assertEqual(payload['latestAssistant']['text'], 'OUTPUT_A')
                    self.assertEqual(previous[0]['sessions'][0]['lastOutput'], 'OUTPUT_A')
                    with patch.object(entry, 'pull_snapshot', return_value=newer), \
                            patch.object(wslpull, 'wsl', return_value=old_b):
                        entry.run_cycle(cfg, store, state, raw)
                    self.assertEqual(raw.health['status'], 'ok')
                    self.assertEqual(state.snapshot()[0]['sessions'][0]['lastOutput'], 'OUTPUT_X')
                    self.assertEqual(http_context()['latestAssistant']['text'], 'OUTPUT_X')
                finally:
                    if server:
                        server.shutdown(); server.server_close(); thread.join(timeout=5)
                    store.close()


if __name__ == '__main__':
    unittest.main()
