# -*- coding: utf-8 -*-
"""Derive board data (tasks, stories, logs) from a raw runtime snapshot.

Ported from build/symphony-watch.py.
"""
import json
import os
import re
import subprocess

from .collector import parse_log, public_session, role_of
from .common import (
    STATUS_LABEL, attempt_of, badge_class, clip, clock, dur, dur_from_stamps,
    natural_name, repo_of, repo_slug, short_runtime, sort_ts, stage_of, task_repo,
)

EVIDENCE_RE = re.compile(r'^\{:command_failed,\s*(-?\d+),\s*"(.*)"\s*\}$', re.S)
CHECK_STAGE_RE = re.compile(
    r"\[check\] stage=(\S+) child_exit=(-?\d+) outcome=(-?\d+)(?: reason=(.*))?"
)
STAGE_BUSY = {
    "deps": "正在获取依赖",
    "format": "正在做格式检查",
    "lint": "正在做 Credo 检查",
    "test": "正在跑测试和覆盖率",
}


def elixir_unescape(text):
    out = []
    i = 0
    while i < len(text):
        if text[i] != "\\" or i + 1 >= len(text):
            out.append(text[i])
            i += 1
            continue
        n = text[i + 1]
        mapped = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", '"': '"'}
        if n in mapped:
            out.append(mapped[n])
            i += 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def decode_check_log(text):
    raw = text.strip()
    m = EVIDENCE_RE.fullmatch(raw)
    if not m:
        return {"exit": None, "body": raw, "tail": False}
    return {"exit": int(m.group(1)), "body": elixir_unescape(m.group(2)), "tail": True}


def failing_check_outcome(body):
    for match in CHECK_STAGE_RE.finditer(body or ""):
        outcome = int(match.group(3))
        if outcome != 0:
            return outcome
    return None


def open_check_stage(body):
    finished = {match.group(1) for match in CHECK_STAGE_RE.finditer(body or "")}
    started = re.findall(r"\[check\] stage=(\S+) (?:run_id|command)=", body or "")
    for stage in reversed(started):
        if stage not in finished:
            return stage
    return ""


def summarize_check(body):
    lines = []
    tests = re.search(r"(\d+)\s+tests?,\s+(\d+)\s+failures?(?:,\s+(\d+)\s+skipped)?", body)
    if tests:
        skipped = f"，{tests.group(3)} 项跳过" if tests.group(3) else ""
        lines.append(f"{tests.group(1)} 项测试，{tests.group(2)} 项失败{skipped}")
    cov = re.search(r"Coverage:\s*([\d.]+%)", body)
    thr = re.search(r"Threshold:\s*([\d.]+%)", body)
    if cov and thr:
        lines.append(f"覆盖率 {cov.group(1)}，阈值 {thr.group(1)}")
    cmd = re.search(r"Command '?(\[[^\]]+\])'? returned non-zero exit status (\d+)", body)
    if cmd:
        lines.append(f"{cmd.group(1)} 退出码 {cmd.group(2)}")
    if failing_check_outcome(body) is not None:
        credo = re.search(r"found (\d+) refactoring opportunities", body)
        if credo and int(credo.group(1)) > 0:
            lines.append(f"Credo：{credo.group(1)} 处复杂度或嵌套问题")
        readable = re.search(r"found (\d+) code readability issues?", body)
        if readable and int(readable.group(1)) > 0:
            mark = re.search(
                r"Numbers larger than 9999 should be written with underscores:\s*([0-9][0-9_]*)",
                body,
            )
            if mark and int(readable.group(1)) == 1:
                lines.append(f"Credo：数字应写成 {mark.group(1)}")
            else:
                lines.append(f"Credo：{readable.group(1)} 处可读性问题")
        dialyzer = re.search(r"Total errors:\s*(\d+)", body)
        if dialyzer and int(dialyzer.group(1)) > 0:
            names = re.findall(r"Function ([A-Za-z0-9_]+/\d+) has no local return", body)
            if names:
                lines.append(f"Dialyzer：{dialyzer.group(1)} 处，{names[0]} 无返回")
            else:
                lines.append(f"Dialyzer：{dialyzer.group(1)} 个错误")
    under = []
    for pct, name in re.findall(r"\|\s+([\d.]+%)\s+\|\s+([^|]+?)\s+\|", body):
        name = name.strip()
        if pct != "100.00%" and name not in ("Percentage", "---"):
            under.append(f"{name} {pct}")
    return {"lines": lines, "under": under}


