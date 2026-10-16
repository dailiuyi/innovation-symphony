# -*- coding: utf-8 -*-
"""Collect and parse raw runtime artifacts: rollouts, controller logs.

Ported from build/symphony-watch.py.
"""
import json
import os
import re
import threading

from .common import clock, clip, dur, issue_from_cwd, issue_from_prompt, role_of, short_cwd, short_runtime, sort_ts
from .wslpull import wsl

BUILD_ROLLOUTS = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "build", "rollouts")

_CONTEXT_SOURCES = {}
_CONTEXT_SOURCES_LOCK = threading.Lock()

DIAGNOSIS_ACTION = {
    "repair_code": "接着改代码并重跑检查",
    "retry_stage": "按原阶段重试",
    "stop": "诊断结论是停止",
}

LOG_RE = re.compile(r"^(\S+) (debug|info|warning|error): (.*)$")


def display_title(prompt):
    text = prompt or ""
    matched = re.search(r"issue:\s*(?:GH|GL)-\d+\s+(.*)", text)
    if matched:
        return matched.group(1).splitlines()[0].strip()
    matched = re.search(r"Independently review\s+(?:GH|GL)-\d+:\s*(.*)", text)
    if matched:
        return matched.group(1).splitlines()[0].strip()
    return text.splitlines()[0].strip()[:180] if text else ""


def is_injected_user_context(text):
    """Recognize explicit Codex context preambles, not task prompt templates."""
    stripped = (text or "").lstrip()
    return bool(
        re.match(r"^#+\s*AGENTS\.md instructions for(?:\s|$)", stripped, re.IGNORECASE)
        or re.match(r"^<environment_context(?:\s|>)", stripped, re.IGNORECASE)
    )


def _file_lines(path):
    with open(path, encoding="utf-8") as handle:
        yield from handle


def parse_rollout(path):
    counts = {"reasoning": 0, "tool": 0, "assistant": 0, "user": 0, "developer": 0}
    tokens, agent_msgs = None, []
    event_prompt, response_prompt = "", ""
    model = None
    model_source = None
    latest_output = ""
    latest_output_ts = None
    first_ts = last_ts = None
    meta = {}
    for line in _file_lines(path):
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        t, ts = o.get("type"), (o.get("timestamp") or "")
        if ts:
            first_ts = first_ts or ts
            last_ts = ts
        p = o.get("payload") or {}
        if t == "session_meta":
            meta = {"session_id": p.get("session_id") or p.get("id"), "cwd": p.get("cwd"),
                    "cli": p.get("cli_version"), "originator": p.get("originator"),
                    "model_provider": p.get("model_provider"),
                    "ts": p.get("timestamp") or ts}
            if p.get("model"):
                model, model_source = p["model"], "session_meta.model"
        elif t == "turn_context":
            if p.get("model"):
                model, model_source = p["model"], "turn_context.model"
        elif t == "event_msg":
            st = p.get("type")
            if st == "token_count":
                # Codex 会写 "info":null（键存在值为 null，get 默认值不生效）
                tokens = (p.get("info") or {}).get("total_token_usage")
            elif st == "item_completed":
                it = p.get("item") or {}
                if it.get("type") == "AgentMessage":
                    txt = _content_text(it.get("content"))
                    if txt.strip():
                        agent_msgs.append((ts, " ".join(txt.split())))
                        latest_output, latest_output_ts = txt, ts or latest_output_ts
                elif it.get("type") == "UserMessage" and not event_prompt:
                    text = _content_text(it.get("content")).strip()
                    if text and not event_prompt:
                        event_prompt = text
        elif t == "response_item":
            st = p.get("type")
            if st == "reasoning":
                counts["reasoning"] += 1
            elif st in ("custom_tool_call", "function_call"):
                counts["tool"] += 1
            elif st == "message":
                counts[{"assistant": "assistant", "user": "user"}.get(p.get("role"), "developer")] += 1
                text = _content_text(p.get("content"))
                if p.get("role") == "user" and not response_prompt and text.strip() and not is_injected_user_context(text):
                    response_prompt = text.strip()
                elif (p.get("role") == "assistant" and text.strip()
                      and p.get("phase") in (None, "commentary", "final_answer")):
                    # Ignore hidden/internal phases. AgentMessage event records,
                    # when present, provide the final user-visible text.
                    latest_output, latest_output_ts = text, ts
    prompt = event_prompt or response_prompt
    cwd = meta.get("cwd") or ""
    return {
        "meta": meta, "cwd": cwd,
        "model": model,
        "model_source": model_source,
        "issue": issue_from_cwd(cwd) or issue_from_prompt(prompt),
        "prompt": prompt, "title": display_title(prompt),
        "last_output": latest_output, "last_output_ts": latest_output_ts,
        "tokens": tokens, "counts": counts, "entries": sum(counts.values()),
        "agent_msgs": agent_msgs, "first_ts": first_ts, "last_ts": last_ts,
    }


