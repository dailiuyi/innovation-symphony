import json
import os
import sys
import tempfile
import unittest

APP_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app")
if APP_DIR not in sys.path:
    sys.path.insert(0, APP_DIR)

from symphony_board.derive import build_tasks, result_text
from symphony_board.wslpull import remote_script


def attempt_reader():
    """Compile only the helper definitions from the WSL-side snapshot script."""
    source = remote_script(["/unused-runtime"])
    prefix = source.split("roots = sorted(", 1)[0]
    namespace = {}
    exec(compile(prefix, "<wslpull-attempt-helpers>", "exec"), namespace)
    return namespace["_agent_attempts"]


class RoundMappingTests(unittest.TestCase):
    def test_current_review_does_not_repeat_previous_check_failure(self):
        evidence = [{"name": "round-19/check-1.log", "exit": 124, "summary": "previous check timeout", "under": [], "tail": False}]
        text = result_text("reviewing", "", "abcd123", [], evidence)
        self.assertIn("正在进行独立审查", text)
        self.assertNotIn("previous check timeout", text)
        text = result_text("blocked", ":mvp_invalid_review", "abcd123", [], evidence)
        self.assertIn("协议校验", text)
        self.assertNotIn("检查未通过", text)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="round-mapping-")
        self.evidence = os.path.join(self.temp.name, "receipt.json.evidence")
        os.makedirs(self.evidence)
        self.read_attempts = attempt_reader()

    def tearDown(self):
        self.temp.cleanup()

    def event_pair(self, events, attempt, round_no, role, stage_attempt, thread_id,
                   outcome):
        directory = os.path.join(self.evidence, f"round-{round_no}", f"agent-attempt-{attempt}")
        os.makedirs(directory)
        second_uuid = f"00000000-0000-4000-8000-{attempt:012d}"
        session_id = f"{thread_id}-{second_uuid}"
        with open(os.path.join(directory, "messages.log"), "w", encoding="utf-8") as handle:
            handle.write(
                "%{timestamp: ~U[2026-09-30 01:02:03Z], "
                f'session_id: "{session_id}", event: :session_started, '
                f'thread_id: "{thread_id}", turn_id: "{second_uuid}"}}\n'
            )
        usage_key = f"{role}_attempt_{attempt}"
        events.append({
            "attempt": attempt,
            "evidence": directory,
            "role": role,
            "stage_attempt": stage_attempt,
            "status": "started",
            "usage_key": usage_key,
        })
        if outcome is not None:
            events.append({
                "role": role,
                "status": "finished",
                "usage_key": usage_key,
                "outcome": outcome,
            })

    def test_reviewer_retries_keep_receipt_round_and_sanitize_outcomes(self):
        events = []
        review_ids = [
            "01a0f20b-c08a-7aa2-a970-359551e1ce53",
            "01a0f213-806f-79d1-bffe-bd31274c83f6",
            "01a0f21b-4278-7922-a181-a6980d26aefe",
            "01a0f25f-f48e-7863-8adf-9acaa790ce9a",
        ]
        for attempt, (thread_id, stage_attempt) in enumerate(zip(review_ids, (1, 2, 3, 1)), 41):
            if attempt < 44:
                outcome = "{:error, :mvp_invalid_review}"
            else:
                outcome = (
                    '{:ok, %{result: :turn_completed, session_id: '
                    f'"{thread_id}-00000000-0000-4000-8000-{attempt:012d}", '
                    'output_text: "The transcript mentions timeout and invalid_review."}}'
                )
            self.event_pair(events, attempt, 19, "reviewer", stage_attempt,
                            thread_id, outcome)

        coder_id = "01a0f268-dbb8-74b2-80b7-8bea22888710"
        self.event_pair(events, 45, 20, "coder", 1, coder_id,
                        "{:error, :mvp_recovery_resource_exhausted}")
        running_id = "01a0f277-3356-77d0-9a2b-9357a4d1199e"
        self.event_pair(events, 47, 20, "reviewer", 1, running_id, None)
        receipt = {"recovery": {"events": events}}

        rows = self.read_attempts(receipt, self.evidence)
        by_attempt = {row["attempt"]: row for row in rows}

        self.assertEqual(set(by_attempt), {41, 42, 43, 44, 45, 47})
        self.assertEqual([by_attempt[n]["round"] for n in (41, 42, 43, 44)], [19] * 4)
        self.assertEqual([by_attempt[n]["stageAttempt"] for n in (41, 42, 43, 44)], [1, 2, 3, 1])
        self.assertEqual([by_attempt[n]["session_id"] for n in (41, 42, 43, 44)], review_ids)
        self.assertEqual([by_attempt[n]["outcome"] for n in (41, 42, 43)], ["invalid_review"] * 3)
        self.assertEqual([by_attempt[n]["status"] for n in (41, 42, 43)], ["failed"] * 3)
        self.assertEqual(by_attempt[44]["outcome"], "completed")
        self.assertEqual(by_attempt[44]["status"], "completed")
        self.assertEqual(by_attempt[45]["round"], 20)
        self.assertEqual(by_attempt[45]["role"], "coder")
        self.assertEqual(by_attempt[45]["status"], "failed")
        self.assertEqual(by_attempt[47]["status"], "running")
        self.assertEqual(by_attempt[47]["outcome"], "running")
        self.assertNotIn("mvp_invalid_review", json.dumps(rows))
        self.assertNotIn("timeout and invalid_review", json.dumps(rows))

    def test_diagnosis_attempt_is_preserved_as_its_own_role(self):
        events = []
        thread_id = "01a0f2aa-5e31-7c11-8064-80953381e8f9"
        self.event_pair(events, 46, 20, "diagnosis", 1, thread_id,
                        "{:error, :mvp_recovery_resource_exhausted}")

        rows = self.read_attempts({"recovery": {"events": events}}, self.evidence)

        self.assertEqual(rows, [{
            "session_id": thread_id,
            "round": 20,
            "attempt": 46,
            "stageAttempt": 1,
            "role": "diagnosis",
            "status": "failed",
            "outcome": "failed",
            "roundSource": "evidence",
        }])

    def test_event_limit_keeps_both_records_for_500_attempts(self):
        events = []
        for attempt in range(1, 501):
            thread_id = f"00000000-0000-4000-8000-{attempt:012d}"
            self.event_pair(events, attempt, 19, "reviewer", attempt,
                            thread_id, "{:error, :mvp_invalid_review}")
        rows = self.read_attempts({"recovery": {"events": events}}, self.evidence)
        self.assertEqual(len(rows), 500)
        self.assertEqual(rows[0]["attempt"], 1)
        self.assertEqual(rows[-1]["attempt"], 500)
        self.assertTrue(all(row["round"] == 19 and row["status"] == "failed"
                            for row in rows))

    def test_unmatched_session_is_unassigned_for_controller_rounds(self):
        workspace = "/var/tmp/innovation-symphony-v0-rerun1/workspaces/GH-88"
        session_id = "01a0f299-30e9-7620-91f1-a1948296c19e"
        session = {
            "meta": {"session_id": session_id},
            "cwd": workspace,
            "prompt": "Independently review GH-88: verify this change.",
            "issue": "GH-88",
            "first_ts": "2026-09-30T01:00:00Z",
            "last_ts": "2026-09-30T01:01:00Z",
            "entries": 1,
            "counts": {"reasoning": 0, "tool": 0},
            "tokens": None,
            "agent_msgs": [],
            "bytes": 0,
            "remote": "/remote/rollout.jsonl",
        }
        receipt = {
            "issue": 88,
            "repository": "acme/project",
            "workspace": workspace,
            "status": "reviewing",
            "rounds": [{"round": 19, "status": "reviewing"}],
            "_agent_attempts": [],
            "_path": "/state/attempt-4/issue-88.json",
        }
        snapshot = {"runtimes": [{
            "root": "/var/tmp/innovation-symphony-v0-rerun1",
            "receipts": [receipt],
            "evidence": [],
        }]}

        task = build_tasks(snapshot, [session], {})[0]

        self.assertEqual(task["roundsAuthority"], "controller")
        self.assertEqual(len(task["sessions"]), 1)
        self.assertIsNone(task["sessions"][0]["round"])
        self.assertEqual(task["sessions"][0]["roundSource"], "unassigned")
        self.assertEqual(task["sessions"][0]["attemptOutcome"], "unknown")


if __name__ == "__main__":
    unittest.main()