def evidence_view(item):
    if os.path.basename(item["name"].replace("\\", "/")) == "review.json":
        body = item["text"].strip()
        approved = None
        summary = "审查输出"
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, dict):
            approved = parsed.get("approved")
            text = parsed.get("summary") if isinstance(parsed.get("summary"), str) else ""
            verdict = {True: "批准", False: "拒绝"}.get(approved, "审查输出")
            summary = f"{verdict}。{text}".strip() if text else verdict
        return {
            "name": item["name"], "path": item["path"], "bytes": item["bytes"],
            "exit": None, "summary": summary, "under": [], "body": body, "tail": False,
            "approved": approved,
        }
    decoded = decode_check_log(item["text"])
    summary = summarize_check(decoded["body"])
    text = " · ".join(summary["lines"])
    exit_code = decoded["exit"]
    if exit_code is None:
        exit_code = failing_check_outcome(decoded["body"])
    if exit_code is not None:
        prefix = f"退出码 {exit_code}"
        text = f"{prefix} · {text}" if text else prefix
    open_stage = "" if exit_code is not None else open_check_stage(decoded["body"])
    if open_stage and not text:
        text = STAGE_BUSY.get(open_stage, "自动检查还在跑")
    return {
        "name": item["name"], "path": item["path"], "bytes": item["bytes"],
        "exit": exit_code, "summary": text or item["name"],
        "under": summary["under"], "body": decoded["body"], "tail": decoded["tail"],
        "open": open_stage,
    }


def sum_tokens(items):
    keys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens",
            "output_tokens", "reasoning_output_tokens", "total_tokens"]
    acc = {k: 0 for k in keys}
    found = False
    for item in items:
        if not item:
            continue
        found = True
        for key in keys:
            acc[key] += int(item.get(key) or 0)
    return acc if found else None


def evidence_failed(item):
    if item.get("exit") is not None or item.get("tail"):
        return True
    return bool(re.search(r"[1-9]\d* 项失败", item.get("summary") or ""))


def result_text(status, reason, cand, session_bits, evidence):
    parts = []
    if status in ("coding", "checking", "reviewing", "recovering") or "mvp_invalid_review" in (reason or ""):
        evidence = []  # Previous check failures are history while this stage runs again.
    failed = [item for item in evidence if evidence_failed(item)]
    passed = [item for item in evidence if not evidence_failed(item)]
    if failed:
        ev = failed[0]
        parts.append(f"检查未通过（{ev['name']}）。{ev['summary']}。")
        if ev["under"]:
            parts.append("低于 100%：" + "、".join(ev["under"]) + "。")
        if ev["tail"]:
            parts.append("失败时控制器只把命令输出的最后 4000 个字符写入这份日志，更前面的失败用例名不在文件里。")
    elif passed:
        parts.append("检查日志：" + "；".join(f"{item['name']} {item['summary']}" for item in passed) + "。")
    if "mvp_candidate_or_baseline_changed" in (reason or ""):
        parts.append("检查跑完后，控制器发现候选提交或基线快照变了，任务阻塞。")
    elif not failed and "response_timeout" in (reason or ""):
        parts.append("编码会话没有在时限内返回。这次尝试没有 check 日志。")
    elif status == "checking":
        parts.append("正在跑自动检查。check 日志要等这条命令结束才写入。")
    elif status == "coding":
        parts.append("正在编码。检查日志要等这一轮检查跑完才会出现。")
    elif status == "recovering":
        parts.append("正在做只读诊断，决定下一轮怎么返工。")
    elif status == "reviewing":
        parts.append("正在进行独立审查，结论以控制器接受的结果为准。")
    elif "mvp_invalid_review" in (reason or ""):
        parts.append("审查输出未通过协议校验，任务受阻；该输出不是有效的通过或打回结论。")
    elif status in ("awaiting_review", "pr_ready"):
        parts.append("已交付 Draft PR，等待人工审查。自动检查通过不代表已合并或部署。")
    elif status in ("done", "merged"):
        parts.append("任务完成。")
    elif reason and status == "blocked":
        parts.append(f"任务阻塞（{reason}）。")
    else:
        parts.append(f"状态：{status}。")
    if cand and cand != "—":
        parts.append(f"候选提交 {cand}。")
    if session_bits:
        parts.append("会话 " + "、".join(session_bits) + "。")
    return " ".join(parts)


def task_events(log_entries, workspace, session_ids, agent_msgs, issue_no, reason):
    events = []
    for entry in log_entries:
        if not entry["key"]:
            continue
        msg = entry["msg"]
        matched = bool(workspace and workspace in msg)
        matched = matched or any(sid and sid in msg for sid in session_ids)
        if reason and reason in msg and re.search(rf"issue_id={re.escape(str(issue_no))}\b", msg):
            matched = True
        if not matched:
            continue
        tag = "控制器⚠" if entry["level"] == "warning" else "控制器"
        events.append((entry.get("sort") or 0, f"{entry['clock']}  [{tag}] {msg}"))
    for ts, txt in agent_msgs:
        events.append((sort_ts(ts), f"{clock(ts)}  [模型进展] {txt[:180]}"))
    events.sort(key=lambda item: item[0])
    return [text for _, text in events]


def issue_title(issue_gid, matched, sessions):
    for session in matched:
        if session.get("title") and role_of(session) == "编码":
            return session["title"]
    for session in matched:
        if session.get("title"):
            return session["title"]
    for session in sessions:
        if session.get("issue") == issue_gid and session.get("title") and role_of(session) == "编码":
            return session["title"]
    return None


def tidy_pct(value):
    num = value[:-1] if str(value).endswith("%") else str(value)
    if "." in num:
        num = num.rstrip("0").rstrip(".")
    return f"{num}%"


