# -*- coding: utf-8 -*-
"""Bounded, read-only views over locally cached Codex rollout files."""
import json
import os
import re

from .collector import BUILD_ROLLOUTS, is_injected_user_context

MAX_WINDOW_BYTES = 1024 * 1024
MAX_HEADER_BYTES = 256 * 1024
MAX_RECORD_BYTES = 512 * 1024
MAX_ENTRY_TEXT = 16 * 1024
MAX_LONG_TEXT = 64 * 1024
MAX_PAGE_SIZE = 100
SESSION_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
WORKSPACE_RE = re.compile(r"(?:^|/)workspaces/(GH-\d+|preflight)(?:/|$)")


def valid_session_id(value):
    return isinstance(value, str) and bool(SESSION_NAME_RE.fullmatch(value))


def _text_from_content(content):
    if isinstance(content, str):
        return content
    chunks = []
    for item in content or []:
        if isinstance(item, dict) and isinstance(item.get("text"), str):
            chunks.append(item["text"])
    return "\n".join(chunks)


def _clip(text, limit):
    text = text if isinstance(text, str) else ""
    if len(text) <= limit:
        return text, False
    return text[:limit] + "…", True


def _safe_workdir(cwd):
    """Expose only known workspace labels, never an absolute host path."""
    normalized = str(cwd or "").replace("\\", "/")
    if normalized == "/workspace":
        return "/workspace"
    if normalized.startswith("/workspace/"):
        parts = normalized[len("/workspace/"):].split("/")
        if parts and all(re.fullmatch(r"[A-Za-z0-9._-]{1,80}", part) and part not in (".", "..") for part in parts):
            return "/workspace/" + "/".join(parts[:4])
        return "/workspace"
    match = WORKSPACE_RE.search(normalized)
    return "workspaces/" + match.group(1) if match else None


def _inside_rollout_cache(path):
    if not isinstance(path, str):
        return False
    try:
        root = os.path.realpath(BUILD_ROLLOUTS)
        target = os.path.realpath(path)
        return os.path.commonpath((root, target)) == root and target.lower().endswith(".jsonl")
    except (OSError, ValueError):
        return False


def _read_window(path, end, max_bytes):
    """Read an aligned byte window ending before `end`, dropping a partial line."""
    size = os.path.getsize(path)
    end = size if end is None else max(0, min(int(end), size))
    start = max(0, end - max_bytes)
    with open(path, "rb") as handle:
        handle.seek(start)
        data = handle.read(end - start)
    boundary = start
    if start:
        newline = data.find(b"\n")
        if newline < 0:
            return [], start, end - start
        boundary = start + newline + 1
        data = data[newline + 1:]
    rows = []
    position = boundary
    for raw in data.splitlines(keepends=True):
        line_start = position
        position += len(raw)
        line = raw.rstrip(b"\r\n")
        if not line or len(line) > MAX_RECORD_BYTES:
            continue
        try:
            obj = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if isinstance(obj, dict):
            rows.append((line_start, obj))
    return rows, boundary, end - start


def _first_prompt_and_model(path, fallback_prompt=""):
    size = os.path.getsize(path)
    with open(path, "rb") as handle:
        data = handle.read(min(size, MAX_HEADER_BYTES))
    # The header window can end in the middle of a JSON record.
    if size > len(data):
        data = data[:data.rfind(b"\n") + 1]
    event_prompt = ""
    response_prompt = ""
    model = None
    model_source = None
    cwd = None
    cwd_source = None
    for line in data.splitlines():
        if len(line) > MAX_RECORD_BYTES:
            continue
        try:
            obj = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if not isinstance(obj, dict):
            continue
        kind, payload = obj.get("type"), obj.get("payload") or {}
        if kind == "session_meta":
            if payload.get("cwd"):
                cwd, cwd_source = payload["cwd"], "session_meta.cwd"
            if payload.get("model"):
                model, model_source = payload["model"], "session_meta.model"
        elif kind == "turn_context":
            if payload.get("cwd"):
                cwd, cwd_source = payload["cwd"], "turn_context.cwd"
            if payload.get("model"):
                model, model_source = payload["model"], "turn_context.model"
        elif kind == "response_item" and payload.get("type") == "message" and payload.get("role") == "user" and not response_prompt:
            text = _text_from_content(payload.get("content")).strip()
            if text and not is_injected_user_context(text):
                response_prompt = text
        elif kind == "event_msg" and payload.get("type") == "item_completed" and not event_prompt:
            item = payload.get("item") or {}
            if item.get("type") == "UserMessage":
                event_prompt = _text_from_content(item.get("content")).strip()
    prompt = event_prompt or response_prompt
    found_prompt = bool(prompt)
    return prompt or fallback_prompt or "", model, cwd, cwd_source, model_source, found_prompt


