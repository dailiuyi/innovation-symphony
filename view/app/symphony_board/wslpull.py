# -*- coding: utf-8 -*-
"""Pull a raw runtime snapshot out of WSL.

Ported from build/symphony-watch.py. The remote script globs runtime
directories (by default /var/tmp/innovation-symphony-v0*) and emits one JSON
blob with receipts, inline evidence, controller logs, and rollout listings.
"""
import json
import os
import subprocess
import tempfile

from .common import short_runtime

DEFAULT_GLOB = "/var/tmp/innovation-symphony-v0*"

REMOTE_SCRIPT = r"""
import glob, hashlib, json, os, re

LOCAL = __LOCAL__
if LOCAL:
    from symphony_board.local_files import normalized, open_artifact, list_directory, walk_directory, glob_directories

def _read(path):
    if LOCAL:
        with open_artifact(root, path) as handle:
            return handle.read().decode("utf-8", "replace")
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()

def _info(path):
    if LOCAL:
        with open_artifact(root, path) as handle:
            return os.fstat(handle.fileno())
    return os.stat(path)

def _list(path):
    return list_directory(root, path) if LOCAL else os.listdir(path)

def _walk(path):
    return walk_directory(root, path) if LOCAL else os.walk(path)

def _closed_host_interruption(receipt, raw, evidence):
    # A matching closed operator proves this historical coding state stopped.
    # Missing ownership or old timestamps alone never prove an interruption.
    ident = receipt.get("operator_recheck")
    if (receipt.get("status") != "coding" or not isinstance(ident, str)
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", ident)
            or os.path.lexists(os.path.join(evidence, "operator-recheck.lock"))):
        return None
    directory = os.path.join(evidence, "operator-rechecks")
    head = os.path.join(directory, "head.json")
    completion = os.path.join(directory, ident, "completion.json")
    try:
        if _info(head).st_size > 16_384 or _info(completion).st_size > 16_384:
            return None
        record = json.loads(_read(head))
        if (not isinstance(record, dict) or record != json.loads(_read(completion))
                or record.get("id") != ident
                or record.get("final_receipt_sha256") != hashlib.sha256(raw.encode("utf-8")).hexdigest()
                or not re.fullmatch(r'\{:error, \{:host_shutdown_interrupted, "[0-9a-f]{64}"\}\}', record.get("result", ""))
                or os.path.lexists(os.path.join(evidence, "operator-recheck.lock"))):
            return None
        return {"kind": "closed_host_interruption", "operation": ident,
                "completedAt": record.get("completed_at"), "receiptStatus": "coding"}
    except (OSError, ValueError, TypeError):
        return None

UUID = r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"
SID_RE = re.compile(r"^" + UUID + r"(?:-(?:turn-?)?" + UUID + r")?$")
THREAD_RE = re.compile(r"^" + UUID + r"$")
MAX_MESSAGES_BYTES = 256_000
MAX_ATTEMPTS = 512

def _session_started(messages_path):
    # Return only the thread UUID from the bounded session_started record.
    if not os.path.isfile(messages_path):
        return ""
    remaining = MAX_MESSAGES_BYTES
    with (open_artifact(root, messages_path) if LOCAL else open(messages_path, "rb")) as binary:
        import io
        handle = io.TextIOWrapper(binary, encoding="utf-8", errors="replace")
        while remaining > 0:
            line = handle.readline(min(remaining, 16_384))
            if not line:
                break
            remaining -= len(line.encode("utf-8", "replace"))
            if "session_started" not in line:
                continue
            sid = re.search(r"\bsession_id\s*:\s*\"([^\"\n]{1,160})\"", line)
            thread = re.search(r"\bthread_id\s*:\s*\"([^\"\n]{1,80})\"", line)
            if sid and thread and SID_RE.fullmatch(sid.group(1)) and THREAD_RE.fullmatch(thread.group(1)):
                return thread.group(1)
            break
    return ""

def _classify_outcome(value):
    # Inspected Elixir outcomes can contain arbitrary output_text. Classify a
    # few controller atoms and discard the source string immediately.
    text = value if isinstance(value, str) else ""
    if text.startswith("{:ok,"):
        return "completed"
    if not text.startswith("{:error,"):
        return "unknown"
    token = text.split(", output_text:", 1)[0][:256].lower()
    if re.search(r":mvp_invalid_review\b", token):
        return "invalid_review"
    if "timeout" in token or "timed_out" in token:
        return "timeout"
    return "failed"

def _attempt_status(value, outcome):
    text = str(value or "").strip().lower()
    if text in ("started", "running", "in_progress"):
        return "running"
    if outcome in ("invalid_review", "timeout", "failed"):
        return "failed"
    if text in ("finished", "completed", "complete", "succeeded", "done") and outcome == "completed":
        return "completed"
    return "unknown"

def _receipt_round(receipt, directory):
    # Match the owning directory, never a session timestamp or token count.
    path = os.path.realpath(directory)
    matches = {rnd.get("round") for rnd in receipt.get("rounds") or []
               if isinstance(rnd, dict) and isinstance(rnd.get("evidence"), str)
               and os.path.realpath(rnd["evidence"]) == path
               and type(rnd.get("round")) is int and rnd["round"] > 0}
    return next(iter(matches)) if len(matches) == 1 else None


def _legacy_agent_runs(receipt, evidence_dir):
    # A saved pre-resume receipt binds the old single-round sandbox to its
    # original role. Only that exact artifact, still in the receipt, is used.
    originals = []
    if receipt.get("recovery") is None:
        originals.append(receipt)
    else:
        for event in (receipt.get("recovery") or {}).get("events") or []:
            if not isinstance(event, dict) or event.get("kind") != "operator_initial_coder_resume":
                continue
            ident = event.get("operation_id")
            if not isinstance(ident, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", ident):
                continue
            path = os.path.join(evidence_dir, "operator-rechecks", ident, "receipt-before.json")
            try:
                if _info(path).st_size <= 2_000_000:
                    old = json.loads(_read(path))
                    if (isinstance(old, dict) and old.get("repository") == receipt.get("repository")
                            and old.get("issue") == receipt.get("issue")
                            and old.get("workspace") == receipt.get("workspace")
                            and old.get("base_sha") == receipt.get("base_sha")
                            and old.get("recovery") is None):
                        originals.append(old)
            except (OSError, ValueError, TypeError):
                continue
    result = []
    for old in originals:
        rounds = old.get("rounds") or []
        if len(rounds) != 1 or not isinstance(rounds[0], dict):
            continue
        number = _receipt_round(receipt, rounds[0].get("evidence") or "")
        if number != rounds[0].get("round") or number is None:
            continue
        artifacts = [a for a in old.get("sandbox_artifacts") or []
                     if isinstance(a, dict) and a.get("role") == "coder"]
        if len(artifacts) != 1 or artifacts[0] not in (receipt.get("sandbox_artifacts") or []):
            continue
        path = artifacts[0].get("result_path")
        if not isinstance(path, str):
            continue
        sandbox = os.path.dirname(path)
        # Require the recorded native runtime sandbox layout and containment.
        run = os.path.dirname(sandbox)
        if (os.path.basename(path) != "result.json" or os.path.basename(sandbox) != "sandbox"
                or not os.path.basename(run).startswith("run-")
                or os.path.dirname(run) != os.path.join(root, "sandboxes")):
            continue
        outcome = "timeout" if (old.get("status") == "blocked" and old.get("candidate_sha") is None
                                and str(old.get("reason") or "") in (":wall_timeout", ":response_timeout")) else "unknown"
        result.append({"sessionsRoot": os.path.join(run, "codex-home", "sessions"),
                       "round": number, "role": "coder", "outcome": outcome})
    return result


def _agent_attempts(receipt, evidence_dir):
    # Join controller attempt events to their bounded session-start evidence.
    rows = {}
    recovery = receipt.get("recovery") or {}
    events = recovery.get("events") if isinstance(recovery, dict) else None
    if events is None:
        events = receipt.get("events") or []
    if isinstance(events, dict):
        events = events.get("events") or events.get("items") or []
    if not isinstance(events, list):
        return []
    # Bound distinct attempts, keeping both start and finish records. A
    # recovery attempt emits multiple events, so slicing events loses links.
    selected_keys = set()
    selected_events = []
    for event in reversed(events):
        if not isinstance(event, dict):
            continue
        role = str(event.get("role") or "").strip().lower()
        usage_key = str(event.get("usage_key") or "")
        usage = re.fullmatch(r"(coder|reviewer|diagnosis)_attempt_(\d+)", usage_key)
        if usage:
            role = usage.group(1)
            attempt = int(usage.group(2))
        else:
            attempt = event.get("attempt")
            if not isinstance(attempt, int) or isinstance(attempt, bool):
                attempt = None
        if role not in ("coder", "reviewer", "diagnosis") or attempt is None:
            continue
        key = usage_key or role + "_attempt_" + str(attempt)
        if key not in selected_keys:
            if len(selected_keys) >= MAX_ATTEMPTS:
                continue
            selected_keys.add(key)
        selected_events.append((event, role, attempt, key))
    for event, role, attempt, key in reversed(selected_events):
        row = rows.setdefault(key, {
            "session_id": "", "round": None, "attempt": attempt,
            "stageAttempt": None, "role": role, "status": "unknown",
            "outcome": "unknown", "roundSource": "unassigned",
        })
        row["role"] = role
        stage_attempt = event.get("stage_attempt")
        if isinstance(stage_attempt, int) and not isinstance(stage_attempt, bool):
            row["stageAttempt"] = stage_attempt
        round_no = event.get("round")
        if isinstance(round_no, int) and not isinstance(round_no, bool):
            row["round"] = round_no
            row["roundSource"] = "controller"
        evidence = event.get("evidence")
        if isinstance(evidence, str) and evidence:
            evidence_path = os.path.realpath(evidence)
            evidence_root = os.path.realpath(evidence_dir)
            try:
                inside_evidence = os.path.commonpath((evidence_root, evidence_path)) == evidence_root
            except ValueError:
                inside_evidence = False
            round_match = re.search(r"(?:^|/)round-(\d+)(?:/|$)", evidence_path.replace("\\", "/"))
            recorded_round = _receipt_round(receipt, os.path.dirname(evidence_path)) if inside_evidence else None
            if recorded_round is not None and row["round"] is None:
                row["round"] = recorded_round
                row["roundSource"] = "controller"
            if inside_evidence and round_match:
                row["round"] = int(round_match.group(1))
                row["roundSource"] = "evidence"
            if inside_evidence and str(event.get("status") or "").lower() == "started":
                sid = _session_started(os.path.join(evidence_path, "messages.log"))
                if sid:
                    row["session_id"] = sid
        outcome = _classify_outcome(event.get("outcome"))
        status = _attempt_status(event.get("status"), outcome)
        if outcome != "unknown":
            row["outcome"] = outcome
        if status != "unknown":
            row["status"] = status
        if status == "running" and outcome == "unknown":
            row["outcome"] = "running"
        # Successful controller outcomes can carry the session id inside an
        # inspected map. Extract only that field; never parse or return prose.
        outcome_text = event.get("outcome")
        if isinstance(outcome_text, str) and outcome_text.startswith("{:ok,"):
            header = outcome_text.split(", output_text:", 1)[0][:8192]
            sid = re.search(r"\bsession_id\s*:\s*\"([^\"\n]{1,160})\"", header)
            if sid and SID_RE.fullmatch(sid.group(1)):
                thread = re.match(UUID, sid.group(1))
                if thread:
                    row["session_id"] = thread.group(0)
    result = [row for row in rows.values() if row["session_id"]]
    result.sort(key=lambda item: (item["round"] is None, item["round"] or 0,
                                  item["attempt"], item["stageAttempt"] or 0,
                                  item["session_id"]))
    return result

roots = sorted({p for pattern in __GLOBS__ for p in (glob_directories(pattern) if LOCAL else glob.glob(pattern)) if os.path.isdir(p)})
if LOCAL:
    roots = [normalized(path) for path in roots]
    # Validate every root even if it contains no known artifact directories.
    for path in roots:
        list_directory(path, path)
out = {"runtimes": []}
for root in roots:
    rt = {"root": root, "receipts": [], "evidence": [], "logs": [], "sessions": []}
    state = os.path.join(root, "state")
    if os.path.isdir(state):
        for dirpath, dirnames, filenames in _walk(state):
            dirnames[:] = [d for d in dirnames if not d.endswith(".evidence")]
            for name in filenames:
                if not name.endswith(".json"):
                    continue
                path = os.path.join(dirpath, name)
                try:
                    receipt_raw = _read(path)
                    rec = json.loads(receipt_raw)
                except Exception:
                    if LOCAL:
                        raise
                    continue
                if not isinstance(rec, dict) or "issue" not in rec:
                    continue
                rec["_path"] = path
                ev_dir = path + ".evidence"
                rec.pop("_execution_health", None)
                interruption = _closed_host_interruption(rec, receipt_raw, ev_dir)
                if interruption:
                    rec["_execution_health"] = interruption
                rec["_agent_attempts"] = _agent_attempts(rec, ev_dir)
                rec["_legacy_agent_runs"] = _legacy_agent_runs(rec, ev_dir)
                rec.pop("events", None)
                rt["receipts"].append(rec)
                if not os.path.isdir(ev_dir):
                    continue
                def add_evidence(directory, prefix):
                    for ev in sorted(_list(directory)):
                        fp = os.path.join(directory, ev)
                        rel = ev if not prefix else prefix + "/" + ev
                        if os.path.isdir(fp) and ev.startswith("round-"):
                            add_evidence(fp, rel)
                            continue
                        if not os.path.isfile(fp):
                            continue
                        if not (
                            (ev.startswith("check-") and (ev.endswith(".log") or ev.endswith(".json")))
                            or ev == "review.json"
                        ):
                            continue
                        if _info(fp).st_size <= 2_000_000:
                            rt["evidence"].append({
                                "receipt": path,
                                "name": rel,
                                "path": fp,
                                "bytes": _info(fp).st_size,
                                "text": _read(fp),
                            })
                add_evidence(ev_dir, "")
    logdir = os.path.join(root, "logs", "log")
    if os.path.isdir(logdir):
        for name in sorted(_list(logdir)):
            if not name.startswith("symphony.log") or name.endswith((".siz", ".idx")):
                continue
            fp = os.path.join(logdir, name)
            if os.path.isfile(fp) and _info(fp).st_size <= 8_000_000:
                rt["logs"].append({
                    "path": fp,
                    "bytes": _info(fp).st_size,
                    "text": _read(fp),
                })
    sess_bases = [os.path.join(root, "codex-home", "sessions")]
    # 新版控制器把每次 run 的 codex-home 放进 sandboxes/run-*/，顶层目录可能已删
    for sb in sorted(glob_directories(os.path.join(root, "sandboxes", "*", "codex-home")) if LOCAL else glob.glob(os.path.join(root, "sandboxes", "*", "codex-home"))):
        sess_bases.append(os.path.join(sb, "sessions"))
    for sess in sess_bases:
        if os.path.isdir(sess):
            for dirpath, _, filenames in _walk(sess):
                for name in filenames:
                    if name.startswith("rollout-") and name.endswith(".jsonl"):
                        fp = os.path.join(dirpath, name)
                        info = _info(fp)
                        rt["sessions"].append({"path": fp, "bytes": info.st_size, "mtime_ns": info.st_mtime_ns})
    out["runtimes"].append(rt)
print(json.dumps(out, ensure_ascii=False))
"""


