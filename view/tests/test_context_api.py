import hashlib
import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler
from types import SimpleNamespace
from urllib.error import HTTPError
from urllib.request import urlopen

APP_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app")
if APP_DIR not in sys.path:
    sys.path.insert(0, APP_DIR)

from symphony_board.api import BoardHTTPServer, RawRef, make_handler
from symphony_board.collector import BUILD_ROLLOUTS, load_sessions, public_session
from symphony_board.context import MAX_ENTRY_TEXT, MAX_HEADER_BYTES, MAX_WINDOW_BYTES, read_session_context
from symphony_board.state import BoardState


def record(kind, payload, timestamp="2026-09-30T01:02:03Z"):
    return {"type": kind, "timestamp": timestamp, "payload": payload}


def fixture_lines(session_id="01a0f117-2b80-73a2-a3bb-f6d83c3b614b"):
    return [
        record("session_meta", {"id": session_id, "cwd": "/var/tmp/symphony/workspaces/GH-33", "cli_version": "0.1", "originator": "symphony"}),
        record("turn_context", {"model": "gpt-6-astra", "cwd": "/var/tmp/symphony/workspaces/GH-33", "effort": "high"}),
        record("response_item", {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Implement this issue.\nKeep the second line."}]}),
        record("response_item", {"type": "reasoning", "summary": [{"type": "summary_text", "text": "Visible summary"}], "encrypted_content": "must not be returned"}),
        record("response_item", {"type": "custom_tool_call", "name": "exec_command", "input": "pwd"}),
        record("response_item", {"type": "function_call", "name": "exec_command", "arguments": "{\"command\":\"pwd\",\"tag\":\"legacy-function-call\"}", "call_id": "call-1"}),
        record("response_item", {"type": "function_call_output", "output": "legacy tool result", "call_id": "call-1"}),
        record("response_item", {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Earlier answer"}]}),
        record("event_msg", {"type": "item_completed", "item": {"type": "AgentMessage", "content": [{"type": "output_text", "text": "Latest answer.\nSecond line."}]}}),
    ]


class ContextApiTests(unittest.TestCase):
    def setUp(self):
        os.makedirs(BUILD_ROLLOUTS, exist_ok=True)
        self.paths = []

    def tearDown(self):
        for path in self.paths:
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
        load_sessions({})

    def cache_fixture(self, remote, rows):
        name = remote.replace("\\", "/").rsplit("/", 1)[-1]
        digest = hashlib.sha256(remote.encode("utf-8", "replace")).hexdigest()[:16]
        path = os.path.join(BUILD_ROLLOUTS, digest + "-" + name)
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        self.paths.append(path)
        return path

    def test_session_id_prompt_model_and_output_are_extracted(self):
        remote = "/var/tmp/runtime-a/rollout-01a0f117.jsonl"
        path = self.cache_fixture(remote, fixture_lines())
        sessions = load_sessions({"runtimes": [{"sessions": [{"path": remote, "bytes": os.path.getsize(path)}]}]})
        self.assertEqual(sessions[0]["meta"]["session_id"], "01a0f117-2b80-73a2-a3bb-f6d83c3b614b")
        self.assertEqual(sessions[0]["prompt"], "Implement this issue.\nKeep the second line.")
        self.assertEqual(sessions[0]["model"], "gpt-6-astra")
        self.assertEqual(sessions[0]["counts"]["tool"], 2)
        self.assertEqual(sessions[0]["last_output"], "Latest answer.\nSecond line.")
        public = public_session(sessions[0])
        self.assertEqual(public["lastOutput"], "Latest answer.\nSecond line.")
        self.assertEqual(public["modelEvidence"], "turn_context.model")

    def test_context_model_prefers_full_collector_value_and_matching_evidence(self):
        session_id = "01a0f117-2b80-73a2-a3bb-f6d83c3b6150"
        remote = "/var/tmp/runtime-a/rollout-model-consistency.jsonl"
        rows = [
            record("session_meta", {"id": session_id, "cwd": "/var/tmp/runtime-a/workspaces/GH-9", "model": "meta-model"}),
            record("turn_context", {"cwd": "/workspace", "model": "model-A"}),
            record("response_item", {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Implement only this repository's issue: GH-9 model consistency."}]}),
            record("world_state", {"padding": "x" * (MAX_HEADER_BYTES + 100)}),
            record("turn_context", {"cwd": "/workspace", "model": "model-B"}),
        ]
        path = self.cache_fixture(remote, rows)
        sessions = load_sessions({"runtimes": [{"sessions": [{"path": remote, "bytes": os.path.getsize(path)}]}]})
        parsed = sessions[0]
        self.assertEqual(parsed["model"], "model-B")
        public = public_session(parsed)
        from symphony_board.collector import context_sources
        sources = context_sources(session_id)

        complete = read_session_context(session_id, public, sources)
        self.assertEqual(complete["session"]["model"], "model-B")
        self.assertEqual(complete["session"]["modelEvidence"], "turn_context.model")

        without_public_model = dict(public, model=None, modelEvidence=None)
        header_fallback = read_session_context(session_id, without_public_model, sources)
        self.assertEqual(header_fallback["session"]["model"], "model-A")
        self.assertEqual(header_fallback["session"]["modelEvidence"], "turn_context.model")

        unknown_evidence = dict(public, model="snapshot-model", modelEvidence=None)
        no_fabricated_source = read_session_context(session_id, unknown_evidence, sources)
        self.assertEqual(no_fabricated_source["session"]["model"], "snapshot-model")
        self.assertIsNone(no_fabricated_source["session"]["modelEvidence"])

    def test_injected_agents_message_does_not_replace_real_task_prompt(self):
        session_id = "01a0f0bf-a1c7-7381-b9a3-d1806c25ef9b"
        injected = "# AGENTS.md instructions for /workspace\nRepository guidance injected by Codex."
        prompt = "Implement only this repository's issue: GH-5 Fix session context selection.\nPreserve the assigned behavior."
        remote = "/var/tmp/runtime-a/rollout-01a0f0bf.jsonl"
        rows = [
            record("session_meta", {"id": session_id, "cwd": "/var/tmp/runtime-a/sandboxes/run-5/codex-home"}),
            record("turn_context", {"cwd": "/workspace", "model": "gpt-6-astra"}),
            record("response_item", {"type": "message", "role": "user", "content": [{"type": "input_text", "text": injected}]}),
            record("response_item", {"type": "message", "role": "user", "content": [{"type": "input_text", "text": prompt}]}),
            record("event_msg", {"type": "item_completed", "item": {"type": "UserMessage", "content": [{"type": "input_text", "text": prompt}]}}),
        ]
        path = self.cache_fixture(remote, rows)
        sessions = load_sessions({"runtimes": [{"sessions": [{"path": remote, "bytes": os.path.getsize(path)}]}]})
        parsed = sessions[0]
        self.assertEqual(parsed["prompt"], prompt)
        self.assertEqual(parsed["issue"], "GH-5")
        self.assertEqual(public_session(parsed)["role"], "编码")
        from symphony_board.collector import context_sources
        context = read_session_context(public_session(parsed)["id"], public_session(parsed), context_sources(session_id), limit=20)
        self.assertEqual(context["session"]["issuedInstruction"], prompt)
        self.assertEqual(context["session"]["workdir"], "/workspace")
        self.assertTrue(any(injected in entry["text"] for entry in context["entries"]))

    def test_prompt_fallback_skips_injected_user_context(self):
        remote = "/var/tmp/runtime-a/rollout-fallback.jsonl"
        prompt = "Independently review GH-12: verify the patch and report findings."
        rows = [
            record("session_meta", {"id": "01a0f117-2b80-73a2-a3bb-f6d83c3b614d", "cwd": "/var/tmp/runtime-a/workspaces/GH-12"}),
            record("response_item", {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "<environment_context>\nInjected cwd and environment data.\n</environment_context>"}]}),
            record("response_item", {"type": "message", "role": "user", "content": [{"type": "input_text", "text": prompt}]}),
        ]
        path = self.cache_fixture(remote, rows)
        sessions = load_sessions({"runtimes": [{"sessions": [{"path": remote, "bytes": os.path.getsize(path)}]}]})
        self.assertEqual(sessions[0]["prompt"], prompt)

    def test_search_matches_text_beyond_entry_preview(self):
        remote = "/var/tmp/runtime-a/rollout-long-entry.jsonl"
        marker = "MARKER_OUTSIDE_PREVIEW_123"
        long_text = "x" * (MAX_ENTRY_TEXT + 200) + marker
        rows = [
            record("session_meta", {"id": "01a0f117-2b80-73a2-a3bb-f6d83c3b614f", "cwd": "/var/tmp/runtime-a/workspaces/GH-7"}),
            record("response_item", {"type": "message", "role": "assistant", "phase": "final_answer",
                                      "content": [{"type": "output_text", "text": long_text}]}),
        ]
        path = self.cache_fixture(remote, rows)
        sessions = load_sessions({"runtimes": [{"sessions": [{"path": remote, "bytes": os.path.getsize(path)}]}]})
        public = public_session(sessions[0])
        from symphony_board.collector import context_sources
        result = read_session_context(public["id"], public, context_sources(public["id"]),
                                      limit=10, entry_type="message", search=marker)
        self.assertEqual(len(result["entries"]), 1)
        entry = result["entries"][0]
        self.assertTrue(entry["truncated"])
        self.assertTrue(entry["matchBeyondPreview"])
        self.assertNotIn(marker, entry["text"])
        self.assertLessEqual(len(entry["text"]), MAX_ENTRY_TEXT + 1)

    def test_event_user_message_precedes_response_item_fallback(self):
        session_id = "01a0f117-2b80-73a2-a3bb-f6d83c3b614e"
        remote = "/var/tmp/runtime-a/rollout-event-priority.jsonl"
        response_prompt = "Implement only this repository's issue: GH-4 response fallback."
        event_prompt = "Implement only this repository's issue: GH-5 event instruction."
        rows = [
            record("session_meta", {"id": session_id, "cwd": "/var/tmp/runtime-a/sandboxes/run-5/codex-home"}),
            record("turn_context", {"cwd": "/workspace"}),
            record("response_item", {"type": "message", "role": "user", "content": [{"type": "input_text", "text": response_prompt}]}),
            record("event_msg", {"type": "item_completed", "item": {"type": "UserMessage", "content": [{"type": "input_text", "text": event_prompt}]}}),
        ]
        path = self.cache_fixture(remote, rows)
        sessions = load_sessions({"runtimes": [{"sessions": [{"path": remote, "bytes": os.path.getsize(path)}]}]})
        parsed = sessions[0]
        self.assertEqual(parsed["prompt"], event_prompt)
        self.assertEqual(parsed["issue"], "GH-5")
        from symphony_board.collector import context_sources
        public = public_session(parsed)
        context = read_session_context(session_id, public, context_sources(session_id), limit=20)
        self.assertEqual(context["session"]["issuedInstruction"], event_prompt)

    def test_context_response_sanitizes_paths_and_reasoning(self):
        remote = "/var/tmp/runtime-a/rollout-01a0f117.jsonl"
        path = self.cache_fixture(remote, fixture_lines())
        sessions = load_sessions({"runtimes": [{"sessions": [{"path": remote, "bytes": os.path.getsize(path)}]}]})
        public = public_session(sessions[0])
        from symphony_board.collector import context_sources
        result = read_session_context(public["id"], public, context_sources(public["id"]), limit=20)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["session"]["workdir"], "workspaces/GH-33")
        self.assertNotIn("/var/tmp", json.dumps(result, ensure_ascii=False))
        self.assertEqual(result["session"]["issuedInstruction"], "Implement this issue.\nKeep the second line.")
        self.assertEqual(result["latestAssistant"]["text"], "Latest answer.\nSecond line.")
        reasoning = [entry for entry in result["entries"] if entry["type"] == "reasoning"]
        self.assertTrue(reasoning)
        self.assertIn("Visible summary", reasoning[0]["text"])
        self.assertNotIn("must not be returned", reasoning[0]["text"])
        tools = [entry for entry in result["entries"] if entry["type"] == "tool"]
        self.assertEqual(sum("legacy-function-call" in entry["text"] for entry in tools), 1)
        self.assertEqual(sum("legacy tool result" in entry["text"] for entry in tools), 1)

    def test_same_basename_from_different_runtime_roots_stays_distinct(self):
        rows = fixture_lines()
        first = "/var/tmp/runtime-a/rollout-same.jsonl"
        second = "/var/tmp/runtime-b/rollout-same.jsonl"
        first_path = self.cache_fixture(first, rows)
        second_rows = fixture_lines("01a0f117-2b80-73a2-a3bb-f6d83c3b614c")
        second_path = self.cache_fixture(second, second_rows)
        self.assertNotEqual(first_path, second_path)
        sessions = load_sessions({"runtimes": [{"sessions": [
            {"path": first, "bytes": os.path.getsize(first_path)},
            {"path": second, "bytes": os.path.getsize(second_path)},
        ]}]})
        self.assertEqual(len(sessions), 2)
        self.assertNotEqual(sessions[0]["meta"]["session_id"], sessions[1]["meta"]["session_id"])

    def test_context_endpoint_reports_missing_and_serves_context(self):
        remote = "/var/tmp/runtime-a/rollout-01a0f117.jsonl"
        path = self.cache_fixture(remote, fixture_lines())
        sessions = load_sessions({"runtimes": [{"sessions": [{"path": remote, "bytes": os.path.getsize(path)}]}]})
        public = public_session(sessions[0])
        state = BoardState()
        state.publish({"sessions": [public]})
        config = SimpleNamespace(
            title="test", interval=5, port=0, path="", exists=False,
            stall_hours=24, cost=SimpleNamespace(currency="", enabled=False, input_per_m=0,
                                                  cached_input_per_m=0, output_per_m=0),
            repos=[], pending=lambda _raw: [],
        )
        raw_ref = RawRef()
        raw_ref.health = {"status": "ok", "source": "wsl", "lastSuccess": "2026-09-30T01:00:00Z"}
        server = BoardHTTPServer(("127.0.0.1", 0), make_handler(state, config, raw_ref, None))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            with urlopen(base + "/api/sessions/01a0f117-2b80-73a2-a3bb-f6d83c3b614b/context") as response:
                body = json.loads(response.read().decode("utf-8"))
            self.assertEqual(body["status"], "ok")
            with urlopen(base + "/api/sessions/01a0f117-2b80-73a2-a3bb-f6d83c3b614b/context?type=message&q=Keep") as response:
                filtered = json.loads(response.read().decode("utf-8"))
            self.assertEqual([entry["role"] for entry in filtered["entries"]], ["user"])
            with urlopen(base + "/api/bootstrap") as response:
                bootstrap = json.loads(response.read().decode("utf-8"))
            self.assertEqual(bootstrap["collection"], raw_ref.health)
            with self.assertRaises(HTTPError) as missing:
                urlopen(base + "/api/sessions/not-present/context")
            self.assertEqual(missing.exception.code, 404)
            self.assertEqual(json.loads(missing.exception.read().decode("utf-8"))["status"], "missing")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_large_context_page_is_bounded_and_cursor_moves_older(self):
        remote = "/var/tmp/runtime-a/rollout-large.jsonl"
        rows = fixture_lines()
        for index in range(900):
            rows.append(record("response_item", {"type": "message", "role": "assistant",
                                                   "content": [{"type": "output_text", "text": f"line-{index}-" + "x" * 1500}]}))
        path = self.cache_fixture(remote, rows)
        sessions = load_sessions({"runtimes": [{"sessions": [{"path": remote, "bytes": os.path.getsize(path)}]}]})
        public = public_session(sessions[0])
        from symphony_board.collector import context_sources
        sources = context_sources(public["id"])
        newest = read_session_context(public["id"], public, sources, limit=5)
        self.assertGreater(os.path.getsize(path), MAX_WINDOW_BYTES)
        self.assertLessEqual(newest["page"]["scannedBytes"], MAX_WINDOW_BYTES)
        self.assertTrue(newest["page"]["hasOlder"])
        older = read_session_context(public["id"], public, sources, limit=5, before=newest["page"]["nextBefore"])
        self.assertLess(max(item["index"] for item in older["entries"]), min(item["index"] for item in newest["entries"]))

    def test_board_server_rejects_duplicate_bind_and_first_server_stays_live(self):
        class PingHandler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                body = b"alive"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        first = BoardHTTPServer(("127.0.0.1", 0), PingHandler)
        thread = threading.Thread(target=first.serve_forever, daemon=True)
        thread.start()
        port = first.server_address[1]
        try:
            try:
                second = BoardHTTPServer(("127.0.0.1", port), PingHandler)
            except OSError:
                second = None
            if second is not None:
                second.server_close()
                self.fail("second server unexpectedly bound the active board port")
            with urlopen(f"http://127.0.0.1:{port}/") as response:
                self.assertEqual(response.read(), b"alive")
        finally:
            first.shutdown()
            first.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