def _assistant_text(obj):
    kind, payload = obj.get("type"), obj.get("payload") or {}
    if kind == "response_item" and payload.get("type") == "message" and payload.get("role") == "assistant":
        if payload.get("phase") not in (None, "commentary", "final_answer"):
            return None, None
        text = _text_from_content(payload.get("content"))
        return (text, obj.get("timestamp")) if text.strip() else (None, None)
    if kind == "event_msg" and payload.get("type") == "item_completed":
        item = payload.get("item") or {}
        if item.get("type") == "AgentMessage":
            text = _text_from_content(item.get("content"))
            return (text, obj.get("timestamp")) if text.strip() else (None, None)
    return None, None


def _latest_assistant(path):
    size = os.path.getsize(path)
    rows, _boundary, _scanned = _read_window(path, size, MAX_WINDOW_BYTES)
    latest = None
    for _offset, obj in rows:
        text, timestamp = _assistant_text(obj)
        if text is not None:
            latest = {"timestamp": timestamp, "text": text}
    if latest:
        latest["text"], latest["truncated"] = _clip(latest["text"], MAX_LONG_TEXT)
    return latest


def _json_text(value):
    if isinstance(value, str):
        return value
    if value is None:
        return ""
    try:
        return json.dumps(value, ensure_ascii=False)
    except (TypeError, ValueError):
        return str(value)


def _entry(offset, obj):
    record_type = obj.get("type")
    payload = obj.get("payload") or {}
    timestamp = obj.get("timestamp")
    result = {
        "index": offset,
        "timestamp": timestamp,
        "type": "event",
        "role": "event",
        "name": "",
        "text": "",
        "source": record_type or "unknown",
        "truncated": False,
    }
    if record_type == "response_item":
        subtype = payload.get("type") or "event"
        if subtype == "message":
            result.update(type="message", role=payload.get("role") or "unknown",
                          name=payload.get("channel") or payload.get("phase") or "",
                          text=_text_from_content(payload.get("content")))
        elif subtype == "reasoning":
            summary = payload.get("summary")
            result.update(type="reasoning", role="reasoning", name="reasoning",
                          text=_json_text(summary) if summary else "(no visible summary)")
        elif subtype in ("custom_tool_call", "custom_tool_call_output", "function_call", "function_call_output"):
            call_input = subtype in ("custom_tool_call", "function_call")
            detail = payload.get("input") if subtype == "custom_tool_call" else payload.get("arguments")
            if not call_input:
                detail = payload.get("output")
            result.update(type="tool", role="tool", name=str(payload.get("name") or subtype),
                          text=_json_text(detail))
        else:
            result.update(type="event", role=subtype, name=subtype,
                          text=_json_text(payload.get("summary") or payload.get("query") or ""))
    elif record_type == "event_msg":
        subtype = payload.get("type") or "event"
        if subtype == "item_completed":
            item = payload.get("item") or {}
            item_type = item.get("type") or "event"
            if item_type in ("UserMessage", "AgentMessage"):
                result.update(type="message", role="user" if item_type == "UserMessage" else "assistant",
                              name=item_type, text=_text_from_content(item.get("content")))
            elif item_type == "CommandExecution":
                detail = []
                for label, value in (("command", item.get("command")), ("stdout", item.get("stdout")), ("stderr", item.get("stderr"))):
                    if isinstance(value, str) and value:
                        detail.append(label + ":\n" + value)
                result.update(type="tool", role="tool", name=item_type, text="\n\n".join(detail))
            elif item_type == "Reasoning":
                result.update(type="reasoning", role="reasoning", name=item_type,
                              text=str(item.get("summary_text") or "(no visible summary)"))
            else:
                result.update(type="event", role=item_type, name=item_type,
                              text=_json_text(item.get("summary") or item.get("formatted_output") or ""))
        elif subtype == "token_count":
            usage = (payload.get("info") or {}).get("total_token_usage")
            if usage:
                result.update(type="meta", role="meta", name="token_count", text=_json_text(usage))
            else:
                return None
        else:
            return None
    elif record_type == "turn_context":
        keys = ("model", "approval_policy", "collaboration_mode", "effort")
        selected = {key: payload[key] for key in keys if payload.get(key) is not None}
        result.update(type="meta", role="meta", name="turn_context", text=_json_text(selected))
    elif record_type == "session_meta":
        keys = ("session_id", "id", "cli_version", "originator", "model_provider")
        selected = {key: payload[key] for key in keys if payload.get(key) is not None}
        result.update(type="meta", role="meta", name="session_meta", text=_json_text(selected))
    else:
        return None
    return result


