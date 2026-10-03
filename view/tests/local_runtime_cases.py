"""Linux-only synthetic FD/copy checks, run outside the frozen worker phase."""
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from test_runtime_source import SID, rollout, scan
import run as entry
from symphony_board import api, collector, config, local_files, runtime_source as source, wslpull
from symphony_board.state import BoardState
from symphony_board.store import BoardStore


class LocalRuntimeSourceTests(unittest.TestCase):
    def tearDown(self):
        collector.load_sessions({})

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


    def test_literal_template_marker_root_does_not_select_true_decoy(self):
        with tempfile.TemporaryDirectory() as tmp:
            configured, decoy = Path(tmp) / '__LOCAL__', Path(tmp) / 'True'
            configured.mkdir(); decoy.mkdir()
            found = scan([str(configured)])
            self.assertEqual([runtime['root'] for runtime in found['runtimes']], [str(configured)])