def glance_check(summary):
    text = summary or ""
    tests = re.search(r"(\d+)\s*项测试，(\d+)\s*项失败", text)
    cov = re.search(r"覆盖率\s*([\d.]+%)，阈值\s*([\d.]+%)", text)
    parts = []
    if tests and int(tests.group(2)) > 0:
        parts.append(f"{tests.group(1)} 项测试，{tests.group(2)} 项失败")
    if cov and tidy_pct(cov.group(1)) != tidy_pct(cov.group(2)):
        parts.append(f"覆盖率 {tidy_pct(cov.group(1))}，阈值 {tidy_pct(cov.group(2))}")
    if parts:
        return "；".join(parts)
    text = re.sub(r"\d+\s*项测试，0\s*项失败(?:，\d+\s*项跳过)?", " ", text)
    cleaned = re.sub(r"退出码\s*-?\d+", "", text)
    cleaned = re.sub(r"\[[^\]]*\]", "", cleaned)
    cleaned = " ".join(cleaned.replace("·", " ").split())
    return clip(cleaned, 48) or "自动检查没有通过"


def glance_review(summary):
    text = " ".join((summary or "").split())
    text = re.sub(r"^(?:拒绝|批准)。\s*", "", text)
    text = re.sub(r"^拒绝(?:批准)?候选\s*[0-9a-fA-F]{7,64}[。：:]\s*", "", text)
    text = re.sub(r"^\[\s*P\d+\s*\]\s*", "", text)
    text = re.sub(r"^[①②③④⑤⑥⑦⑧⑨]\s*", "", text)
    text = text.strip()
    if not text:
        return "Review 没有批准这次候选"
    head = re.split(r"[。；;]", text, maxsplit=1)[0].strip()
    if re.search(r"[：:]", head):
        left = re.split(r"[：:]", head, maxsplit=1)[0].strip()
        if 6 <= len(left) <= 36:
            head = left
    if len(head) > 36:
        piece = re.split(r"[，,]", head, maxsplit=1)[0].strip()
        if 6 <= len(piece) <= 36:
            head = piece
    if len(head) > 42:
        head = head[:42].rstrip("，,、 ") + "…"
    return head or "Review 没有批准这次候选"


def is_review_evidence(item):
    return os.path.basename((item.get("name") or "").replace("\\", "/")) == "review.json"


def evidence_round(name):
    match = re.search(r"round-(\d+)/", (name or "").replace("\\", "/"))
    return int(match.group(1)) if match else None


def attached_evidence_round(item):
    return item.get("round") if "round" in item else evidence_round(item.get("name"))


def attach_evidence_rounds(items, receipt):
    if not receipt.get("rounds"):
        return
    for item in items:
        directory = os.path.normpath(os.path.dirname(item.get("path") or ""))
        matches = {r.get("round") for r in receipt.get("rounds") or []
                   if isinstance(r, dict) and isinstance(r.get("evidence"), str)
                   and os.path.normpath(r["evidence"]) == directory
                   and type(r.get("round")) is int and r["round"] > 0}
        item["round"] = next(iter(matches)) if len(matches) == 1 else None
        item["roundSource"] = "controller" if item["round"] is not None else "unassigned"


def causes_for_group(items):
    reviews = [item for item in items if is_review_evidence(item)]
    checks = [item for item in items if not is_review_evidence(item)]
    found = []
    failed = [item for item in checks if evidence_failed(item)]
    if failed:
        whys = []
        for item in failed:
            why = glance_check(item.get("summary") or "")
            if why and why not in whys:
                whys.append(why)
        found.append({"kind": "script", "title": "脚本审查未通过", "why": "；".join(whys[:2])})
    rejected = [item for item in reviews if item.get("approved") is False]
    if rejected:
        found.append({
            "kind": "review",
            "title": "Review 未通过",
            "why": glance_review(rejected[-1].get("summary") or ""),
        })
    return found


def rework_returns(task):
    pr = task.get("pr") if isinstance(task.get("pr"), dict) else {}
    state = pr.get("state")
    if state == "merged" or task.get("status") in ("done", "merged"):
        return []
    if state == "changes":
        return [{"kind": "human", "title": "人工要求修改", "why": "最新审查结论是要求修改"}]
    if state == "closed":
        return [{"kind": "human", "title": "人工未通过", "why": "PR 已关闭，没有合并"}]
    reason = task.get("reason") or ""
    if "response_timeout" in reason:
        return [{"kind": "timeout", "title": "编码超时", "why": "会话没有在时限内返回，没有进入脚本审查"}]
    if "mvp_candidate_or_baseline_changed" in reason:
        return [{"kind": "invalidated", "title": "结果作废", "why": "脚本审查已通过，之后候选提交或基线变了"}]
    grouped = {}
    for item in task.get("evidence") or []:
        if isinstance(item, dict):
            grouped.setdefault(attached_evidence_round(item), []).append(item)
    numbered = sorted(number for number in grouped if isinstance(number, int))
    if numbered:
        found = []
        for number in numbered:
            for cause in causes_for_group(grouped[number]):
                found.append({"n": number, **cause})
        if found:
            return found
    loose = causes_for_group(grouped.get(None, []))
    if "mvp_review_not_approved" in reason:
        review = next((item for item in loose if item["kind"] == "review"), None)
        return [review or {"kind": "review", "title": "Review 未通过", "why": "Review 没有批准这次候选"}]
    if "mvp_check_failed" in reason:
        script = next((item for item in loose if item["kind"] == "script"), None)
        return [script or {"kind": "script", "title": "脚本审查未通过", "why": "自动检查没有通过"}]
    return loose


