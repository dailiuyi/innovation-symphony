import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

APP_DIR = str(Path(__file__).resolve().parents[1] / 'app')
if APP_DIR not in sys.path:
    sys.path.insert(0, APP_DIR)

from symphony_board.collector import display_title, parse_rollout
from symphony_board.common import issue_from_cwd, issue_from_prompt, receipt_issue_identifier, repo_of
from symphony_board.config import BoardConfig, RepoCfg
from symphony_board.context import _safe_workdir
from symphony_board.derive import build_tasks, build_stories, enrich_pulls, parse_pull_request, safe_web_url


class GitLabViewTests(unittest.TestCase):
    def test_gitlab_rollout_parses_prompt_roles_title_and_workspace(self):
        for prefix in ('GH', 'GL'):
            gid = f'{prefix}-42'
            prompts = [(f"Implement only this repository's issue: {gid} Fix luca.", 'Fix luca.'),
                       (f'Independently review {gid}: Check luca.', 'Check luca.')]
            for prompt, title in prompts:
                self.assertEqual(issue_from_prompt(prompt), gid)
                self.assertEqual(display_title(prompt), title)
            self.assertEqual(issue_from_prompt(f'Diagnose repeated or unclassified technical failures for {gid}.'), gid)
            self.assertEqual(issue_from_cwd(f'/runtime/workspaces/{gid}/backend'), gid)
            self.assertEqual(_safe_workdir(f'/runtime/workspaces/{gid}'), f'workspaces/{gid}')
        rows = [
            {'type': 'session_meta', 'payload': {'id': 'gitlab-session', 'cwd': '/runtime/sandboxes/coder'}},
            {'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': [
                {'type': 'input_text', 'text': "Implement only this repository's issue: GL-42 Fix luca."}]}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'rollout.jsonl'
            path.write_text('\n'.join(json.dumps(row) for row in rows) + '\n')
            parsed = parse_rollout(str(path))
        self.assertEqual(parsed['issue'], 'GL-42')

    def test_native_repository_metadata_and_historic_fallback(self):
        receipt = {'issue_native_ref': {'project_path': 'team/subgroup/luca', 'iid': 42}}
        self.assertEqual(repo_of(receipt), 'team/subgroup/luca')
        self.assertEqual(receipt_issue_identifier(receipt), 'GL-42')
        self.assertEqual(receipt_issue_identifier({'issue': 42}), 'GH-42')
        self.assertEqual(receipt_issue_identifier({'issue': 42, 'tracker_kind': 'gitlab'}), 'GL-42')
        cfg = BoardConfig(repos=[RepoCfg('other/repo')])
        self.assertEqual(cfg.pending({'runtimes': [{'root': '/runtime', 'receipts': [receipt]}]}),
                         [{'runtime': 'runtime', 'repo': 'team/subgroup/luca'}])

    def test_mixed_tracker_same_number_keeps_sessions_and_stories_separate(self):
        receipts, sessions = [], []
        for prefix in ('GH', 'GL'):
            gid = f'{prefix}-42'
            receipt = {'issue': '42', 'repository': 'team/luca', 'workspace': f'/runtime/workspaces/{gid}',
                       'status': 'awaiting_review', '_path': f'/runtime/state/{gid}.json'}
            if prefix == 'GL':
                receipt.update(tracker_kind='gitlab', issue_identifier=gid,
                               issue_url='https://gitlab.example/team/luca/-/issues/42',
                               pull_request='https://gitlab.example/team/luca/-/merge_requests/3')
            receipts.append(receipt)
            sessions.append({'meta': {'session_id': gid}, 'cwd': f'/runtime/sandboxes/{gid}',
                             'prompt': f"Implement only this repository's issue: {gid} Fix {prefix}.",
                             'issue': gid, 'entries': 1, 'counts': {'reasoning': 0, 'tool': 0},
                             'agent_msgs': [], 'bytes': 0})
        tasks = build_tasks({'runtimes': [{'root': '/runtime', 'receipts': receipts}]}, sessions, {})
        with patch('symphony_board.derive.fetch_pr') as fetch:
            enrich_pulls(tasks)
            fetch.assert_not_called()
        stories = build_stories(tasks)
        self.assertEqual(len(stories), 2)
        by_label = {task['issueLabel']: task for task in tasks}
        for gid, task in by_label.items():
            self.assertEqual([s['id'] for s in task['sessions']], [gid])
            self.assertTrue(task['id'].endswith(gid))
        gitlab = next(s for s in stories if s['issueLabel'] == 'GL-42')
        self.assertTrue(gitlab['id'].endswith('GL-42'))
        self.assertEqual(gitlab['issueUrl'], receipts[1]['issue_url'])
        self.assertEqual(gitlab['pr']['state'], 'unknown')
        self.assertIn('MR #3', gitlab['outcomeDetail'])
        self.assertIn('Draft MR', by_label['GL-42']['result'])
        self.assertNotIn('issueUrl', by_label['GH-42'])

    def test_merge_request_links_keep_host_and_nested_namespace_without_github_queries(self):
        url = 'http://gitlab.internal:8080/team/subgroup/luca/-/merge_requests/123'
        parsed = parse_pull_request(url)
        self.assertEqual(parsed, {'repo': 'team/subgroup/luca', 'number': 123, 'url': url, 'kind': 'merge_request'})
        task = {'pullRequest': url}
        with patch('symphony_board.derive.subprocess.run') as run:
            enrich_pulls([task])
            run.assert_not_called()
        self.assertEqual(task['pr']['url'], url)
        self.assertEqual(task['pr']['state'], 'unknown')
        self.assertEqual(parse_pull_request('https://github.com/team/luca/pull/123'),
                         {'repo': 'team/luca', 'number': 123, 'url': 'https://github.com/team/luca/pull/123'})
        for invalid in ('javascript:alert(1)', 'https://user:secret@gitlab.example/team/luca/-/merge_requests/1',
                        'https://gitlab.example/team/luca/-/merge_requests/nope'):
            self.assertIsNone(parse_pull_request(invalid))
        self.assertFalse(safe_web_url('javascript:alert(1)'))


if __name__ == '__main__':
    unittest.main()