def _matches(entry, entry_type, search):
    if entry_type != "all" and entry.get("type") != entry_type:
        return False
    if search:
        text = " ".join(str(entry.get(key) or "") for key in ("text", "name", "role", "source"))
        if search.casefold() not in text.casefold():
            return False
    return True


def read_session_context(session_id, public, sources, *, limit=50, before=None, entry_type="all", search=""):
    """Build a response from one indexed rollout; no remote reads or commands."""
    if len(sources) != 1:
        return {"status": "ambiguous" if sources else "unavailable",
                "reason": "duplicate_session_id" if sources else "rollout_not_mapped"}
    path = sources[0].get("path")
    if not _inside_rollout_cache(path) or not os.path.isfile(path):
        return {"status": "unavailable", "reason": "local_rollout_missing"}
    try:
        size = os.path.getsize(path)
        prompt, header_model, cwd, cwd_source, header_model_source, prompt_found_in_rollout = _first_prompt_and_model(
            path, fallback_prompt=public.get("prompt") or "")
        prompt, was_clipped = _clip(prompt, MAX_LONG_TEXT)
        prompt_truncated = was_clipped or (bool(prompt) and not prompt_found_in_rollout)
        public_model = public.get("model")
        if isinstance(public_model, str) and public_model.strip():
            model = public_model
            model_evidence = public.get("modelEvidence")
        else:
            model = header_model
            model_evidence = header_model_source
        latest = _latest_assistant(path)
        end = size if before is None else before
        rows, boundary, scanned = _read_window(path, end, MAX_WINDOW_BYTES)
        matched = []
        for offset, obj in rows:
            entry = _entry(offset, obj)
            if entry is not None and _matches(entry, entry_type, search):
                matched.append(entry)
        page_size = max(1, min(MAX_PAGE_SIZE, int(limit)))
        selected = matched[-page_size:]
        if len(matched) > len(selected):
            next_before = selected[0]["index"]
        else:
            next_before = boundary
        workdir = _safe_workdir(cwd or public.get("cwd") or "")
        counts = public.get("counts")
        source_name = sources[0].get("name") or os.path.basename(path)
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,180}", source_name):
            source_name = os.path.basename(path)
        visible_entries = []
        for entry in selected:
            visible = dict(entry)
            full_text = entry.get("text") or ""
            visible["text"], visible["truncated"] = _clip(full_text, MAX_ENTRY_TEXT)
            needle = search.casefold()
            visible["matchBeyondPreview"] = bool(
                needle
                and needle in full_text.casefold()
                and needle not in visible["text"].casefold()
            )
            visible_entries.append(visible)
        result = {
            "status": "ok",
            "session": {
                "id": session_id,
                "role": public.get("role") or "未识别",
                "issue": public.get("issue") or None,
                "source": {"kind": "codex_rollout", "runtime": public.get("runtime") or None, "name": source_name},
                "issuedInstruction": prompt,
                "issuedInstructionTruncated": prompt_truncated,
                "model": model or None,
                "modelEvidence": model_evidence,
                "workdir": workdir,
                "workdirEvidence": cwd_source if workdir else None,
                "counts": counts if isinstance(counts, dict) else None,
                "entries": public.get("entries") if isinstance(public.get("entries"), int) else None,
                "tokens": public.get("tokens") if isinstance(public.get("tokens"), dict) else None,
                "statsEvidence": "rollout parser" if counts is not None or public.get("tokens") is not None else None,
                "firstTs": public.get("firstTs") or None,
                "lastTs": public.get("lastTs") or None,
            },
            "latestAssistant": latest,
            "entries": visible_entries,
            "page": {
                "limit": page_size,
                "nextBefore": next_before if next_before > 0 else None,
                "hasOlder": next_before > 0,
                "scannedBytes": scanned,
                "truncated": size > scanned or boundary > 0 or len(matched) > len(selected),
                "filter": {"type": entry_type, "q": search},
            },
        }
        return result
    except (OSError, ValueError) as exc:
        return {"status": "unavailable", "reason": type(exc).__name__}