def handoff_text(reason):
    text = reason or ""
    if "response_timeout" in text:
        return "编码会话超时，控制器再次派发"
    if "mvp_candidate_or_baseline_changed" in text:
        return "检查之后候选提交或基线快照变了，这次作废"
    if "mvp_review_not_approved" in text:
        return "Review 未通过"
    if "mvp_check_failed" in text:
        return "脚本审查未通过"
    return text


def beat_handoff(task):
    returns = task.get("returns") or []
    if returns:
        item = returns[-1]
        return f"{item['title']}：{item['why']}"
    pr = task.get("pr") if isinstance(task.get("pr"), dict) else {}
    if pr.get("state") == "merged":
        return "人工已合并"
    if pr.get("state") in ("closed", "changes"):
        return "人工没有合并，打回重做"
    return handoff_text(task.get("reason"))


def pr_label(pr):
    number = pr.get("number") if isinstance(pr, dict) else None
    return f"PR #{number}" if number else "PR"


def story_outcome(last):
    status = last.get("status")
    pr = last.get("pr") if isinstance(last.get("pr"), dict) else {}
    state = pr.get("state")
    label = pr_label(pr)
    returns = last.get("returns") or []
    if state == "merged" or status in ("done", "merged"):
        detail = f"人工已合并 {label}。" if state == "merged" else (last.get("statusLabel") or "已交付")
        return "已交付", "done", "b-done", detail
    if state in ("closed", "changes"):
        why = (returns[0]["why"] if returns else "") or f"人工没有通过 {label}，这次要重做。"
        return "打回重做", "blocked", "b-blocked", why
    if status in ("awaiting_human", "awaiting_review", "pr_ready"):
        if pr.get("url") and state in ("open", "unknown", None, ""):
            tail = "合并后进入已交付。" if state == "open" else ""
            return "进入人审", "human", "b-done", f"Review 已批准，去处理 {label}。{tail}".strip()
        return "进入人审", "human", "b-done", "Review 已批准，等待人工。还没有合并或部署。"
    if status == "blocked":
        if returns:
            item = returns[-1]
            badge = "b-review" if item["kind"] == "review" else "b-blocked"
            return item["title"], "blocked", badge, item["why"]
        detail = handoff_text(last.get("reason")) or "仍被挡住"
        return "仍被挡住", "blocked", "b-blocked", detail
    if status in ("coding", "checking", "review", "reviewing", "recovering"):
        detail = "只读诊断正在决定怎么返工。" if status == "recovering" else "这一拍还在进行。"
        return last.get("statusLabel") or status, "running", last.get("badge") or "b-running", detail
    return last.get("statusLabel") or status or "未知", "other", last.get("badge") or "", last.get("reason") or ""


def gate_follow(nxt):
    if not nxt:
        return "这一轮被打回"
    if nxt.get("role") == "诊断":
        return "控制器先派只读诊断，再决定怎么返工"
    return "这一轮被打回，后面的会话接着做"


def gate_row(item, follow):
    title = item.get("title") or ""
    if item.get("n"):
        title = f"第 {item['n']} 轮 · {title}"
    return {
        "kind": "gate",
        "tone": "review" if item.get("kind") == "review" else "script",
        "title": title,
        "why": item.get("why") or "",
        "follow": follow,
    }


def session_timeline(sessions, returns):
    """Insert each numbered rejection under the session for that round.

    Only 编码 advances the round. 诊断 stays between rounds and is not a coder.
    """
    sessions = list(sessions or [])
    numbered = [item for item in (returns or []) if item.get("n")]
    used = set()
    rows = []
    coder_n = 0

    def take(kind, number, follow):
        picked = []
        for index, item in enumerate(numbered):
            if index in used or item.get("kind") != kind or item.get("n") != number:
                continue
            used.add(index)
            picked.append(gate_row(item, follow))
        return picked

    for index, session in enumerate(sessions):
        rows.append({"kind": "session", "id": session.get("id") or ""})
        nxt = sessions[index + 1] if index + 1 < len(sessions) else None
        role = session.get("role")
        if role == "编码":
            coder_n += 1
            rows.extend(take("script", coder_n, gate_follow(nxt)))
        elif role == "Review":
            rows.extend(take("review", coder_n, gate_follow(nxt)))
    for index, item in enumerate(numbered):
        if index not in used:
            rows.append(gate_row(item, "这一轮被打回"))
    return rows


