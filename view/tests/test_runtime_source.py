"""Synthetic transport regressions; real subprocess checks run separately."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import stat
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
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


def scan(globs):
    # Exercise the shared scanner in the frozen worker without a subprocess.
    import contextlib
    import io
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        exec(compile(wslpull.remote_script(globs, local=True), '<synthetic-local-scan>', 'exec'), {})
    result = json.loads(output.getvalue())
    result['_transport'] = 'local'
    return result


class RuntimeSourceTests(unittest.TestCase):
    def tearDown(self):
        collector.load_sessions({})

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
            for suffix, text in [('json', '{"board":{"transport":"local"}}'),
                                 ('toml', '[board]\ntransport="local"\n')]:
                path = root / ('config.' + suffix)
                path.write_text(text)
                self.assertEqual(config.load_config(str(path)).transport, 'local')
                path.write_text(text.replace('local', 'invalid'))
                with self.assertRaises(ValueError):
                    config.load_config(str(path))

    def test_local_argv_is_fixed_array_bounded_and_json_validated(self):
        globs = ["/fixture/中文 space'*/", '/fixture/other*']
        with patch.object(source.subprocess, 'run', return_value=SimpleNamespace(
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
            with patch.object(source.subprocess, 'run', return_value=SimpleNamespace(
                    returncode=code, stdout=data, stderr=b'fixture failure')), self.assertRaises((RuntimeError, ValueError)):
                source.pull_snapshot(globs)
        with patch.object(source.subprocess, 'run', side_effect=subprocess.TimeoutExpired('scan', 30)), \
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

    def test_multiglob_unicode_top_level_sandbox_and_receipts_are_readonly(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "运行 root'quote"
            first = root / 'codex-home/sessions/date/rollout-first.jsonl'
            second = root / 'sandboxes/run-1/codex-home/sessions/rollout-second.jsonl'
            rollout(first); rollout(second)
            state = root / 'state/receipt.json'
            state.parent.mkdir()
            state.write_text(json.dumps({'issue': '7', 'repository': 'fixture/repo',
                                         'command': 'touch SHOULD_NOT_EXECUTE'}))
            before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
            found = scan([str(root.parent / '运行*'), str(root), str(root.parent / 'missing*')])
            self.assertEqual(len(found['runtimes']), 1)
            sessions = found['runtimes'][0]['sessions']
            self.assertEqual({item['path'] for item in sessions}, {str(first), str(second)})
            self.assertTrue(all(isinstance(item['mtime_ns'], int) for item in sessions))
            after = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
            self.assertEqual(before, after)
            self.assertFalse(Path('SHOULD_NOT_EXECUTE').exists())

    def test_local_cache_path_normalization_same_basename_and_cross_transport(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, cache = Path(tmp) / 'runtime', str(Path(tmp) / 'cache')
            path = root / 'codex-home/sessions/rollout-same.jsonl'
            stat = rollout(path)
            a = source.copy_session(str(path), stat.st_size, cache, 'local', stat.st_mtime_ns, str(root))
            b = source.copy_session(str(path.parent / '.' / path.name), stat.st_size, cache, 'local', stat.st_mtime_ns, str(root))
            self.assertEqual(a, b)
            other = Path(tmp) / 'other/codex-home/sessions/rollout-same.jsonl'
            info = rollout(other)
            c = source.copy_session(str(other), info.st_size, cache, 'local', info.st_mtime_ns, str(Path(tmp) / 'other'))
            with patch.object(wslpull, 'wsl', return_value=path.read_text()):
                d = source.copy_session(str(path), stat.st_size, cache)
            self.assertEqual(len({a, c, d}), 3)
            legacy = hashlib.sha256(str(path).encode()).hexdigest()[:16] + '-' + path.name
            self.assertEqual(Path(d).name, legacy)

    def test_same_length_growth_truncation_and_old_versions_remain_intact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, cache = Path(tmp) / 'runtime', str(Path(tmp) / 'cache')
            path = root / 'codex-home/sessions/rollout-update.jsonl'
            info = rollout(path)
            first = source.copy_session(str(path), info.st_size, cache, 'local', info.st_mtime_ns, str(root))
            original = Path(first).read_bytes()
            info2 = rollout(path, 'OUTPUT_B')
            os.utime(path, ns=(info2.st_atime_ns, info.st_mtime_ns + 1_000_000))
            info2 = path.stat()
            self.assertEqual(info.st_size, info2.st_size)
            second = source.copy_session(str(path), info2.st_size, cache, 'local', info2.st_mtime_ns, str(root))
            self.assertNotEqual(first, second)
            self.assertIn('OUTPUT_B', Path(second).read_text())
            for output in ['OUTPUT_C_GROWN', 'X']:
                info3 = rollout(path, output)
                copied = source.copy_session(str(path), info3.st_size, cache, 'local', info3.st_mtime_ns, str(root))
                self.assertEqual(Path(copied).read_bytes(), path.read_bytes())
            self.assertEqual(Path(first).read_bytes(), original)
            with self.assertRaises(RuntimeError):
                source.copy_session(str(path), info.st_size, cache, 'local', info.st_mtime_ns, str(root))

    def test_atomic_interruption_and_concurrent_copies(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, cache = Path(tmp) / 'runtime', str(Path(tmp) / 'cache')
            path = root / 'codex-home/sessions/rollout-concurrent.jsonl'
            info = rollout(path)
            target = Path(tmp) / 'old'
            target.write_bytes(b'LAST_SUCCESS')
            def interrupted(handle):
                handle.write(b'PARTIAL')
                raise KeyboardInterrupt()
            with self.assertRaises(KeyboardInterrupt):
                source._atomic_write(str(target), interrupted)
            self.assertEqual(target.read_bytes(), b'LAST_SUCCESS')
            self.assertFalse(list(Path(tmp).glob('.rollout-*.tmp')))
            with ThreadPoolExecutor(max_workers=4) as pool:
                paths = list(pool.map(lambda _: source.copy_session(str(path), info.st_size, cache,
                                      'local', info.st_mtime_ns, str(root)), range(8)))
            self.assertEqual(len(set(paths)), 1)
            self.assertEqual(Path(paths[0]).read_bytes(), path.read_bytes())
            self.assertFalse(list(Path(cache).glob('.rollout-*.tmp')))

    def test_source_mutation_during_copy_leaves_no_partial_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, cache = Path(tmp) / 'runtime', str(Path(tmp) / 'cache')
            path = root / 'codex-home/sessions/rollout-changing.jsonl'
            info = rollout(path)
            atomic = source._atomic_write
            def mutate_then_write(local, writer):
                os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns + 1_000_000))
                return atomic(local, writer)
            with patch.object(source, '_atomic_write', side_effect=mutate_then_write), self.assertRaises(RuntimeError):
                source.copy_session(str(path), info.st_size, cache, 'local', info.st_mtime_ns, str(root))
            self.assertFalse(list(Path(cache).iterdir()))

    def test_forbidden_outside_symlink_and_special_sources_never_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'runtime'
            path = root / 'codex-home/sessions/rollout-good.jsonl'
            info = rollout(path)
            cache = str(Path(tmp) / 'cache')
            outside = Path(tmp) / 'outside/rollout-good.jsonl'
            outside.parent.mkdir()
            outside.write_text('PRIVATE_OUTSIDE')
            linked = path.parent / 'rollout-link.jsonl'
            linked.symlink_to(outside)
            with self.assertRaises((PermissionError, OSError)):
                source.copy_session(str(linked), outside.stat().st_size, cache, 'local', outside.stat().st_mtime_ns, str(root))
            with self.assertRaises(PermissionError):
                source.copy_session(str(outside), 1, cache, 'local', 1, str(root))
            with self.assertRaises((PermissionError, OSError)):
                scan([str(root)])
            linked.unlink()
            alias = Path(tmp) / 'alias'
            alias.symlink_to(root, target_is_directory=True)
            with self.assertRaises((PermissionError, OSError)):
                scan([str(alias)])
            fifo = path.parent / 'rollout-fifo.jsonl'
            os.mkfifo(fifo)
            with self.assertRaises(PermissionError):
                source.copy_session(str(fifo), 0, cache, 'local', 1, str(root))
            with patch.object(local_files.os, 'open') as opened, self.assertRaises(PermissionError):
                local_files.open_artifact('/root/.codex/sessions', '/root/.codex/sessions/rollout-denied.jsonl')
            opened.assert_not_called()

    def test_forbidden_glob_match_is_rejected_before_directory_open(self):
        # Simulate discovery without inspecting any real protected directory.
        with patch.object(local_files, '_directory', return_value=99), \
                patch.object(local_files.os, 'listdir', return_value=['sessions']), \
                patch.object(local_files.os, 'stat', return_value=SimpleNamespace(st_mode=stat.S_IFDIR)), \
                patch.object(local_files.os, 'close'), \
                patch.object(local_files.os, 'open', return_value=100) as opened, self.assertRaises(PermissionError):
            local_files.glob_directories('/root/.codex/*')
        self.assertEqual([call.args[0] for call in opened.call_args_list], ['root', '.codex'])

    def test_bad_receipt_disappearing_file_and_unreadable_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'runtime'
            path = root / 'codex-home/sessions/rollout-disappear.jsonl'
            info = rollout(path)
            path.unlink()
            with self.assertRaises(FileNotFoundError):
                source.copy_session(str(path), info.st_size, str(Path(tmp) / 'cache'), 'local', info.st_mtime_ns, str(root))
            receipt = root / 'state/bad.json'
            receipt.parent.mkdir(); receipt.write_text('{broken')
            with self.assertRaises(ValueError):
                scan([str(root)])
            with patch.object(local_files.os, 'open', side_effect=PermissionError('synthetic denied')), self.assertRaises(PermissionError):
                scan([str(root)])

    def test_failed_cycle_keeps_snapshot_registry_cache_and_recovers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'runtime'
            path = root / 'codex-home/sessions/rollout-preserve.jsonl'
            rollout(path)
            cfg = config.BoardConfig(runtime_glob=str(root), transport='local')
            store = BoardStore(str(Path(tmp) / 'board.db'))
            state, raw = BoardState(), api.RawRef()
            with patch.object(collector, 'BUILD_ROLLOUTS', str(Path(tmp) / 'cache')), \
                    patch.object(entry, 'pull_snapshot', side_effect=lambda *args, **kwargs: scan(cfg.globs())), \
                    patch.object(entry, 'enrich_pulls'):
                try:
                    entry.run_cycle(cfg, store, state, raw)
                    old_state, old_raw = state.snapshot(), raw.raw
                    old_sources = collector.context_sources(SID)
                    old_cache = Path(old_sources[0]['path']).read_bytes()
                    old_health = dict(raw.health)
                    rollout(path, 'OUTPUT_B')
                    bad = root / 'codex-home/sessions/rollout-zz-broken.jsonl'
                    bad.write_text('{broken\n')
                    with self.assertRaises(ValueError):
                        entry.run_cycle(cfg, store, state, raw)
                    self.assertEqual(state.snapshot(), old_state)
                    self.assertEqual(raw.raw, old_raw)
                    self.assertEqual(collector.context_sources(SID), old_sources)
                    self.assertEqual(Path(old_sources[0]['path']).read_bytes(), old_cache)
                    self.assertEqual(raw.health['status'], 'error')
                    self.assertEqual(raw.health['source'], 'local')
                    self.assertEqual(raw.health['lastSuccess'], old_health['lastSuccess'])
                    bad.unlink()
                    entry.run_cycle(cfg, store, state, raw)
                    self.assertEqual(raw.health['status'], 'ok')
                    self.assertEqual(raw.health['lastError'], '')
                    self.assertIn('OUTPUT_B', state.snapshot()[0]['sessions'][0]['lastOutput'])
                finally:
                    store.close()

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


if __name__ == '__main__':
    unittest.main()
