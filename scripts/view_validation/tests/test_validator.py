"""Negative evidence checks plus an actual pinned-source fixture worker run."""
import json
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import validator as v


@contextmanager
def synthetic_repo(files):
    with tempfile.TemporaryDirectory(prefix='validator-head-binding-') as tmp:
        base = Path(tmp)
        candidate = base / 'candidate'
        candidate.mkdir()
        setup = base / 'setup'
        setup.mkdir()
        env = v.clean_environment(setup)
        env['GIT_CONFIG_NOSYSTEM'] = '1'
        env['GIT_CONFIG_GLOBAL'] = str(setup / 'absent-global-config')
        def run(*args, input_bytes=None):
            result = subprocess.run(['git', '-C', str(candidate), *args], input=input_bytes,
                                    env=env, capture_output=True, timeout=30)
            if result.returncode:
                raise AssertionError(result.stderr.decode('utf-8', 'replace'))
            return result.stdout.decode('utf-8', 'strict').strip()
        run('init')
        for name, data in files.items():
            target = candidate / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        run('add', '.')
        run('-c', 'user.name=PreparationFixture', '-c', 'user.email=fixture@example.invalid',
            'commit', '-m', 'Synthetic candidate identity regression')
        yield candidate, run('rev-parse', 'HEAD'), run


def python_report(count=16):
    return {'passed': True, 'python': {'passed': True, 'tests': count,
            'identities': [f'case-{n}' for n in range(count)], 'failures': [], 'errors': [],
            'skipped': [], 'expected_failures': [], 'unexpected_successes': []}}


def tap(count=10, skipped=0):
    return f'# tests {count}\n# pass {count-skipped}\n# fail 0\n# cancelled 0\n# skipped {skipped}\n# todo 0\n'