def checking_row(task):
    if task.get("status") != "checking":
        return None
    chosen = None
    for item in task.get("evidence") or []:
        if is_review_evidence(item) or evidence_failed(item) or not item.get("open"):
            continue
        chosen = item
    if not chosen:
        return None
    number = attached_evidence_round(chosen)
    title = f"第 {number} 轮 · 脚本审查进行中" if number else "脚本审查进行中"
    return {
        "kind": "gate",
        "tone": "run",
        "title": title,
        "why": STAGE_BUSY.get(chosen.get("open"), "自动检查还在跑"),
        "follow": "",
    }


def build_stories(tasks):
    for task in tasks:
        task["returns"] = rework_returns(task)
        task["timeline"] = session_timeline(task.get("sessions") or [], task["returns"])
        running = checking_row(task)
        if running:
            task["timeline"].append(running)
    groups, order = {}, []
    for task in tasks:
        repo = task_repo(task)
        key = (repo, task["runtime"], str(task["issue"]))
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(task)
    stories = []
    for repo, runtime, issue in order:
        beats_src = groups[(repo, runtime, issue)]
        beats_src.sort(key=lambda task: int(re.search(r"(\d+)", task["attempt"]).group(1)) if re.search(r"(\d+)", task["attempt"]) else 0)
        last = beats_src[-1]
        outcome, kind, badge, detail = story_outcome(last)
        beats = []
        for index, task in enumerate(beats_src, 1):
            label = f"第 {index} 次" + (f" · {task['attempt']}" if task.get("attempt") else "")
            beats.append({
                "taskId": task["id"],
                "n": index,
                "attempt": task.get("attempt") or "",
                "label": label,
                "status": task.get("status"),
                "statusLabel": task.get("statusLabel"),
                "badge": task.get("badge"),
                "reason": task.get("reason") or "",
                "returns": task.get("returns") or [],
                "handoff": beat_handoff(task) if index < len(beats_src) else "",
                "pr": task.get("pr"),
                "gap": task.get("gap") or "",
                "flow": task.get("flow") or [],
                "duration": task.get("duration") or "—",
            })
        title = next((task["title"] for task in beats_src if task.get("title")), f"Issue #{issue}")
        stories.append({
            "id": f"story--{repo_slug(repo)}--{runtime}--GH-{issue}",
            "repo": repo,
            "runtime": runtime,
            "issue": issue,
            "issueLabel": f"GH-{issue}",
            "title": title,
            "meta": f"{repo} · {runtime} · Issue #{issue} · {len(beats)} 次尝试",
            "attempts": len(beats),
            "outcome": outcome,
            "outcomeKind": kind,
            "outcomeDetail": detail,
            "badge": badge,
            "pr": last.get("pr"),
            "preflight": beats_src[0].get("preflight") or [],
            "beats": beats,
        })
    return stories


def token_brief(usage):
    if not isinstance(usage, dict) or usage.get("total_tokens") is None:
        return None
    return {
        "input": usage.get("input_tokens"),
        "output": usage.get("output_tokens"),
        "total": usage.get("total_tokens"),
    }


def execution_summary(receipt):
    """Read explicit controller fields; missing historical evidence stays unknown."""
    recovery = receipt.get("recovery") if isinstance(receipt.get("recovery"), dict) else {}
    failure = receipt.get("check_failure") if isinstance(receipt.get("check_failure"), dict) else {}
    artifacts = [item for item in receipt.get("sandbox_artifacts", []) if isinstance(item, dict)]
    latest = artifacts[-1] if artifacts else {}
    def count(value):
        return value if type(value) is int and value >= 0 else None
    def flag(key):
        value = latest.get(key)
        return value if type(value) is bool else None
    start, end = latest.get("started_at_epoch"), latest.get("ended_at_epoch")
    elapsed = end - start if type(start) is int and type(end) is int and end >= start else None
    return {
        "failureCategory": failure.get("category"),
        "reworkCount": count(receipt.get("rework_count")),
        "agentAttempts": count(recovery.get("agent_attempts")),
        "stageRetries": count(receipt.get("stage_retries")),
        "externalProbeReservations": count(receipt.get("external_probe_calls")),
        "sourceSaved": flag("source_saved"),
        "exportComplete": flag("export_complete"),
        "cleanupComplete": flag("cleanup_complete"),
        "externalWaiting": receipt.get("status") == "awaiting_external",
        "latestStage": latest.get("role"),
        "latestStageSeconds": elapsed,
    }


def rounds_view(receipt):
    rows = []
    for rnd in receipt.get("rounds") or []:
        if not isinstance(rnd, dict):
            continue
        usage = rnd.get("usage") or {}
        review = rnd.get("review")
        accepted = isinstance(review, dict) and isinstance(review.get("approved"), bool)
        rows.append({
            "round": rnd.get("round"),
            "coder": token_brief(usage.get("coder")),
            "reviewer": token_brief(usage.get("reviewer")),
            "controller": True,
            "status": rnd.get("status") or "",
            "reason": rnd.get("reason") or "",
            "review": {"approved": review["approved"], "summary": clip(review.get("summary") or "", 400)} if accepted else None,
            "accepted": accepted,
            "candidate": (rnd.get("candidate_sha") or "")[:7],
        })
    return rows


