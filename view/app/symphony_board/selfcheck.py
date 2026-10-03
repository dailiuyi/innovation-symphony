# -*- coding: utf-8 -*-
"""Offline self-check for the board pipeline. Ported from the watcher."""
import json
import os
import re
import tempfile

from .collector import diagnosis_note, public_session, review_verdict
from .common import attempt_of, cycle_pause, listed_runtimes, natural_name, repo_of, repo_slug, session_role
from .config import _from_dicts
from .derive import (
    build_stories,
    build_tasks,
    checking_row,
    decode_check_log,
    evidence_failed,
    evidence_view,
    glance_check,
    glance_review,
    attach_session_repos,
    parse_pull_request,
    decisive_review,
    session_timeline,
    summarize_check,
    workflow_of,
)
from .pagegen import codex_transcript_html, page_body, stamp_codex_page, transcript_token, viewer_pages
from .store import BoardStore


def self_check():
    sample = '{:command_failed, 1, "372 tests, 1 failure, 6 skipped\\nCoverage:   99.93%\\nThreshold: 100.00%\\nCommand \'[\'mix\', \'test\', \'--cover\']\' returned non-zero exit status 3.\\n"}'
    decoded = decode_check_log(sample)
    if decoded["exit"] != 1 or "\n" not in decoded["body"] or "99.93%" not in decoded["body"]:
        raise RuntimeError(f"evidence decode failed: {decoded!r}")
    summary = summarize_check(decoded["body"])
    blob = " ".join(summary["lines"])
    if "99.93%" not in blob or "退出码 3" not in blob:
        raise RuntimeError(f"evidence summary failed: {summary!r}")
    if session_role("/tmp/workspaces/GH-1", "Implement only this repository's issue: GH-1 x") != "编码":
        raise RuntimeError("coder role")
    if session_role("/tmp/workspaces/GH-1", "Independently review GH-1: x") != "Review":
        raise RuntimeError("review role")
    if session_role("/tmp/workspaces/preflight", "hello") != "预检":
        raise RuntimeError("preflight role")
    if session_role("/tmp/workspaces/GH-1", "hello") != "未识别":
        raise RuntimeError("unknown role must not become coder")
    diagnose = "Diagnose repeated or unclassified technical failures for GH-5."
    if session_role("/tmp/workspaces/GH-5", diagnose) != "诊断":
        raise RuntimeError("diagnosis role")
    if session_role("/tmp/workspaces/GH-5", diagnose) in ("编码", "未识别"):
        raise RuntimeError("diagnosis must stay out of the coder bucket")
    lint_log = "\n".join([
        "[check] stage=deps child_exit=0 outcome=0 reason=ok",
        "[check] stage=format child_exit=0 outcome=0 reason=ok",
        "Function is too complex (cyclomatic complexity is 13, max is 9)",
        "found 11 refactoring opportunities.",
        "[check] stage=lint child_exit=8 outcome=1 reason=environment diagnostic or unexpected process exit",
    ])
    lint_view = evidence_view({"name": "round-1/check-1.log", "text": lint_log, "path": "lint", "bytes": 12})
    if lint_view["exit"] != 1 or not evidence_failed(lint_view):
        raise RuntimeError(f"lint exit {lint_view['exit']}")
    if "Credo：11 处复杂度或嵌套问题" not in lint_view["summary"] or lint_view["summary"] == "round-1/check-1.log":
        raise RuntimeError(f"lint summary {lint_view['summary']}")
    if glance_check(lint_view["summary"]) != "Credo：11 处复杂度或嵌套问题":
        raise RuntimeError(f"lint glance {glance_check(lint_view['summary'])}")
    if "environment diagnostic" in glance_check(lint_view["summary"]):
        raise RuntimeError("lint glance used the generic stage reason")
    read_log = "\n".join([
        "[R] ↗ Numbers larger than 9999 should be written with underscores: 43_210",
        "found 1 code readability issue.",
        "[check] stage=lint child_exit=4 outcome=1 reason=environment diagnostic or unexpected process exit",
    ])
    read_view = evidence_view({"name": "round-3/check-1.log", "text": read_log, "path": "read", "bytes": 8})
    read_why = glance_check(read_view["summary"])
    if read_view["exit"] != 1 or read_why != "Credo：数字应写成 43_210":
        raise RuntimeError(f"readability glance {read_view['exit']} {read_why}")
    if "environment diagnostic" in read_why:
        raise RuntimeError("readability glance used the generic stage reason")
    busy_log = "\n".join([
        "[check] stage=lint child_exit=0 outcome=0 reason=process passed",
        "[check] stage=test run_id=abc evidence=/tmp/x",
        "[check] stage=test command=mix test --cover",
        "Running ExUnit",
    ])
    busy_view = evidence_view({"name": "round-4/check-1.log", "text": busy_log, "path": "busy", "bytes": 8})
    if busy_view["exit"] is not None or busy_view.get("open") != "test" or evidence_failed(busy_view):
        raise RuntimeError(f"open check {busy_view['exit']} {busy_view.get('open')}")
    if "正在跑测试和覆盖率" not in busy_view["summary"]:
        raise RuntimeError(f"open summary {busy_view['summary']}")
    running = checking_row({"status": "checking", "evidence": [busy_view]})
    if not running or running["title"] != "第 4 轮 · 脚本审查进行中" or running["why"] != "正在跑测试和覆盖率":
        raise RuntimeError(f"checking row {running}")
    if checking_row({"status": "coding", "evidence": [busy_view]}):
        raise RuntimeError("coding must not grow a running gate")
    legacy = "\n".join([
        "[check] stage=deps command=mix deps get",
        "[check] stage=deps child_exit=0 outcome=0",
        "[check] stage=test command=mix test --cover",
        "383 tests, 0 failures, 6 skipped",
        "[check] stage=test child_exit=0 outcome=0",
        "[check] stage=build command=mix build",
        "[check] stage=build child_exit=0 outcome=0",
    ])
    legacy_view = evidence_view({"name": "round-2/check-1.log", "text": legacy, "path": "legacy", "bytes": 8})
    if legacy_view.get("open") or legacy_view["exit"] is not None or evidence_failed(legacy_view):
        raise RuntimeError(f"finished legacy check {legacy_view.get('open')} {legacy_view['exit']}")
    dial_log = "\n".join([
        "496 tests, 0 failures, 6 skipped",
        "[check] stage=test child_exit=0 outcome=0 reason=complete passing suite",
        "Total errors: 3, Skipped: 0, Unnecessary Skips: 0",
        "lib/symphony_elixir/cli.ex:48:8:no_return Function watchdog_once/2 has no local return.",
        "[check] stage=dialyzer child_exit=2 outcome=1 reason=unrecognized failure",
    ])
    dial_view = evidence_view({"name": "round-4/check-1.log", "text": dial_log, "path": "dial", "bytes": 8})
    dial_why = glance_check(dial_view["summary"])
    if dial_view["exit"] != 1 or dial_why != "Dialyzer：3 处，watchdog_once/2 无返回":
        raise RuntimeError(f"dialyzer glance {dial_view['exit']} {dial_why}")
    if "0 项失败" in dial_why or "unrecognized" in dial_why:
        raise RuntimeError(f"dialyzer glance hid the errors {dial_why}")
    passed_log = "[check] stage=lint child_exit=0 outcome=0 reason=ok\nfound no issues\n"
    passed_view = evidence_view({"name": "round-2/check-1.log", "text": passed_log, "path": "ok", "bytes": 4})
    if passed_view["exit"] is not None or evidence_failed(passed_view):
        raise RuntimeError(f"passing stage {passed_view}")
    test_log = "\n".join([
        "489 tests, 2 failures, 6 skipped",
        "Coverage: 96.67%",
        "Threshold: 100.00%",
        "[check] stage=test child_exit=3 outcome=10 reason=coverage below required 100% and assertion failures",
    ])
    test_view = evidence_view({"name": "round-2/check-1.log", "text": test_log, "path": "test", "bytes": 20})
    test_why = glance_check(test_view["summary"])
    if test_view["exit"] != 10 or test_why != "489 项测试，2 项失败；覆盖率 96.67%，阈值 100%":
        raise RuntimeError(f"test glance {test_view['exit']} {test_why}")
    note = diagnosis_note({
        "cwd": "/tmp/workspaces/GH-5",
        "prompt": diagnose,
        "agent_msgs": [("t", "先看日志"), ("t", '{"action": "repair_code", "summary": "这是候选代码的确定性静态检查失败。mix lint 报出 11 处 Credo 问题。"}')],
    })
    if not note.startswith("接着改代码并重跑检查") or "11 处 Credo" not in note:
        raise RuntimeError(f"diagnosis note {note}")
    if diagnosis_note({"cwd": "/tmp/workspaces/GH-1", "prompt": "Implement only this repository's issue: GH-1", "agent_msgs": []}):
        raise RuntimeError("coder note")
    # Review 结论：控制器不一定落 review.json，会话输出里的 approved 必须能被读到
    review_reject = {
        "cwd": "/tmp/workspaces/GH-5", "prompt": "Independently review GH-5: x", "issue": "GH-5",
        "agent_msgs": [("t", '{"approved": false, "summary": "不批准进入 HUMAN review。"}')],
    }
    verdict = review_verdict(review_reject)
    if not verdict or verdict["approved"] is not False or "不批准" not in verdict["summary"]:
        raise RuntimeError(f"review verdict {verdict}")
    review_ok = dict(review_reject, agent_msgs=[("t", '{"approved": true, "summary": "批准。"}')])
    if (review_verdict(review_ok) or {}).get("approved") is not True:
        raise RuntimeError("review verdict approved")
    if review_verdict(dict(review_reject, prompt="Implement only this repository's issue: GH-5 x")):
        raise RuntimeError("coder session must not yield a review verdict")
    if review_verdict(dict(review_reject, agent_msgs=[("t", "没有 JSON 的普通回复")])):
        raise RuntimeError("review verdict without payload")
    # 上下文页文件名必须唯一：同一分钟内两个 session 的 id 前 8 位会相同
    a = public_session({"meta": {"session_id": "01a0ee26-3a6c-7421-9176-d5a057ad351f"}, "cwd": "/tmp/ws",
                        "prompt": "Independently review GH-5: x", "agent_msgs": []})
    b = public_session({"meta": {"session_id": "01a0ee26-9999-7421-9176-d5a057ad351f"}, "cwd": "/tmp/ws",
                        "prompt": "Independently review GH-5: x", "agent_msgs": []})
    if a["short"] != b["short"]:
        raise RuntimeError("fixture must share the 8-char prefix")
    if a["href"] == b["href"]:
        raise RuntimeError(f"context page names collide: {a['href']}")
    chain = session_timeline([
        {"id": "c1", "role": "编码", "short": "01a0ec91"},
        {"id": "d1", "role": "诊断", "short": "01a0eca3"},
        {"id": "c2", "role": "编码", "short": "01a0eca5"},
        {"id": "c3", "role": "编码", "short": "01a0ecad"},
    ], [
        {"n": 1, "kind": "script", "title": "脚本审查未通过", "why": "Credo：11 处复杂度或嵌套问题"},
        {"n": 2, "kind": "script", "title": "脚本审查未通过", "why": "489 项测试，2 项失败；覆盖率 96.67%，阈值 100%"},
    ])
    chain_view = [
        (row["kind"], row.get("id") or row.get("title"), row.get("follow") or "")
        for row in chain
    ]
    if chain_view != [
        ("session", "c1", ""),
        ("gate", "第 1 轮 · 脚本审查未通过", "控制器先派只读诊断，再决定怎么返工"),
        ("session", "d1", ""),
        ("session", "c2", ""),
        ("gate", "第 2 轮 · 脚本审查未通过", "这一轮被打回，后面的会话接着做"),
        ("session", "c3", ""),
    ]:
        raise RuntimeError(f"session timeline {chain_view}")
    reviewed = session_timeline([
        {"id": "c1", "role": "编码"},
        {"id": "r1", "role": "Review"},
        {"id": "c2", "role": "编码"},
    ], [
        {"n": 1, "kind": "script", "title": "脚本审查未通过", "why": "覆盖率"},
        {"n": 1, "kind": "review", "title": "Review 未通过", "why": "验收没对齐"},
        {"n": 2, "kind": "script", "title": "脚本审查未通过", "why": "测试失败"},
    ])
    reviewed_ids = [(row["kind"], row.get("id") or row.get("title")) for row in reviewed]
    if reviewed_ids != [
        ("session", "c1"),
        ("gate", "第 1 轮 · 脚本审查未通过"),
        ("session", "r1"),
        ("gate", "第 1 轮 · Review 未通过"),
        ("session", "c2"),
        ("gate", "第 2 轮 · 脚本审查未通过"),
    ]:
        raise RuntimeError(f"review timeline {reviewed_ids}")
    steps, gap = workflow_of(
        [
            {"role": "编码", "short": "a", "duration": "1s", "href": "c.html"},
            {"role": "诊断", "short": "b", "duration": "1s", "href": "d.html"},
        ],
        [],
        "编码中",
        "",
    )
    if any(step["kind"] == "unknown" for step in steps) or gap != "有编码会话，没有 Review rollout。":
        raise RuntimeError(f"diagnosis pipe {gap} {steps}")
    repo = "dailiuyi/innovation-symphony"
    other = "acme/widget"
    if repo_slug(repo) != "dailiuyi--innovation-symphony" or repo_of({}) != "未知仓库":
        raise RuntimeError("repo identity")
    blank = {"title": "T", "gap": "", "flow": [], "preflight": [], "duration": "—",
             "status": "blocked", "statusLabel": "被挡住", "badge": "b-blocked", "repo": repo}
    rows = [
        {**blank, "runtime": "rerun1", "issue": "1", "attempt": "attempt-4",
         "id": "dailiuyi--innovation-symphony--rerun1--attempt-4--GH-1",
         "status": "awaiting_human", "reason": "", "statusLabel": "等待人工", "badge": "b-review"},
        {**blank, "runtime": "rerun1", "issue": "1", "attempt": "",
         "id": "dailiuyi--innovation-symphony--rerun1--GH-1", "reason": ":response_timeout"},
        {**blank, "runtime": "v0", "issue": "1", "attempt": "",
         "id": "dailiuyi--innovation-symphony--v0--GH-1", "reason": "{:mvp_check_failed, 1}"},
        {**blank, "runtime": "rerun1", "issue": "1", "attempt": "attempt-3",
         "id": "dailiuyi--innovation-symphony--rerun1--attempt-3--GH-1",
         "reason": ":mvp_review_not_approved", "gap": "没有编码 rollout，只有 Review 会话。"},
        {**blank, "runtime": "rerun1", "issue": "1", "attempt": "attempt-2",
         "id": "dailiuyi--innovation-symphony--rerun1--attempt-2--GH-1",
         "reason": ":mvp_candidate_or_baseline_changed"},
        {**blank, "repo": other, "runtime": "rerun1", "issue": "1", "attempt": "",
         "id": "acme--widget--rerun1--GH-1", "reason": "{:mvp_check_failed, 1}"},
    ]
    stories = {story["id"]: story for story in build_stories(rows)}
    if len(stories) != 3:
        raise RuntimeError(f"story count {sorted(stories)}")
    rerun = stories["story--dailiuyi--innovation-symphony--rerun1--GH-1"]
    order = [beat["taskId"] for beat in rerun["beats"]]
    if order != [
        "dailiuyi--innovation-symphony--rerun1--GH-1",
        "dailiuyi--innovation-symphony--rerun1--attempt-2--GH-1",
        "dailiuyi--innovation-symphony--rerun1--attempt-3--GH-1",
        "dailiuyi--innovation-symphony--rerun1--attempt-4--GH-1",
    ]:
        raise RuntimeError(f"story order {order}")
    if rerun["repo"] != repo or rerun["outcome"] != "进入人审" or not rerun["beats"][2]["handoff"].startswith("Review 未通过") or rerun["beats"][-1]["handoff"]:
        raise RuntimeError(f"rerun ending {rerun['outcome']} {rerun['beats'][2]['handoff']}")
    if any(beat["taskId"].startswith("acme--") for beat in rerun["beats"]):
        raise RuntimeError("second repo merged into rerun1")
    v0 = stories["story--dailiuyi--innovation-symphony--v0--GH-1"]
    if v0["attempts"] != 1 or v0["outcome"] != "脚本审查未通过" or v0["outcomeKind"] != "blocked":
        raise RuntimeError(f"v0 story {v0['outcome']} {v0['outcomeDetail']}")
    separate = stories["story--acme--widget--rerun1--GH-1"]
    if separate["attempts"] != 1 or separate["repo"] != other or separate["runtime"] != "rerun1" or separate["issue"] != "1":
        raise RuntimeError(f"second repo story {separate['id']} {separate['attempts']}")
    pr_url = "https://github.com/dailiuyi/innovation-symphony/pull/2"
    parsed = parse_pull_request(pr_url)
    if not parsed or parsed["repo"] != repo or parsed["number"] != 2:
        raise RuntimeError(f"pr url {parsed}")
    if decisive_review([
        {"state": "APPROVED", "submittedAt": "2026-01-01T00:00:00Z"},
        {"state": "CHANGES_REQUESTED", "submittedAt": "2026-01-02T00:00:00Z"},
    ]) != "CHANGES_REQUESTED":
        raise RuntimeError("latest changes request")
    if decisive_review([
        {"state": "CHANGES_REQUESTED", "submittedAt": "2026-01-01T00:00:00Z"},
        {"state": "APPROVED", "submittedAt": "2026-01-02T00:00:00Z"},
        {"state": "COMMENTED", "submittedAt": "2026-01-03T00:00:00Z"},
    ]) != "APPROVED":
        raise RuntimeError("approval after comments")

    def story_with(pr_state, extra=None):
        cloned = [dict(task) for task in rows]
        for task in cloned:
            if task["id"].endswith("attempt-4--GH-1") and task["repo"] == repo:
                task["pr"] = {"state": pr_state, "number": 2, "url": pr_url}
        if extra:
            cloned.extend(extra)
        found = {item["id"]: item for item in build_stories(cloned)}
        return found["story--dailiuyi--innovation-symphony--rerun1--GH-1"]

    merged_story = story_with("merged")
    if merged_story["outcomeKind"] != "done" or merged_story["outcome"] != "已交付" or merged_story["pr"]["url"] != pr_url:
        raise RuntimeError(f"merged story {merged_story['outcome']} {merged_story['outcomeDetail']}")
    if merged_story["beats"][-1]["pr"]["state"] != "merged":
        raise RuntimeError("merged beat")
    closed_story = story_with("closed")
    if closed_story["outcome"] != "打回重做" or closed_story["outcomeKind"] != "blocked" or "没有合并" not in closed_story["outcomeDetail"]:
        raise RuntimeError(f"closed story {closed_story['outcome']} {closed_story['outcomeDetail']}")
    open_story = story_with("open")
    if open_story["outcomeKind"] != "human" or "PR #2" not in open_story["outcomeDetail"]:
        raise RuntimeError(f"open story {open_story['outcomeDetail']}")
    rework = story_with("closed", [{
        **blank, "runtime": "rerun1", "issue": "1", "attempt": "attempt-5",
        "id": "dailiuyi--innovation-symphony--rerun1--attempt-5--GH-1",
        "status": "coding", "statusLabel": "编码中", "badge": "b-running", "reason": "",
    }])
    if rework["outcomeKind"] != "running" or "人工未通过" not in rework["beats"][-2]["handoff"] or "没有合并" not in rework["beats"][-2]["handoff"]:
        raise RuntimeError(f"rework {rework['outcomeKind']} {rework['beats'][-2]['handoff']}")
    if glance_review("拒绝。[P2] A9 中断路径会错误标记用量完整：elixir/lib/x.ex:93 后面还有说明") != "A9 中断路径会错误标记用量完整":
        raise RuntimeError("review headline")
    preflight_why = glance_review("拒绝。拒绝批准候选 04846341d9392fefa1cf10599fdaa177f56e7507。[P1] 指定差异仅实现只读 --preflight；A 停领与收尾都没有做")
    if "只读 --preflight" not in preflight_why:
        raise RuntimeError(f"preflight headline {preflight_why}")
    pf3_why = glance_review("拒绝。拒绝候选 bf27c10：① PF-3 存在实际假成功路径，HTTP 200 的畸形列表会被当成体检通过；② 断言不够")
    if pf3_why != "PF-3 存在实际假成功路径":
        raise RuntimeError(f"pf3 headline {pf3_why}")
    if glance_check("退出码 1 · 覆盖率 99.93%，阈值 100.00% · ['mix', 'test', '--cover'] 退出码 3") != "覆盖率 99.93%，阈值 100%":
        raise RuntimeError("coverage glance")
    both_why = glance_check("退出码 1 · 372 项测试，1 项失败，6 项跳过 · 覆盖率 99.93%，阈值 100.00% · ['mix', 'test', '--cover'] 退出码 3")
    if both_why != "372 项测试，1 项失败；覆盖率 99.93%，阈值 100%":
        raise RuntimeError(f"check glance {both_why}")
    gh3 = {**blank, "runtime": "rerun1", "issue": "3", "attempt": "",
           "id": "dailiuyi--innovation-symphony--rerun1--GH-3",
           "status": "coding", "statusLabel": "编码中", "badge": "b-running", "reason": "",
           "evidence": [
               {"name": "round-1/check-1.log", "summary": "退出码 1 · 覆盖率 99.93%，阈值 100.00% · ['mix', 'test', '--cover'] 退出码 3", "exit": 1},
               {"name": "round-2/check-1.log", "summary": "383 项测试，0 项失败，6 项跳过"},
               {"name": "round-2/review.json", "summary": "拒绝。拒绝批准候选 04846341d9392fefa1cf10599fdaa177f56e7507。[P1] 指定差异仅实现只读 --preflight；后面还有很多字", "approved": False},
               {"name": "round-3/check-1.log", "summary": "385 项测试，1 项失败，6 项跳过"},
               {"name": "round-4/review.json", "summary": "拒绝。拒绝候选 bf27c10：① PF-3 存在实际假成功路径，HTTP 200 的畸形列表；② 其他", "approved": False},
           ]}
    gh3_story = next(item for item in build_stories(rows + [gh3]) if item["issue"] == "3")
    kinds = [item["kind"] for item in gh3_story["beats"][0]["returns"]]
    if gh3_story["outcomeKind"] != "running" or kinds != ["script", "review", "script", "review"]:
        raise RuntimeError(f"round causes {gh3_story['outcomeKind']} {kinds} {gh3_story['beats'][0]['returns']}")
    if "99.93%" not in gh3_story["beats"][0]["returns"][0]["why"] or "只读 --preflight" not in gh3_story["beats"][0]["returns"][1]["why"]:
        raise RuntimeError(f"round why {gh3_story['beats'][0]['returns']}")
    tagged = [
        {"cwd": "/var/tmp/innovation-symphony-v0-rerun1/workspaces/GH-1", "prompt": "Implement only this repository's issue"},
        {"cwd": "/var/tmp/innovation-symphony-v0-rerun1/preflight", "prompt": "This is an authorized local execution preflight"},
        {"cwd": "/var/tmp/innovation-symphony-v0/preflight", "prompt": "This is an authorized local execution preflight"},
    ]
    attach_session_repos({"runtimes": [
        {"root": "/var/tmp/innovation-symphony-v0-rerun1", "receipts": [
            {"repository": repo, "workspace": "/var/tmp/innovation-symphony-v0-rerun1/workspaces/GH-1"},
            {"repository": other, "workspace": "/var/tmp/innovation-symphony-v0-rerun1/attempt-2/workspaces/GH-9"},
        ]},
        {"root": "/var/tmp/innovation-symphony-v0", "receipts": [
            {"repository": repo, "workspace": "/var/tmp/innovation-symphony-v0/workspaces/GH-1"},
        ]},
    ]}, tagged)
    if tagged[0]["repo"] != repo or tagged[0]["runtime"] != "rerun1":
        raise RuntimeError(f"workspace repo {tagged[0]}")
    if tagged[1]["repo"] != "" or tagged[1]["runtime"] != "rerun1":
        raise RuntimeError(f"multi-repo preflight should stay untagged {tagged[1]}")
    if tagged[2]["repo"] != repo or tagged[2]["runtime"] != "v0":
        raise RuntimeError(f"single-repo preflight {tagged[2]}")
    # 沙箱会话：cwd 指向沙箱自身，issue 从 prompt 提取，repo 按 runtime+issue 兜底
    sandboxed = [
        {"cwd": "/var/tmp/innovation-symphony-v0-rerun1/sandboxes/run-1/codex-home",
         "prompt": "Implement only this repository's issue: GH-5 watchdog", "issue": "GH-5"},
        {"cwd": "/var/tmp/innovation-symphony-v0-rerun1/sandboxes/run-2/codex-home",
         "prompt": "Independently review GH-5: watchdog", "issue": "GH-5"},
    ]
    attach_session_repos({"runtimes": [{"root": "/var/tmp/innovation-symphony-v0-rerun1", "receipts": [
        {"repository": repo, "issue": 5, "workspace": "/var/tmp/innovation-symphony-v0-rerun1/workspaces/v1/GH-5"},
    ]}]}, sandboxed)
    for item in sandboxed:
        if item["runtime"] != "rerun1" or item["repo"] != repo:
            raise RuntimeError(f"sandbox session attach {item}")
    from .common import issue_from_prompt
    if issue_from_prompt("Diagnose repeated or unclassified technical failures for GH-5.") != "GH-5":
        raise RuntimeError("issue from diagnosis prompt")
    if issue_from_prompt("This is an authorized local execution preflight") is not None:
        raise RuntimeError("preflight prompt must not gain an issue")
    if attempt_of(
        "/var/tmp/innovation-symphony-v0-rerun1/workspaces/v1/GH-3",
        "/var/tmp/innovation-symphony-v0-rerun1/state/attempt-4/522ff094.json",
    ) != "":
        raise RuntimeError("state directory must not label another issue as attempt-4")
    if attempt_of(
        "/var/tmp/innovation-symphony-v0-rerun1/workspaces/attempt-4/GH-1",
        "/var/tmp/innovation-symphony-v0-rerun1/state/no-attempt/x.json",
    ) != "attempt-4":
        raise RuntimeError("workspace attempt")
    listed = listed_runtimes({"runtimes": [
        {"root": "/var/tmp/innovation-symphony-v0", "receipts": []},
        {"root": "/var/tmp/innovation-symphony-v0-rerun1", "receipts": [{"issue": 1}]},
    ]})
    if listed != [{"name": "rerun1", "root": "/var/tmp/innovation-symphony-v0-rerun1"}]:
        raise RuntimeError(f"listed runtimes {listed}")
    # 沙箱孤儿会话必须挂到同 runtime+issue 的最新尝试上
    sandbox_session = [{
        "meta": {"session_id": "01a0ede3-aaaa"},
        "cwd": "/var/tmp/innovation-symphony-v0-rerun1/sandboxes/run-9/codex-home",
        "prompt": "Implement only this repository's issue: GH-5 watchdog",
        "issue": "GH-5", "runtime": "rerun1", "repo": repo,
        "first_ts": "2026-09-29T15:57:00Z", "last_ts": "2026-09-29T16:00:00Z",
        "entries": 4, "counts": {"reasoning": 2, "tool": 1, "assistant": 1, "user": 0, "developer": 0},
        "tokens": {"input_tokens": 10, "total_tokens": 12}, "agent_msgs": [],
        "bytes": 100, "remote": "/remote/rollout.jsonl", "local": None, "title": "T",
    }]
    sandbox_snapshot = {"runtimes": [{"root": "/var/tmp/innovation-symphony-v0-rerun1", "receipts": [
        {"repository": repo, "issue": 5, "status": "coding", "updated_at": "2026-09-29T16:05:00Z",
         "workspace": "/var/tmp/innovation-symphony-v0-rerun1/workspaces/v1/GH-5", "_path": "/tmp/9c22.json"},
    ], "evidence": [], "logs": []}]}
    sandbox_tasks = build_tasks(sandbox_snapshot, sandbox_session, {})
    if len(sandbox_tasks) != 1 or len(sandbox_tasks[0]["sessions"]) != 1:
        raise RuntimeError(f"sandbox orphan must attach {[(t['id'], len(t['sessions'])) for t in sandbox_tasks]}")
    if sandbox_tasks[0]["sessions"][0]["short"] != "01a0ede3":
        raise RuntimeError(f"sandbox orphan session {sandbox_tasks[0]['sessions']}")
    fd, sample_path = tempfile.mkstemp(prefix="symphony-codex-", suffix=".jsonl")
    os.close(fd)
    sample = "\n".join([
        json.dumps({
            "timestamp": "2026-09-29T09:49:30.444Z",
            "type": "session_meta",
            "payload": {
                "id": "01a0ec91-b660-7f81-9abf-0acf6b339c29",
                "session_id": "01a0ec91-b660-7f81-9abf-0acf6b339c29",
                "timestamp": "2026-09-29T09:49:27.527Z",
                "cwd": "/tmp/ws",
                "cli_version": "0.157.1",
            },
        }),
        json.dumps({
            "timestamp": "2026-09-29T09:49:31.000Z",
            "type": "event_msg",
            "payload": {
                "type": "item_completed",
                "item": {
                    "type": "UserMessage",
                    "content": [{"type": "text", "text": "Implement only this repository issue: GH-5 watch"}],
                },
            },
        }),
        json.dumps({
            "timestamp": "2026-09-29T09:49:32.000Z",
            "type": "response_item",
            "payload": {"type": "reasoning", "summary": [], "encrypted_content": "gAAAA-secret-thought"},
        }),
    ]) + "\n"
    try:
        with open(sample_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(sample)
        page = stamp_codex_page(
            codex_transcript_html(sample_path),
            "GH-5 编码会话",
            "编码代理。",
            "/var/tmp/session.jsonl",
            5,
        )
        # viewer_pages 必须接收原始解析对象（含 local 路径）；传错成 public 字典会静默生成 0 页
        fixture_session = {
            "meta": {"session_id": "01a0ec91-b660-7f81-9abf-0acf6b339c29", "cwd": "/tmp/ws"},
            "cwd": "/tmp/ws", "prompt": "Implement only this repository's issue: GH-5 watch",
            "issue": "GH-5", "runtime": "rerun1", "repo": "", "local": sample_path,
            "remote": "/remote/rollout.jsonl", "bytes": os.path.getsize(sample_path),
            "first_ts": "2026-09-29T09:49:30Z", "last_ts": "2026-09-29T09:49:32Z",
            "entries": 3, "counts": {"reasoning": 1, "tool": 0, "assistant": 0, "user": 1, "developer": 0},
            "tokens": None, "agent_msgs": [], "title": "T",
        }
        pages = viewer_pages([fixture_session], 5)
        if not pages or pages[0][0] != "context-01a0ec91-b660-7f81-9abf-0acf6b339c29.html":
            raise RuntimeError(f"viewer pages {[(name, len(html)) for name, html in pages]}")
    finally:
        from .pagegen import _CODEX_HTML
        _CODEX_HTML.pop(sample_path, None)
        try:
            os.remove(sample_path)
        except OSError:
            pass
    if page.count('href="workbench.html"') < 2 or "返回工作台" not in page:
        raise RuntimeError("codex page missing workbench link")
    if "GH-5 编码会话" not in page or "Implement only this repository issue: GH-5 watch" not in page:
        raise RuntimeError("codex page missing transcript")
    if "gAAAA-secret-thought" in page or 'class="user-message"' not in page:
        raise RuntimeError("codex page leaked reasoning or dropped the masonc15 shell")
    if "编码代理。" not in page or "/var/tmp/session.jsonl" not in page:
        raise RuntimeError("codex page missing symphony note")
    if "refreshSilent" not in page or "setInterval(refreshSilent, 5 * 1000)" not in page:
        raise RuntimeError("context page missing silent refresh")
    if 'http-equiv="refresh"' in page or r"Generated \d{4}" not in page:
        raise RuntimeError("context page reloads or ignores the viewer minute")
    token = re.search(r'data-transcript="([0-9a-f]{20})"', page)
    if not token:
        raise RuntimeError("context page missing transcript token")
    if transcript_token("Generated 2026-09-29 19:26") != transcript_token("Generated 2026-09-29 19:27"):
        raise RuntimeError("viewer minute changed the transcript token")
    if transcript_token(page) == transcript_token(page + "tail"):
        raise RuntimeError("transcript token ignored a body change")
    ordered = sorted(
        ["round-11/check-1.log", "round-2/review.json", "round-10/check-1.log",
         "round-2/check-2.log", "round-1/check-1.log", "round-2/check-1.log"],
        key=natural_name,
    )
    if ordered != [
        "round-1/check-1.log", "round-2/check-1.log", "round-2/check-2.log",
        "round-2/review.json", "round-10/check-1.log", "round-11/check-1.log",
    ]:
        raise RuntimeError(f"evidence order {ordered}")
    if cycle_pause(2, 5) != 3 or cycle_pause(5, 5) != 0 or cycle_pause(7, 5) != 0:
        raise RuntimeError("cycle pause")
    stamped = page_body('{"generated":"生成 09-29 19:07:31","tasks":[]}')
    if "19:07:31" in stamped or "生成" not in stamped:
        raise RuntimeError(f"stamp strip {stamped}")
    _check_config()
    _check_store()
    _check_cost()


def _check_cost():
    from .common import token_cost
    from .config import CostCfg
    off = CostCfg()
    if token_cost({"input_tokens": 1000, "output_tokens": 100}, off) is not None:
        raise RuntimeError("cost must stay off without prices")
    cost = CostCfg(input_per_m=2.0, cached_input_per_m=0.4, output_per_m=8.0)
    if not cost.enabled:
        raise RuntimeError("cost enabled flag")
    value = token_cost({
        "input_tokens": 1_000_000, "cached_input_tokens": 600_000,
        "cache_write_input_tokens": 100_000, "output_tokens": 250_000,
    }, cost)
    # 普通输入 (1M-600k+100k)=0.5M×2 + 缓存 0.6M×0.4 + 输出 0.25M×8 = 1.0+0.24+2.0
    if abs(value - 3.24) > 1e-6:
        raise RuntimeError(f"token cost {value}")
    if token_cost(None, cost) is not None or token_cost({"input_tokens": 5}, None) is not None:
        raise RuntimeError("token cost guards")
    cfg = _from_dicts({"board": {"stall_hours": 6}, "cost": {"currency": "$", "output_per_m": 3}}, "c", True)
    if cfg.stall_hours != 6 or cfg.cost.currency != "$" or not cfg.cost.enabled:
        raise RuntimeError(f"stall/cost config {cfg.stall_hours} {cfg.cost}")


def _check_config():
    defaults = _from_dicts({}, "config.toml", False)
    if defaults.interval != 5 or defaults.has_repo_entries() or defaults.exists:
        raise RuntimeError(f"config defaults {defaults}")
    if defaults.globs() != ["/var/tmp/innovation-symphony-v0*"]:
        raise RuntimeError(f"config default glob {defaults.globs()}")
    cfg = _from_dicts({
        "board": {
            "title": "监控", "interval": 3, "runtime_glob": "/var/tmp/a*",
            "repos": [
                {"name": "acme/widget", "alias": "组件", "glob": "/var/tmp/b*", "enabled": True},
                {"name": "acme/hidden", "enabled": False},
            ],
        },
    }, "config.toml", True)
    if cfg.interval != 3 or cfg.title != "监控":
        raise RuntimeError("config board section")
    if cfg.globs() != ["/var/tmp/a*", "/var/tmp/b*"]:
        raise RuntimeError(f"config globs {cfg.globs()}")
    if cfg.alias_of("acme/widget") != "组件" or cfg.alias_of("acme/other") != "acme/other":
        raise RuntimeError("config alias")
    pending = cfg.pending({"runtimes": [
        {"root": "/var/tmp/a1", "receipts": [{"repository": "acme/widget"}, {"repository": "acme/new"}]},
        {"root": "/var/tmp/a2", "receipts": [{"repository": "acme/new"}]},
    ]})
    if pending != [{"runtime": "a1", "repo": "acme/new"}] and pending != [{"runtime": "a1", "repo": "acme/new"}, {"runtime": "a2", "repo": "acme/new"}]:
        raise RuntimeError(f"config pending {pending}")


def _check_store():
    tmp = tempfile.mkdtemp(prefix="symphony-board-db-")
    store = BoardStore(os.path.join(tmp, "board.db"))
    base = {
        "id": "acme--widget--v0--GH-1", "repo": "acme/widget", "runtime": "v0",
        "issue": "1", "attempt": "", "workspace": "/ws/GH-1", "title": "T",
        "statusLabel": "编码中", "reason": "", "updated": "09-29 10:00:00",
        "pr": None, "evidence": [], "receipt": {}, "_matched": [],
    }
    first = [dict(base, status="coding")]
    store.update_cycle(first, [], [])
    second = [dict(base, status="checking")]
    transitions = store.update_cycle(second, [], [])
    rows = transitions["acme--widget--v0--GH-1"]
    if len(rows) != 2 or rows[0]["to"] != "coding" or rows[1]["from"] != "coding" or rows[1]["to"] != "checking":
        raise RuntimeError(f"store transitions {rows}")
    if store.history_counts()["transitions"] != 2:
        raise RuntimeError("store history counts")
    store.close()
