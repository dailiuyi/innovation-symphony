"""Adversarial source/preseed tests using disposable Git repositories only."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_view_source as source


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='view-preparation-test-')
        self.root = Path(self.temporary.name)
        self.repo = self.root / 'fixture-repository'
        self.repo.mkdir()
        home = self.root / 'fixture-home'
        home.mkdir()
        self.environment = {key: value for key, value in os.environ.items()
                            if key.upper() in {'PATH', 'SYSTEMROOT', 'WINDIR', 'TEMP', 'TMP', 'COMSPEC', 'PATHEXT'}}
        self.environment.update(HOME=str(home), USERPROFILE=str(home))
        self.command('init', '--quiet')
        self.command('config', 'user.name', 'Sanitized fixture')
        self.command('config', 'user.email', 'fixture@example.invalid')
        files = {'app/config.toml': b'DO_NOT_READ_RUNTIME_CONFIGURATION\n',
                 'app/config.example.toml': b'port = 8765\n',
                 'app/run.py': b'print("fixture")\n', 'tests/test_fixture.py': b'# fixed fixture\n'}
        for name, data in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.command('add', '.')
        self.command('commit', '--quiet', '-m', 'Sanitized fixture')
        self.policy = source.Policy(self.command('rev-parse', 'HEAD').strip(),
                                    self.command('rev-parse', 'HEAD^{tree}').strip(), 'fixture://sanitized')
        self.output = self.root / 'artifact'
        self.manifest = source.build(self.repo, self.output, self.policy)
        self.package = self.output / 'view-source.zip'
        self.manifest_path = self.output / 'source-manifest.json'

    def tearDown(self):
        self.temporary.cleanup()

    def command(self, *args):
        result = subprocess.run(['git', '-C', str(self.repo), *args], env=self.environment,
                                capture_output=True, encoding='utf-8', timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def forge(self, *, mutate_files=None, mutate_manifest=None, extra=None):
        document, files = source.verify_package(self.package, self.manifest_path, self.policy)
        document = json.loads(json.dumps(document))
        document.pop('archive')
        files = dict(files)
        if mutate_files:
            mutate_files(files)
        if mutate_manifest:
            mutate_manifest(document, files)
        forged = self.root / 'forged.zip'
        with zipfile.ZipFile(forged, 'w') as archive:
            archive.writestr(*source.zip_entry(source.INTERNAL_MANIFEST, source.canonical(document)))
            for name, data in sorted(files.items()):
                archive.writestr(*source.zip_entry(name, data))
            if extra:
                archive.writestr(extra[0], extra[1])
        data = forged.read_bytes()
        document['archive'] = {'name': 'view-source.zip', 'bytes': len(data), 'sha256': source.sha256(data)}
        manifest = self.root / 'forged-manifest.json'
        manifest.write_bytes(source.canonical(document))
        return forged, manifest

    def test_reproducible_archive_and_manifest(self):
        second = self.root / 'second-artifact'
        source.build(self.repo, second, self.policy)
        self.assertEqual(self.package.read_bytes(), (second / 'view-source.zip').read_bytes())
        self.assertEqual(self.manifest_path.read_bytes(), (second / 'source-manifest.json').read_bytes())

    def test_excluded_configuration_blob_is_never_read(self):
        excluded = self.command('rev-parse', 'HEAD:app/config.toml').strip()
        original = source.git

        def guarded(repo, *args):
            if args == ('cat-file', 'blob', excluded):
                self.fail('runtime configuration content was read')
            return original(repo, *args)

        with patch.object(source, 'git', side_effect=guarded):
            manifest = source.build(self.repo, self.root / 'guarded', self.policy)
        self.assertIs(manifest['excluded'][0]['content_read'], False)
        self.assertNotIn(b'DO_NOT_READ_RUNTIME_CONFIGURATION', self.package.read_bytes())

    def test_fixed_objects_ignore_dirty_checkout_and_untracked_files(self):
        (self.repo / 'app/run.py').write_bytes(b'UNCOMMITTED_CHANGE\n')
        (self.repo / 'untracked-secret.txt').write_bytes(b'UNTRACKED_FIXTURE\n')
        other = self.root / 'dirty-checkout-artifact'
        source.build(self.repo, other, self.policy)
        self.assertEqual(self.package.read_bytes(), (other / 'view-source.zip').read_bytes())

    def test_head_mismatch_stops_export(self):
        with self.assertRaisesRegex(ValueError, 'HEAD'):
            source.build(self.repo, self.root / 'wrong-head', source.Policy('0' * 40, self.policy.tree))

    def test_head_drift_during_export_stops_export(self):
        original = source.git
        heads = 0

        def drifting(repo, *args):
            nonlocal heads
            if args == ('rev-parse', 'HEAD'):
                heads += 1
                if heads == 2:
                    return b'0000000000000000000000000000000000000000\n'
            return original(repo, *args)

        with patch.object(source, 'git', side_effect=drifting), self.assertRaisesRegex(ValueError, 'changed'):
            source.build(self.repo, self.root / 'drift', self.policy)
        self.assertFalse((self.root / 'drift').exists())

    def test_rewritten_file_and_all_declarations_cannot_forge_frozen_tree(self):
        def rewrite(document, files):
            entry = next(x for x in document['included'] if x['path'] == 'app/run.py')
            data = files[entry['path']]
            entry.update(bytes=len(data), sha256=source.sha256(data), git_oid=source.git_object('blob', data))

        paths = self.forge(mutate_files=lambda files: files.update({'app/run.py': b'FORGED_CANDIDATE\n'}),
                           mutate_manifest=rewrite)
        with self.assertRaisesRegex(ValueError, 'frozen Git tree'):
            source.verify_package(*paths, self.policy)

    def test_wrong_archive_digest_is_rejected(self):
        document = json.loads(self.manifest_path.read_bytes())
        document['archive']['sha256'] = '0' * 64
        self.manifest_path.write_bytes(source.canonical(document))
        with self.assertRaisesRegex(ValueError, 'digest'):
            source.verify_package(self.package, self.manifest_path, self.policy)

    def test_missing_source_file_is_rejected(self):
        paths = self.forge(mutate_files=lambda files: files.pop('app/run.py'))
        with self.assertRaisesRegex(ValueError, 'inventory'):
            source.verify_package(*paths, self.policy)

    def test_extra_file_is_rejected(self):
        paths = self.forge(extra=source.zip_entry('unexpected.txt', b'not approved'))
        with self.assertRaisesRegex(ValueError, 'inventory'):
            source.verify_package(*paths, self.policy)

    def test_traversal_and_windows_aliases_are_rejected(self):
        for name in ['../escape', '/absolute', 'C:/absolute', 'a\\b', 'a/../b', 'a//b',
                     'CON.txt', 'nul', 'a.', 'a ', 'file:stream', 'a\x00b']:
            with self.subTest(name=repr(name)), self.assertRaises(ValueError):
                source.safe_name(name)
        paths = self.forge(extra=source.zip_entry('../escape.py', b'escape'))
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            source.verify_package(*paths, self.policy)
        self.assertFalse((self.root.parent / 'escape.py').exists())

    def test_archive_link_is_rejected(self):
        info, data = source.zip_entry('link', b'/outside', '120777')
        paths = self.forge(extra=(info, data))
        with self.assertRaisesRegex(ValueError, 'unsafe archive'):
            source.verify_package(*paths, self.policy)

    def test_case_colliding_archive_entries_are_rejected(self):
        paths = self.forge(extra=source.zip_entry('APP/run.py', b'case collision'))
        with self.assertRaisesRegex(ValueError, 'unsafe archive'):
            source.verify_package(*paths, self.policy)

    def test_tree_rejects_submodules_links_and_path_collisions(self):
        for mode in ['120000', '160000']:
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                source.reconstruct_tree([{'path': 'link', 'mode': mode, 'git_oid': '0' * 40}])
        with self.assertRaises(ValueError):
            source.reconstruct_tree([{'path': 'app', 'mode': '100644', 'git_oid': '0' * 40},
                                     {'path': 'app/run.py', 'mode': '100644', 'git_oid': '0' * 40}])

    def test_linked_destination_is_rejected_before_writes(self):
        with patch.object(Path, 'is_symlink', return_value=True), self.assertRaises(ValueError):
            source.extract_package(self.package, self.manifest_path, self.root / 'linked', self.policy)
        self.assertFalse((self.root / 'linked').exists())

    def test_safe_extraction_retains_example_without_configuration_or_git(self):
        destination = self.root / 'extracted'
        source.extract_package(self.package, self.manifest_path, destination, self.policy)
        self.assertTrue((destination / 'app/config.example.toml').is_file())
        self.assertFalse((destination / 'app/config.toml').exists())
        self.assertFalse((destination / '.git').exists())
        self.assertEqual((destination / 'app/run.py').read_bytes(), b'print("fixture")\n')

    def test_existing_output_or_destination_is_preserved(self):
        for method in [lambda: source.build(self.repo, self.output, self.policy),
                       lambda: source.extract_package(self.package, self.manifest_path, self.output, self.policy)]:
            before = self.manifest_path.read_bytes()
            with self.assertRaises(FileExistsError):
                method()
            self.assertEqual(self.manifest_path.read_bytes(), before)

    def test_pseudo_preseed_precedes_claim_and_survives_mkdir(self):
        root = self.root / 'pseudo-task'
        report = source.pseudo_task(self.package, self.manifest_path, root, self.policy)
        self.assertEqual(report['events'], ['source_verified', 'source_preseeded', 'pseudo_claim_recorded',
                                           'executor_mkdir_preserved_preseed'])
        self.assertFalse(report['production_claim'])
        self.assertFalse(report['execution_started'])
        self.assertFalse(report['sandbox_mount_executed'])
        self.assertFalse(report['formal_acceptance'])
        seeded = root / 'pseudo-receipt.json.evidence/view-source/view-source.zip'
        self.assertEqual(source.sha256(seeded.read_bytes()), self.manifest['archive']['sha256'])

    def test_runtime_and_local_pseudo_targets_are_rejected(self):
        for root in [self.root / '.local/task', self.root / 'innovation-symphony-v0-rerun1/fake',
                     self.root / '.LOCAL/task', self.root / 'INNOVATION-SYMPHONY-V0-rerun1/fake']:
            with self.subTest(root=str(root)), self.assertRaises(ValueError):
                source.pseudo_task(self.package, self.manifest_path, root, self.policy)
            self.assertFalse(root.exists())

    def test_relative_pseudo_target_checks_cwd_ancestors(self):
        previous = Path.cwd()
        working = self.root / '.LOCAL'
        working.mkdir()
        try:
            os.chdir(working)
            with self.assertRaises(ValueError):
                source.pseudo_task(self.package, self.manifest_path, Path('relative-task'), self.policy)
        finally:
            os.chdir(previous)
        self.assertFalse((working / 'relative-task').exists())


if __name__ == '__main__':
    unittest.main()