def attach_attempts(publics, receipt, raw_sessions=()):
    """Exact session ids link attempts to controller rounds; never infer a round."""
    links = {a.get("session_id"): a for a in receipt.get("_agent_attempts") or [] if a.get("session_id")}
    for run in receipt.get("_legacy_agent_runs") or []:
        prefix = run["sessionsRoot"].rstrip("/") + "/"
        candidates = [s for s in raw_sessions if (s.get("remote") or "").startswith(prefix)]
        # Multiple rollouts cannot be disambiguated by chronology or usage.
        if len(candidates) == 1:
            sid = (candidates[0].get("meta") or {}).get("session_id")
            if sid and sid not in links:
                links[sid] = {"round": run["round"], "roundSource": "controller",
                              "outcome": run["outcome"],
                              "status": "failed" if run["outcome"] == "timeout" else "unknown"}
    numbers = {r.get("round") for r in receipt.get("rounds") or [] if isinstance(r, dict)}
    for session in publics:
        link = links.get(session["id"], {})
        number = link.get("round")
        known = number in numbers and isinstance(number, int) and not isinstance(number, bool)
        session.update({
            "round": number if known else None,
            "attempt": link.get("attempt"),
            "stageAttempt": link.get("stageAttempt"),
            "attemptStatus": link.get("status") or "unknown",
            "attemptOutcome": link.get("outcome") or "unknown",
            "roundSource": link.get("roundSource") if known else "unassigned",
        })


def workflow_of(publics, evidence, status_label, reason):
    coders = [item for item in publics if item["role"] == "编码"]
    reviews = [item for item in publics if item["role"] == "Review"]
    unknown = [item for item in publics if item["role"] == "未识别"]
    checks = [item for item in evidence if os.path.basename(item["name"]) != "review.json"]
    opinions = [item for item in evidence if os.path.basename(item["name"]) == "review.json"]
    steps = []
    if coders:
        for item in coders:
            steps.append({"kind": "coder", "state": "present", "label": "编码代理",
                          "detail": f"{item['short']} · {item['duration']}", "href": item["href"]})
    else:
        steps.append({"kind": "coder", "state": "missing", "label": "编码代理",
                      "detail": "没有编码 rollout", "href": ""})
    if checks:
        for item in checks:
            failed = evidence_failed(item)
            if item.get("open") and not failed:
                state = "current"
            else:
                state = "fail" if failed else "ok"
            steps.append({"kind": "check", "state": state, "label": item["name"],
                          "detail": clip(item.get("summary")), "href": ""})
    else:
        steps.append({"kind": "check", "state": "missing", "label": "检查",
                      "detail": "没有 check-*.log", "href": ""})
    if reviews:
        for item in reviews:
            steps.append({"kind": "review", "state": "present", "label": "Review 代理",
                          "detail": f"{item['short']} · {item['duration']}", "href": item["href"]})
    else:
        steps.append({"kind": "review", "state": "missing", "label": "Review 代理",
                      "detail": "没有 Review rollout", "href": ""})
    for item in unknown:
        steps.append({"kind": "unknown", "state": "missing", "label": "未识别会话",
                      "detail": item["short"], "href": item["href"]})
    if opinions:
        for item in opinions:
            state = {True: "ok", False: "fail"}.get(item.get("approved"), "present")
            steps.append({"kind": "opinion", "state": state, "label": item["name"],
                          "detail": clip(item.get("summary")), "href": ""})
    else:
        steps.append({"kind": "opinion", "state": "missing", "label": "review.json",
                      "detail": "没有审查结果文件", "href": ""})
    steps.append({"kind": "status", "state": "current", "label": status_label or "回执",
                  "detail": reason or "—", "href": ""})
    if not coders and reviews:
        gap = "没有编码 rollout，只有 Review 会话。"
    elif coders and not reviews:
        gap = "有编码会话，没有 Review rollout。"
    elif not coders and not reviews:
        gap = "没有编码或 Review rollout。"
    else:
        gap = ""
    return steps, gap


def attach_session_repos(snapshot, sessions):
    from .collector import runtime_for_cwd, runtime_index
    pairs = runtime_index(snapshot)
    workspace_repo = {}
    repos_by_runtime = {}
    issue_repos = {}
    for runtime in snapshot.get("runtimes", []):
        name = short_runtime(runtime["root"])
        for receipt in runtime.get("receipts", []):
            repo = repo_of(receipt)
            repos_by_runtime.setdefault(name, set()).add(repo)
            gid = f"GH-{receipt.get('issue')}" if receipt.get("issue") is not None else None
            if gid:
                issue_repos.setdefault((name, gid), set()).add(repo)
            workspace = (receipt.get("workspace") or "").rstrip("/")
            if workspace:
                workspace_repo[workspace] = repo
    for session in sessions:
        session["runtime"] = runtime_for_cwd(session.get("cwd"), pairs)
        cwd = (session.get("cwd") or "").rstrip("/")
        repo = workspace_repo.get(cwd, "")
        if not repo:
            # 沙箱会话 cwd 指向沙箱自身：按 runtime+issue 找唯一覆盖它的仓库
            repos = issue_repos.get((session.get("runtime") or "", session.get("issue") or ""))
            if repos and len(repos) == 1:
                repo = next(iter(repos))
        if not repo and role_of(session) == "预检":
            repos = repos_by_runtime.get(session.get("runtime") or "", set())
            if len(repos) == 1:
                repo = next(iter(repos))
        session["repo"] = repo


