"""Frozen policy remains effective when the candidate attempts to weaken its gate."""
from pathlib import Path
import sys
import tempfile
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


if __name__ == '__main__':
    unittest.main()