def wsl(cmd):
    r = subprocess.run(["wsl.exe", "-e", "bash", "-c", cmd], capture_output=True, timeout=30)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.decode("utf-8", "replace")[-1500:] or "WSL read failed")
    return r.stdout.decode("utf-8", "replace").replace("\x00", "")


def to_wsl_path(path):
    drive, rest = os.path.splitdrive(os.path.abspath(path))
    if not drive:
        raise RuntimeError("WSL transport requires a Windows host path")
    return "/mnt/" + drive[0].lower() + rest.replace("\\", "/")


def remote_script(globs, local=False):
    listed = json.dumps(list(globs or [DEFAULT_GLOB]))
    return REMOTE_SCRIPT.replace("__LOCAL__", repr(local)).replace("__GLOBS__", listed)


def pull_snapshot(globs=None):
    script = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", newline="\n",
        prefix="symphony-pull-runtime-", suffix=".py", delete=False,
    )
    try:
        # Close before wsl.exe reads the file (also required on Windows).
        with script:
            script.write(remote_script(globs))
        r = subprocess.run(["wsl.exe", "-e", "python3", to_wsl_path(script.name)], capture_output=True, timeout=30)
        raw = r.stdout.decode("utf-8", "replace").replace("\x00", "")
        if r.returncode != 0 or "{" not in raw:
            err = r.stderr.decode("utf-8", "replace")[-1500:]
            raise RuntimeError(err or "runtime snapshot failed")
        snapshot = json.loads(raw[raw.find("{"):])
        for runtime in snapshot.get("runtimes", []):
            runtime["name"] = short_runtime(runtime["root"])
        return snapshot
    finally:
        os.unlink(script.name)