def _attempt_rank(receipt):
    matched = re.search(r"/attempt-(\d+)/", (receipt.get("workspace") or ""))
    return (0, int(matched.group(1))) if matched else (1, 0)


def claim_sessions(snapshot, sessions):
    """把会话分配给回执。

    第一优先：cwd 精确等于 receipt.workspace（旧布局，也可能同 workspace 多次尝试）。
    回退：沙箱会话（cwd 指向 sandboxes/ 自身）按 runtime+issue 归到该组最新尝试。
    返回 {id(receipt): [session, ...]} 追加集，已精确认领的会话标记进 claimed_ids。
    """
    claimed_ids = set()
    extras = {}
    all_workspaces = set()
    group_receipts = {}
    for runtime in snapshot.get("runtimes", []):
        name = short_runtime(runtime["root"])
        for receipt in runtime.get("receipts", []):
            all_workspaces.add((receipt.get("workspace") or "").rstrip("/"))
            gid = f"GH-{receipt.get('issue')}" if receipt.get("issue") is not None else None
            if gid:
                group_receipts.setdefault((name, gid), []).append(receipt)
    for session in sessions:
        cwd = (session.get("cwd") or "").rstrip("/")
        if cwd and cwd in all_workspaces:
            claimed_ids.add(id(session))
            continue
        gid = session.get("issue")
        candidates = group_receipts.get((session.get("runtime"), gid)) if gid else None
        if not candidates:
            continue
        target = max(candidates, key=_attempt_rank)
        extras.setdefault(id(target), []).append(session)
        claimed_ids.add(id(session))
    return extras, claimed_ids


def build_tasks(snapshot, sessions, logs_by_runtime):
    attach_session_repos(snapshot, sessions)
    extras_by_receipt, _claimed = claim_sessions(snapshot, sessions)
    tasks = []
    for runtime in snapshot.get("runtimes", []):
        name = short_runtime(runtime["root"])
        evidence_by_receipt = {}
        for item in runtime.get("evidence", []):
            evidence_by_receipt.setdefault(item["receipt"], []).append(evidence_view(item))
        log_entries = []
        for log in logs_by_runtime.get(name, []):
            log_entries.extend(log["entries"])
        for receipt in runtime.get("receipts", []):
            issue_no = str(receipt.get("issue"))
            gid = f"GH-{issue_no}"
            workspace = (receipt.get("workspace") or "").rstrip("/")
            attempt = attempt_of(workspace, receipt.get("_path"))
            matched = ([s for s in sessions if (s.get("cwd") or "").rstrip("/") == workspace]
                       + extras_by_receipt.get(id(receipt), []))
            title = issue_title(gid, matched, sessions) or receipt.get("title") or f"Issue #{issue_no}"
            status = receipt.get("status") or ("coding" if matched else "unknown")
            cand_full = receipt.get("candidate_sha") or ""
            cand = cand_full[:7]
            reason = receipt.get("reason") or ""
            models = receipt.get("models") or {}
            evidence = evidence_by_receipt.get(receipt.get("_path"), [])
            evidence.sort(key=lambda item: natural_name(item.get("name") or ""))
            publics = [public_session(s) for s in matched]
            attach_attempts(publics, receipt, sessions)
            attach_evidence_rounds(evidence, receipt)
            round_rows = rounds_view(receipt)
            latest_round = round_rows[-1]["round"] if round_rows else None
            current_evidence = [ev for ev in evidence if attached_evidence_round(ev) == latest_round] if round_rows else evidence
            role_counts = {}
            for item in publics:
                role_counts[item["role"]] = role_counts.get(item["role"], 0) + 1
            preflights = [public_session(s) for s in sessions if s.get("runtime") == name and role_of(s) == "预检"]
            flow, gap = workflow_of(publics, evidence, STATUS_LABEL.get(status, status), reason)
            health = receipt.get("_execution_health") or {}
            stopped = health.get("kind") == "closed_host_interruption"
            if stopped:
                gap = "宿主关机中断已核验并闭合；回执保留历史编码状态，等待受审计接续。"
            session_ids = [(s.get("meta") or {}).get("session_id") or "" for s in matched]
            agent_msgs = [msg for s in matched for msg in s.get("agent_msgs") or []]
            events = task_events(log_entries, workspace, session_ids, agent_msgs, issue_no, reason)
            duration = "—"
            starts = [s["first_ts"] for s in matched if s.get("first_ts")]
            ends = [s["last_ts"] for s in matched if s.get("last_ts")]
            if starts and ends:
                duration = dur(min(starts), max(ends))
            elif events:
                stamps = [e.get("sort") for e in log_entries if e.get("key") and workspace and workspace in e.get("msg", "")]
                if len(stamps) >= 2:
                    duration = dur_from_stamps(stamps)
            repo = repo_of(receipt)
            ident = "--".join(part for part in (repo_slug(repo), name, attempt, gid) if part)
            meta = " · ".join(part for part in (repo, name, attempt, f"Issue #{issue_no}") if part)
            tasks.append({
                "id": ident,
                "repo": repo,
                "repoRaw": (str(receipt.get("repository") or "").strip() or "未知仓库"),
                "runtime": name,
                "attempt": attempt,
                "issue": issue_no,
                "issueLabel": gid,
                "title": title,
                "meta": meta,
                "status": status,
                "statusLabel": "宿主中断 · 历史编码状态" if stopped else STATUS_LABEL.get(status, status),
                "badge": badge_class("blocked" if stopped else status),
                "stage": [1, None] if stopped else list(stage_of(status, cand, reason)),
                **({"executionHealth": health} if stopped else {}),
                "duration": duration,
                "coder": models.get("coder", "—"),
                "reviewer": models.get("reviewer", "—"),
                "base": (receipt.get("base_sha") or "—")[:7],
                "cand": cand or "—",
                "branch": receipt.get("branch") or "—",
                "pullRequest": receipt.get("pull_request") or "",
                "pr": None,
                "reason": reason,
                "workspace": workspace or "—",
                "updated": clock(receipt.get("updated_at")) + " " + (receipt.get("updated_at") or ""),
                "tokens": sum_tokens([s.get("tokens") for s in matched]),
                "entries": sum(s.get("entries") or 0 for s in matched),
                "sessions": publics,
                "preflight": [{"id": item["id"], "short": item["short"], "href": item["href"]} for item in preflights],
                "flow": flow,
                "gap": gap,
                "rounds": round_rows,
                **({"execution": execution_summary(receipt)} if receipt.get("sandbox_artifacts") or "external_probe_calls" in receipt or "stage_retries" in receipt else {}),
                "roundsAuthority": "controller" if round_rows else "legacy",
                "evidence": evidence,
                "logs": events,
                "result": gap if stopped else result_text(status, reason, cand or "—",
                                      [f"{role} {count} 次" for role, count in role_counts.items()], current_evidence),
                "viewer": publics[0]["href"] if publics else "#",
                "receipt": receipt,
                "_matched": matched,
            })
    tasks.sort(key=lambda task: (task["repo"], task["runtime"], int(task["issue"]) if str(task["issue"]).isdigit() else 0,
                                 int(re.search(r"(\d+)", task["attempt"]).group(1)) if re.search(r"(\d+)", task["attempt"]) else 0))
    return tasks


