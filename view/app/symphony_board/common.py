# -*- coding: utf-8 -*-
"""Shared helpers for the Symphony board: time, identity, labels.

Ported from build/symphony-watch.py unchanged where possible. Keep this
module free of internal imports so every other module can use it.
"""
import datetime
import json
import re

CN = datetime.timezone(datetime.timedelta(hours=8))
UNKNOWN_REPO = "未知仓库"

STATUS_LABEL = {
    "queued": "排队中", "coding": "编码中", "blocked": "需关注",
    "review": "Review 中", "reviewing": "Review 中",
    "awaiting_review": "待人工审查", "pr_ready": "PR 就绪",
    "checking": "检查中", "awaiting_human": "等待人工",
    "recovering": "诊断中",
    "done": "已交付", "merged": "已合并",
}

REPO_ALIASES = {}


def to_local(ts):
    if not ts:
        return None
    try:
        dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=CN)
    return dt.astimezone(CN)


def clock(ts):
    dt = to_local(ts)
    return dt.strftime("%H:%M:%S") if dt else (ts[11:19] if ts and len(ts) > 19 else "—")


def sort_ts(ts):
    dt = to_local(ts)
    return dt.timestamp() if dt else 0


def dur(a, b):
    da, db = to_local(a), to_local(b)
    if not da or not db:
        return "—"
    s = int(abs((db - da).total_seconds()))
    return f"{s // 60}m {s % 60:02d}s"


def now_cn():
    return datetime.datetime.now(CN).isoformat(timespec="seconds")


def dur_from_stamps(stamps):
    start = datetime.datetime.fromtimestamp(min(stamps), CN).isoformat()
    end = datetime.datetime.fromtimestamp(max(stamps), CN).isoformat()
    return dur(start, end)


def cycle_pause(elapsed, interval):
    remaining = interval - elapsed
    return remaining if remaining > 0 else 0


def short_runtime(root):
    base = re.sub(r"[\\/]+$", "", os_basename(root))
    if base == "innovation-symphony-v0":
        return "v0"
    prefix = "innovation-symphony-v0-"
    if base.startswith(prefix):
        return base[len(prefix):]
    return base


def os_basename(path):
    return re.split(r"[\\/]", path or "")[-1]


def listed_runtimes(snapshot):
    rows = []
    for runtime in snapshot.get("runtimes", []):
        if not runtime.get("receipts"):
            continue
        rows.append({"name": short_runtime(runtime["root"]), "root": runtime["root"]})
    return rows


def repo_of(receipt):
    text = str((receipt or {}).get("repository") or "").strip()
    name = text or UNKNOWN_REPO
    return REPO_ALIASES.get(name, name)


def repo_slug(repo):
    slug = re.sub(r"[^A-Za-z0-9._-]+", "--", repo or "").strip("-")
    return slug or "unknown"


def task_repo(task):
    text = str((task or {}).get("repo") or "").strip()
    return text or UNKNOWN_REPO


def issue_from_cwd(cwd):
    found = re.findall(r"/(GH-\d+)(?:/|$)", cwd or "")
    return found[-1] if found else None


def issue_from_prompt(prompt):
    """沙箱化后 Codex 的 cwd 指向沙箱自身，issue 只能从任务指令里提取。

    编码/Review/诊断的指令开头都带 GH-x；预检指令不带。
    """
    text = prompt or ""
    matched = (re.search(r"issue:\s*(GH-\d+)", text)
               or re.search(r"Independently review\s+(GH-\d+)", text)
               or re.search(r"technical failures\s+for\s+(GH-\d+)", text))
    return matched.group(1) if matched else None


def session_role(cwd, prompt):
    path = (cwd or "").rstrip("/")
    text = (prompt or "").lstrip()
    if path.endswith("/preflight") or text.startswith("This is an authorized local execution preflight") or "PREFLIGHT_" in text[:400]:
        return "预检"
    if text.startswith("Independently review"):
        return "Review"
    if text.startswith("Implement only this repository's issue"):
        return "编码"
    if text.startswith("Diagnose repeated or unclassified technical failures"):
        return "诊断"
    return "未识别"


def role_of(session):
    return session_role(session.get("cwd"), session.get("prompt") or "")


def attempt_of(workspace, _receipt_path):
    # The attempt lives in the workspace. state/attempt-N is the controller's
    # current bucket and can hold a different issue started in that same round.
    m = re.search(r"/attempt-(\d+)/", workspace or "")
    if m:
        return f"attempt-{m.group(1)}"
    return ""


def short_cwd(cwd):
    parts = [p for p in (cwd or "").split("/") if p]
    if len(parts) >= 2:
        return "/".join(parts[-3:])
    return cwd or "—"


def clip(text, limit=160):
    compact = " ".join((text or "").split())
    return compact if len(compact) <= limit else compact[:limit] + "…"


def natural_name(name):
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", name or "")]


def token_cost(tokens, cost):
    """折算一次尝试的 token 成本；未配置单价时返回 None。

    口径：普通输入按 input 价（cache_write 并入普通输入），缓存命中按 cached 价，输出按 output 价。
    """
    if not isinstance(tokens, dict) or cost is None or not cost.enabled:
        return None
    inp = tokens.get("input_tokens") or 0
    cached = tokens.get("cached_input_tokens") or 0
    out = tokens.get("output_tokens") or 0
    plain = max(inp - cached, 0) + (tokens.get("cache_write_input_tokens") or 0)
    value = (plain / 1e6 * cost.input_per_m
             + cached / 1e6 * cost.cached_input_per_m
             + out / 1e6 * cost.output_per_m)
    return round(value, 4)


def embed(obj):
    return (json.dumps(obj, ensure_ascii=False)
            .replace("<", "\\u003c")
            .replace(">", "\\u003e")
            .replace("&", "\\u0026")
            .replace("\u2028", "\\u2028")
            .replace("\u2029", "\\u2029"))


def stage_of(status, cand, reason):
    if status in ("done", "merged"):
        return (5, None)
    if status in ("pr_ready", "awaiting_review"):
        return (3, 4)
    if status == "blocked":
        return (2, 2) if cand else (1, 1)
    if status in ("review", "reviewing"):
        return (3, 3)
    if status == "checking":
        return (2, 2)
    if status == "coding":
        return (1, 1)
    if status == "queued":
        return (0, 0)
    if "check" in (reason or ""):
        return (2, 2)
    return (0, 1)


def badge_class(status):
    if status == "blocked":
        return "b-blocked"
    if status in ("review", "reviewing", "awaiting_human"):
        return "b-review"
    if status in ("awaiting_review", "pr_ready", "done", "merged"):
        return "b-done"
    if status == "checking":
        return "b-check"
    if status == "recovering":
        return "b-diagnose"
    if status == "coding":
        return "b-running"
    return "b-queued"