def _content_text(content):
    """Extract visible text while preserving line breaks from Codex content blocks."""
    if isinstance(content, str):
        return content
    parts = []
    for item in content or []:
        if isinstance(item, dict) and isinstance(item.get("text"), str):
            parts.append(item["text"])
    return "\n".join(parts)


def debug_kind(msg):
    m = re.search(r'Codex notification: "([^"]+)"', msg)
    if m:
        return m.group(1)
    if "bubblewrap" in msg or msg.startswith("Codex response stream"):
        return "codex stream"
    if msg.startswith("Ignoring message"):
        return "ignored message"
    return "other"


def is_key_line(level, msg):
    return level != "debug" or "ERROR" in msg or "bubblewrap" in msg


def parse_log(text):
    entries, levels, kinds = [], {}, {}
    for line in text.splitlines():
        m = LOG_RE.match(line)
        if not m:
            if line.strip():
                entries.append({"clock": "", "level": "other", "msg": line, "key": True})
            continue
        ts, level, msg = m.group(1), m.group(2), m.group(3)
        levels[level] = levels.get(level, 0) + 1
        if level == "debug":
            kind = debug_kind(msg)
            kinds[kind] = kinds.get(kind, 0) + 1
        entries.append({
            "clock": clock(ts), "level": level, "msg": msg,
            "key": is_key_line(level, msg), "sort": sort_ts(ts), "ts": ts,
        })
    kind_list = [{"name": k, "count": n} for k, n in sorted(kinds.items(), key=lambda kv: (-kv[1], kv[0]))]
    return entries, levels, kind_list


def copy_session(remote, size, transport="wsl", mtime_ns=None, root=None):
    from .runtime_source import copy_session as copy
    return copy(remote, size, BUILD_ROLLOUTS, transport, mtime_ns, root)


def load_sessions(snapshot, publish=True):
    transport = snapshot.get("_transport", "wsl")
    if transport not in ("local", "wsl"):
        raise ValueError("invalid snapshot transport")
    seen, sessions = set(), []
    for runtime in snapshot.get("runtimes", []):
        for item in runtime.get("sessions", []):
            remote = item.get("path")
            if not remote or remote in seen:
                continue
            seen.add(remote)
            local = copy_session(remote, item.get("bytes") or 0, transport, item.get("mtime_ns"), runtime.get("root"))
            if not local or not os.path.exists(local):
                continue
            if transport == "wsl" and not publish:
                from .runtime_source import pin_context_session
                local = pin_context_session(local, remote, BUILD_ROLLOUTS)
            # Legacy WSL parsing keeps its tolerant behavior; local failures
            # abort publication so the last successful context stays readable.
            try:
                parsed = parse_rollout(local)
                if transport == "local" and not parsed.get("meta", {}).get("session_id"):
                    raise ValueError("local rollout has no valid session metadata")
            except Exception as exc:
                if transport == "local":
                    raise
                print(f"skip rollout {os.path.basename(remote)}: {type(exc).__name__}: {exc}")
                continue
            parsed["remote"] = remote
            parsed["bytes"] = int(item.get("bytes") or os.path.getsize(local))
            parsed["local"] = local
            sessions.append(parsed)
    sessions.sort(key=lambda item: item.get("first_ts") or "")
    if publish:
        publish_context_sources(sessions)
    return sessions


def publish_context_sources(sessions):
    sources = {}
    for session in sessions:
        meta = session.get("meta") or {}
        sid = meta.get("session_id") or os.path.basename(session.get("remote") or "")
        if not sid:
            continue
        sources.setdefault(sid, []).append({
            "path": session.get("local"),
            "name": os.path.basename(session.get("remote") or ""),
        })
    with _CONTEXT_SOURCES_LOCK:
        _CONTEXT_SOURCES.clear()
        _CONTEXT_SOURCES.update({key: tuple(value) for key, value in sources.items()})


def context_sources(session_id):
    """Return local rollout mappings for a published session id.

    This registry is process-local and never returned by the HTTP API. Multiple
    distinct sources for the same id are retained so callers can report an
    explicit ambiguity instead of showing the wrong transcript.
    """
    with _CONTEXT_SOURCES_LOCK:
        return tuple(_CONTEXT_SOURCES.get(session_id, ()))


def runtime_index(snapshot):
    pairs = [(rt["root"], short_runtime(rt["root"])) for rt in snapshot.get("runtimes", [])]
    pairs.sort(key=lambda item: len(item[0]), reverse=True)
    return pairs