def build_logs(snapshot):
    logs = []
    for runtime in snapshot.get("runtimes", []):
        name = short_runtime(runtime["root"])
        for item in runtime.get("logs", []):
            entries, levels, kinds = parse_log(item.get("text") or "")
            path = item["path"]
            logs.append({
                "id": name + ":" + os.path.basename(path),
                "runtime": name,
                "file": os.path.basename(path),
                "path": path,
                "bytes": item.get("bytes") or 0,
                "lines": len(entries),
                "levels": levels,
                "kinds": kinds,
                "entries": [{k: e[k] for k in ("clock", "level", "msg", "key")} for e in entries],
                "_entries": entries,
            })
    return logs


PR_URL_RE = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/(\d+)")


def parse_pull_request(url):
    matched = PR_URL_RE.search(url or "")
    if not matched:
        return None
    return {"repo": matched.group(1), "number": int(matched.group(2)), "url": matched.group(0)}


def decisive_review(reviews):
    rows = [
        review for review in reviews or []
        if isinstance(review, dict) and review.get("state") in ("APPROVED", "CHANGES_REQUESTED")
    ]
    if not rows:
        return ""
    rows.sort(key=lambda review: review.get("submittedAt") or "")
    return rows[-1]["state"]


def fetch_pr(repo, number, url):
    fallback = {"url": url, "number": number, "state": "unknown", "title": "", "draft": False}
    command = ["gh", "pr", "view", str(number), "--repo", repo, "--json", "state,url,title,isDraft,reviews"]
    try:
        result = subprocess.run(command, capture_output=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return fallback
    if result.returncode != 0:
        return fallback
    try:
        data = json.loads(result.stdout.decode("utf-8"))
    except json.JSONDecodeError:
        return fallback
    state = {"MERGED": "merged", "OPEN": "open", "CLOSED": "closed"}.get(data.get("state"), "unknown")
    if state == "open" and decisive_review(data.get("reviews")) == "CHANGES_REQUESTED":
        state = "changes"
    return {
        "url": data.get("url") or url,
        "number": number,
        "state": state,
        "title": data.get("title") or "",
        "draft": bool(data.get("isDraft")),
    }


def enrich_pulls(tasks):
    cache = {}
    for task in tasks:
        parsed = parse_pull_request(task.get("pullRequest") or "")
        if not parsed:
            task["pr"] = None
            continue
        key = (parsed["repo"], parsed["number"])
        if key not in cache:
            cache[key] = fetch_pr(parsed["repo"], parsed["number"], parsed["url"])
        task["pr"] = cache[key]