class ValidatorTests(unittest.TestCase):
    def test_python_zero_tests_are_rejected(self):
        with self.assertRaises(ValueError):
            v.validate_python_report(python_report(0), 1)

    def test_skipped_missing_dependency_error_and_fake_success_are_rejected(self):
        for key in ('skipped', 'errors', 'failures', 'expected_failures', 'unexpected_successes'):
            report = python_report()
            report['python'][key] = ['missing dependency or skipped required case']
            with self.subTest(key=key), self.assertRaises(ValueError):
                v.validate_python_report(report, 16)
        with self.assertRaises(ValueError):
            v.validate_python_report({'passed': True}, 16)

    def test_missing_or_duplicate_frozen_identity_is_rejected(self):
        with self.assertRaises(ValueError):
            v.validate_python_report(python_report(), 16, ['missing-frozen-test'])
        report = python_report()
        report['python']['identities'][1] = report['python']['identities'][0]
        with self.assertRaises(ValueError):
            v.validate_python_report(report, 16)

    def test_node_zero_skip_missing_summary_and_contradiction_are_rejected(self):
        for report in (tap(0), tap(10, 1), 'PASS fabricated\n', tap() + '# tests 10\n', tap().replace('# pass 10', '# pass 9')):
            with self.subTest(report=report), self.assertRaises(ValueError):
                v.validate_tap(report, 10)

    def test_added_tests_are_allowed_without_lowering_baseline(self):
        v.validate_python_report(python_report(17), 16)
        self.assertEqual(v.validate_tap(tap(11), 10)['tests'], 11)

    def test_old_pass_is_rejected_after_candidate_change(self):
        old = {'sha': '1' * 40, 'files': {'view/app/a.py': 'before'}}
        for changed in ({'sha': '2' * 40, 'files': old['files']},
                        {'sha': old['sha'], 'files': {'view/app/a.py': 'after'}}):
            with self.assertRaises(ValueError):
                v.stable(old, changed, 'candidate')

    def test_incomplete_or_fabricated_render_report_is_rejected(self):
        for report in ({'passed': True}, {'render': {'passed': True, 'self_check_rendered': True, 'html_pages': []}}):
            with self.assertRaises(ValueError):
                v.validate_render(report)

    def test_view_and_evidence_paths_cannot_escape_candidate(self):
        with tempfile.TemporaryDirectory(prefix='validator-paths-') as tmp:
            root = Path(tmp) / 'candidate'
            (root / 'view').mkdir(parents=True)
            v.check_paths(root, root / 'view', Path(tmp) / 'new-evidence')
            with self.assertRaises(ValueError):
                v.check_paths(root, root / 'view', root / 'evidence')
            with self.assertRaises(ValueError):
                v.check_paths(root, Path(tmp), Path(tmp) / 'new-evidence')

    def test_runtime_config_is_rejected_without_reading_content(self):
        with tempfile.TemporaryDirectory(prefix='validator-config-') as tmp:
            path = Path(tmp) / 'app'
            path.mkdir()
            (path / 'config.toml').write_bytes(b'SYNTHETIC_CONFIG_NOT_READ')
            with patch.object(v, 'read_file', side_effect=AssertionError('must not read excluded config')):
                with self.assertRaises(ValueError):
                    v.inventory(Path(tmp))

    def test_windows_case_aliases_are_rejected_before_body_reads(self):
        for name in ('APP/CONFIG.TOML', 'App/Config.JSON', 'AUTH.JSON', 'Credentials'):
            with tempfile.TemporaryDirectory(prefix='validator-case-') as tmp:
                path = Path(tmp) / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'SYNTHETIC_NOT_READ')
                with patch.object(v, 'read_file', side_effect=AssertionError('must not read excluded body')):
                    with self.assertRaises(ValueError):
                        v.inventory(Path(tmp))
        for name in ('.LOCAL', '.Codex', '.AWS'):
            with tempfile.TemporaryDirectory(prefix='validator-private-') as tmp:
                (Path(tmp) / name).mkdir()
                with patch.object(v, 'read_file', side_effect=AssertionError('must not read private body')):
                    with self.assertRaises(ValueError):
                        v.inventory(Path(tmp))
        with tempfile.TemporaryDirectory(prefix='validator-path-case-') as tmp:
            candidate = Path(tmp) / 'candidate'
            (candidate / 'view').mkdir(parents=True)
            with self.assertRaises(ValueError):
                v.check_paths(candidate, candidate / 'view', Path(tmp) / '.LOCAL' / 'new')
            with self.assertRaises(ValueError):
                v.check_paths(candidate, candidate / 'view', Path(tmp) / 'INNOVATION-SYMPHONY-V0-fixture' / 'new')

    def test_real_dirty_candidate_cannot_bind_to_old_commit(self):
        with tempfile.TemporaryDirectory(prefix='validator-dirty-') as tmp:
            base = Path(tmp)
            candidate = base / 'candidate'
            candidate.mkdir()
            setup = base / 'setup'
            setup.mkdir()
            env = v.clean_environment(setup)
            env['GIT_CONFIG_NOSYSTEM'] = '1'
            env['GIT_CONFIG_GLOBAL'] = str(setup / 'absent-global-config')
            commands = [['git', 'init', str(candidate)], ['git', '-C', str(candidate), 'add', '.'],
                ['git', '-C', str(candidate), '-c', 'user.name=PreparationFixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'Synthetic candidate']]
            source = candidate / 'fixture.txt'
            source.write_bytes(b'SYNTHETIC_BEFORE')
            for args in commands:
                result = subprocess.run(args, env=env, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0)
            sha = v.git(candidate, 'rev-parse', 'HEAD')
            v.candidate_identity(candidate, sha)
            source.write_bytes(b'SYNTHETIC_AFTER')
            with self.assertRaisesRegex(ValueError, 'worktree is dirty'):
                v.candidate_identity(candidate, sha)

    def test_assume_unchanged_and_skip_worktree_cannot_hide_modified_source(self):
        for flag in ('--assume-unchanged', '--skip-worktree'):
            with self.subTest(flag=flag), synthetic_repo({'view/app/fixture.py': b'SYNTHETIC_BEFORE\n'}) as (candidate, sha, run):
                v.candidate_identity(candidate, sha)
                run('update-index', flag, 'view/app/fixture.py')
                (candidate / 'view/app/fixture.py').write_bytes(b'SYNTHETIC_CHANGED\n')
                self.assertEqual(run('status', '--porcelain=v1', '--untracked-files=all'), '')
                with self.assertRaisesRegex(ValueError, 'working bytes differ from HEAD'):
                    v.candidate_identity(candidate, sha)

    def test_ignored_extra_source_and_bytecode_cannot_enter_head_inventory(self):
        for extra in ('view/app/ignored.py', 'view/app/__pycache__/ignored.pyc'):
            with self.subTest(extra=extra), synthetic_repo({'.gitignore': b'ignored.py\n__pycache__/\n',
                    'view/app/fixture.py': b'SYNTHETIC_HEAD\n'}) as (candidate, sha, run):
                target = candidate / extra
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b'SYNTHETIC_IGNORED_EXTRA')
                self.assertEqual(run('status', '--porcelain=v1', '--untracked-files=all'), '')
                with self.assertRaisesRegex(ValueError, 'disk file list differs from HEAD'):
                    v.candidate_identity(candidate, sha)

    def test_head_attributes_allow_only_pure_crlf_with_both_digests(self):
        original = b'print("SYNTHETIC_HEAD")\nprint("SECOND_LINE")\n'
        with synthetic_repo({'.gitattributes': b'*.py text eol=crlf\n', 'view/app/fixture.py': original}) as (candidate, sha, run):
            source = candidate / 'view/app/fixture.py'
            converted = original.replace(b'\n', b'\r\n')
            source.write_bytes(converted)
            identity = v.candidate_identity(candidate, sha)
            self.assertEqual(identity['normalization']['view/app/fixture.py'], 'crlf-to-lf')
            self.assertEqual(identity['files']['view/app/fixture.py'], v.digest(converted))
            self.assertEqual(identity['head_blobs']['view/app/fixture.py']['oid'], v.blob_oid(original))
            run('update-index', '--assume-unchanged', 'view/app/fixture.py')
            source.write_bytes(converted.replace(b'SYNTHETIC_HEAD', b'SYNTHETIC_CHANGED'))
            with self.assertRaisesRegex(ValueError, 'working bytes differ from HEAD'):
                v.candidate_identity(candidate, sha)

    def test_only_head_attributes_are_used_and_unsafe_attributes_fail_closed(self):
        with synthetic_repo({'view/app/fixture.py': b'SYNTHETIC_HEAD\n'}) as (candidate, sha, run):
            info = candidate / '.git/info/attributes'
            info.write_bytes(b'*.py text eol=crlf\n')
            (candidate / 'view/app/fixture.py').write_bytes(b'SYNTHETIC_HEAD\r\n')
            with self.assertRaisesRegex(ValueError, 'working bytes differ from HEAD'):
                v.candidate_identity(candidate, sha)
        for rule in ('filter=synthetic-forbidden', 'working-tree-encoding=UTF-8', 'ident', 'text=unknown'):
            with self.subTest(rule=rule), synthetic_repo({'.gitattributes': ('*.py ' + rule + '\n').encode(),
                    'view/app/fixture.py': b'SYNTHETIC_HEAD\n'}) as (candidate, sha, run):
                with self.assertRaisesRegex(ValueError, 'unsupported HEAD attributes'):
                    v.candidate_identity(candidate, sha)

    def test_head_link_and_submodule_entries_are_rejected_by_metadata(self):
        for mode in ('120000', '160000'):
            with self.subTest(mode=mode), synthetic_repo({'fixture.txt': b'SYNTHETIC_HEAD'}) as (candidate, sha, run):
                oid = sha if mode == '160000' else run('hash-object', '-w', '--stdin', input_bytes=b'SYNTHETIC_LINK_TARGET')
                run('update-index', '--add', '--cacheinfo', mode + ',' + oid + ',special-entry')
                run('-c', 'user.name=PreparationFixture', '-c', 'user.email=fixture@example.invalid',
                    'commit', '-m', 'Synthetic special entry regression')
                new_sha = run('rev-parse', 'HEAD')
                with self.assertRaisesRegex(ValueError, 'links, submodules, or special'):
                    v.candidate_identity(candidate, new_sha)

    def test_staged_changes_cannot_bind_to_old_head_even_if_disk_was_restored(self):
        with synthetic_repo({'fixture.py': b'SYNTHETIC_HEAD'}) as (candidate, sha, run):
            source = candidate / 'fixture.py'
            source.write_bytes(b'SYNTHETIC_STAGED')
            run('add', 'fixture.py')
            source.write_bytes(b'SYNTHETIC_HEAD')
            with self.assertRaisesRegex(ValueError, 'index differs from HEAD'):
                v.candidate_identity(candidate, sha)

    def test_deleted_candidate_tests_are_reported(self):
        self.assertEqual(v.test_changes({'tests/test_removed.py': b'SYNTHETIC_ORIGINAL'}, {}),
                         {'tests/test_removed.py': {'source_sha256': v.digest(b'SYNTHETIC_ORIGINAL'), 'candidate_sha256': None}})

    def test_git_replace_cannot_bind_alternative_tree_to_original_sha(self):
        original = b'SYNTHETIC_ORIGINAL_HEAD\n'
        alternative = b'SYNTHETIC_REPLACEMENT_TREE\n'
        with synthetic_repo({'fixture.py': original}) as (candidate, sha, run):
            source = candidate / 'fixture.py'
            original_tree = run('rev-parse', sha + '^{tree}')
            source.write_bytes(alternative)
            run('add', 'fixture.py')
            run('-c', 'user.name=PreparationFixture', '-c', 'user.email=fixture@example.invalid',
                'commit', '-m', 'Synthetic replacement tree regression')
            replacement = run('rev-parse', 'HEAD')
            replacement_tree = run('rev-parse', replacement + '^{tree}')
            self.assertNotEqual(original_tree, replacement_tree)
            run('update-ref', 'HEAD', sha)
            run('replace', sha, replacement)
            self.assertEqual(run('rev-parse', 'HEAD'), sha)
            self.assertEqual(run('rev-parse', sha + '^{tree}'), replacement_tree)
            self.assertEqual(v.git(candidate, 'rev-parse', sha + '^{tree}'), original_tree)
            # Replacement index and disk must not pass under the original SHA.
            with self.assertRaisesRegex(ValueError, 'index differs from HEAD'):
                v.candidate_identity(candidate, sha)
            run('--no-replace-objects', 'read-tree', sha)
            source.write_bytes(original)
            identity = v.candidate_identity(candidate, sha)
            self.assertEqual(identity['tree'], original_tree)
            self.assertEqual(identity['head_blobs']['fixture.py']['oid'], v.blob_oid(original))
            # Even an original index cannot hide replacement working bytes.
            source.write_bytes(alternative)
            with self.assertRaisesRegex(ValueError, 'working bytes differ from HEAD'):
                v.candidate_identity(candidate, sha)

    def test_browser_binding_and_cleanup_regressions_without_starting_browser(self):
        result = subprocess.run(['node', '--test', '--test-reporter=tap', str(HERE / 'tests/browser_binding.test.cjs')],
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace') + result.stdout.decode('utf-8', 'replace'))
        self.assertEqual(v.validate_tap(result.stdout.decode('utf-8', 'strict'), 16)['tests'], 16)

    def test_bound_copy_rejects_source_changed_before_or_during_read(self):
        with tempfile.TemporaryDirectory(prefix='validator-copy-binding-') as tmp:
            base = Path(tmp)
            view = base / 'view'
            source = view / 'app/fixture.py'
            source.parent.mkdir(parents=True)
            source.write_bytes(b'SYNTHETIC_BOUND_SOURCE')
            expected = v.inventory(view, strict=True)
            source.write_bytes(b'SYNTHETIC_CHANGED_BEFORE_COPY')
            with self.assertRaisesRegex(ValueError, 'changed before copying'):
                v.copy_stage(view, base / 'before-stage', expected)
            self.assertFalse((base / 'before-stage').exists())
            source.write_bytes(b'SYNTHETIC_BOUND_SOURCE')
            original_read = v.read_file
            def transient_read(path):
                if path == source:
                    return b'SYNTHETIC_TRANSIENT_CHANGED_BYTES'
                return original_read(path)
            with patch.object(v, 'inventory', return_value=expected), patch.object(v, 'read_file', side_effect=transient_read):
                with self.assertRaisesRegex(ValueError, 'changed while copying'):
                    v.copy_stage(view, base / 'during-stage', expected)
            self.assertEqual(source.read_bytes(), b'SYNTHETIC_BOUND_SOURCE')
            self.assertFalse((base / 'during-stage/app/fixture.py').exists())

    def test_frozen_stage_uses_authenticated_original_bytes_without_reread(self):
        with tempfile.TemporaryDirectory(prefix='validator-frozen-copy-') as tmp:
            base = Path(tmp)
            view = base / 'view'
            source = view / 'tests/test_frozen.py'
            source.parent.mkdir(parents=True)
            source.write_bytes(b'SYNTHETIC_CANDIDATE_TEST')
            expected = v.inventory(view, strict=True)
            original_read = v.read_file
            def no_frozen_reread(path):
                if path.is_relative_to(HERE / 'frozen'):
                    raise AssertionError('authenticated frozen files must not be reread while copying')
                return original_read(path)
            with patch.object(v, 'read_file', side_effect=no_frozen_reread):
                staged = v.copy_stage(view, base / 'stage', expected, {'tests/test_frozen.py': b'SYNTHETIC_AUTHENTICATED_ORIGINAL'})
            self.assertEqual((base / 'stage/tests/test_frozen.py').read_bytes(), b'SYNTHETIC_AUTHENTICATED_ORIGINAL')
            self.assertEqual(staged['tests/test_frozen.py'], v.digest(b'SYNTHETIC_AUTHENTICATED_ORIGINAL'))

    def test_stage_source_changes_and_extra_source_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix='validator-executed-stage-') as tmp:
            stage = Path(tmp)
            (stage / 'app').mkdir()
            source = stage / 'app/fixture.py'
            source.write_bytes(b'SYNTHETIC_BOUND_SOURCE')
            expected = v.stage_inventory(stage)
            source.write_bytes(b'SYNTHETIC_CHANGED_EXECUTED_SOURCE')
            with self.assertRaisesRegex(ValueError, 'stage source changed'):
                v.verify_stage(stage, expected)
            source.write_bytes(b'SYNTHETIC_BOUND_SOURCE')
            (stage / 'app/extra.py').write_bytes(b'SYNTHETIC_EXTRA_SOURCE')
            with self.assertRaisesRegex(ValueError, 'stage source changed'):
                v.verify_stage(stage, expected)

    def test_actual_worker_renders_frozen_source_and_rejects_broken_candidate(self):
        if not os.environ.get('VIEW_TEST_SOURCE_PACKAGE') or not os.environ.get('VIEW_TEST_SOURCE_MANIFEST'):
            self.fail('set VIEW_TEST_SOURCE_PACKAGE and VIEW_TEST_SOURCE_MANIFEST to a verified source package')
        package = Path(os.environ['VIEW_TEST_SOURCE_PACKAGE'])
        manifest = Path(os.environ['VIEW_TEST_SOURCE_MANIFEST'])
        packager, _ = v.trusted_packager()
        _, files = packager.verify_package(package, manifest)
        with tempfile.TemporaryDirectory(prefix='validator-fixtures-') as tmp:
            base = Path(tmp)
            for label, broken in (('positive', False), ('broken-candidate', True)):
                stage = base / label
                stage.mkdir()
                for name, data in files.items():
                    target = stage / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                for source in (HERE / 'frozen' / 'tests').iterdir():
                    (stage / 'tests' / source.name).write_bytes(source.read_bytes())
                if broken:
                    derive = stage / 'app' / 'symphony_board' / 'derive.py'
                    derive.write_bytes(derive.read_bytes().replace(b'"round": number if known else None', b'"round": 999'))
                evidence = base / (label + '-evidence')
                evidence.mkdir()
                env = v.clean_environment(evidence)
                result = subprocess.run([sys.executable, '-I', '-B', str(HERE / 'worker.py'), '--stage', str(stage),
                    '--fixture', str(HERE / 'fixtures' / 'acceptance.json'), '--evidence', str(evidence), '--render'],
                    env=env, capture_output=True, timeout=60)
                report = json.loads((evidence / 'worker-result.json').read_text(encoding='utf-8'))
                if broken:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(report['passed'])
                else:
                    self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))
                    baseline = json.loads((HERE / 'frozen' / 'baseline.json').read_text(encoding='utf-8'))
                    v.validate_python_report(report, 16, baseline['python_identities'])
                    v.validate_render(report)
                    self.assertEqual(len(list((evidence / 'rendered').glob('context-*.html'))), 6)


if __name__ == '__main__':
    unittest.main(verbosity=2)