def runtime_for_cwd(cwd, pairs):
    cwd = cwd or ""
    for root, name in pairs:
        if cwd.startswith(root.rstrip("/") + "/"):
            return name
    return "—"


def parse_diagnosis_payload(text):
    blob = (text or "").strip()
    if not blob:
        return None
    candidates = [blob]
    start, end = blob.find("{"), blob.rfind("}")
    if 0 <= start < end:
        candidates.append(blob[start:end + 1])
    for candidate in candidates:
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict) and (parsed.get("action") or parsed.get("summary")):
            return parsed
    return None


def diagnosis_note(session):
    if role_of(session) != "诊断":
        return ""
    parsed = None
    for item in reversed(session.get("agent_msgs") or []):
        text = item[1] if isinstance(item, (list, tuple)) and len(item) > 1 else item
        parsed = parse_diagnosis_payload(text if isinstance(text, str) else "")
        if parsed:
            break
    if not parsed:
        return ""
    action = parsed.get("action") if isinstance(parsed.get("action"), str) else ""
    summary = parsed.get("summary") if isinstance(parsed.get("summary"), str) else ""
    return " ".join(part for part in (DIAGNOSIS_ACTION.get(action, ""), clip(summary, 120)) if part)


def prompt_head(prompt):
    """任务指令的第一行非空内容——symphony 下发给 agent 的指令模板开头。

    编码/Review/诊断的指令第一行就带角色与 Issue（如
    “Implement only this repository's issue: GH-1 …”），研发更新
    symphony 的 prompt 模板时首先看这里。
    """
    for line in (prompt or "").splitlines():
        line = " ".join(line.split())
        if line:
            return line[:160]
    return ""


def review_verdict(session):
    """Review 会话自己给出的结论。

    控制器正常情况下会把结论落成 round-N/review.json；但它并不总是落盘
    （人工中断、或该轮没走到写证据那一步）。这时唯一的结论只在 Review 会话
    的消息里，UI 需要它才不会把「已被否决的轮次」误判成「没被打回」。
    返回 approved 与 summary；来源是会话输出，不是证据文件。
    """
    if role_of(session) != "Review":
        return None
    for item in reversed(session.get("agent_msgs") or []):
        text = item[1] if isinstance(item, (list, tuple)) and len(item) > 1 else item
        if not isinstance(text, str):
            continue
        blob = text.strip()
        candidates = [blob]
        start, end = blob.find("{"), blob.rfind("}")
        if 0 <= start < end:
            candidates.append(blob[start:end + 1])
        for candidate in candidates:
            try:
                parsed = json.loads(candidate)
            except json.JSONDecodeError:
                continue
            if isinstance(parsed, dict) and isinstance(parsed.get("approved"), bool):
                summary = parsed.get("summary") if isinstance(parsed.get("summary"), str) else ""
                return {"approved": parsed["approved"], "summary": clip(summary, 200)}
    return None


def public_session(session):
    meta = session.get("meta") or {}
    sid = meta.get("session_id") or os.path.basename(session.get("remote") or "")
    short = sid[:8] if meta.get("session_id") else sid[:12]
    role = role_of(session)
    prompt = session.get("prompt") or ""
    last_output = session.get("last_output") or ""
    output_limit = 260
    return {
        "id": sid,
        "short": short,
        "role": role,
        "issue": session.get("issue") or "",
        "runtime": session.get("runtime") or "—",
        "repo": session.get("repo") or "",
        "cwd": session.get("cwd") or "",
        "cwdShort": short_cwd(session.get("cwd")),
        "start": clock(session.get("first_ts")),
        "end": clock(session.get("last_ts")),
        "firstTs": session.get("first_ts") or None,
        "lastTs": session.get("last_ts") or None,
        "duration": dur(session.get("first_ts"), session.get("last_ts")),
        "entries": session.get("entries") or 0,
        "counts": session.get("counts") or {"reasoning": 0, "tool": 0},
        "tokens": session.get("tokens"),
        "model": session.get("model") or None,
        "modelEvidence": session.get("model_source") or None,
        "bytes": session.get("bytes") or 0,
        # 上下文页文件名用完整 session id：UUIDv7 前 8 位在同一分钟内会重复，
        # 用 short 命名会让两个 agent 的页面互相覆盖，点进去看到别人的对话。
        "href": f"context-{sid}.html",
        "title": session.get("title") or "",
        "promptHead": prompt_head(prompt),
        "prompt": clip(prompt, 220),
        "lastOutput": last_output[:output_limit] + ("…" if len(last_output) > output_limit else ""),
        "lastOutputTruncated": len(last_output) > output_limit,
        "lastOutputTs": session.get("last_output_ts") or None,
        "verdict": review_verdict(session),
        "note": diagnosis_note(session),
    }
