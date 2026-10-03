# -*- coding: utf-8 -*-
"""Entry point: collect cycle -> SQLite -> published snapshot -> HTTP UI.

Usage:
  python app/run.py once [--out FILE] [--config PATH]
  python app/run.py [interval_seconds] [--port N] [--config PATH]
"""
import datetime
import io
import json
import os
import sys
import threading
import time

if __name__ == "__main__":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", line_buffering=True)

APP_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(APP_DIR)
if APP_DIR not in sys.path:
    sys.path.insert(0, APP_DIR)

from symphony_board import common
from symphony_board.api import serve
from symphony_board.api import RawRef
from symphony_board.collector import load_sessions, public_session, publish_context_sources
from symphony_board.common import cycle_pause, listed_runtimes, token_cost
from symphony_board.config import load_config
from symphony_board.derive import build_logs, build_stories, build_tasks, enrich_pulls
from symphony_board.selfcheck import self_check
from symphony_board.state import BoardState
from symphony_board.store import BoardStore
from symphony_board.runtime_source import pull_snapshot, resolve_transport

DATA_DIR = os.path.join(ROOT, "data")


def run_cycle(config, store, state, raw_ref):
    try:
        return _run_cycle(config, store, state, raw_ref)
    except Exception as exc:
        raw_ref.health = {**raw_ref.health, "status": "error",
                          "source": resolve_transport(config.transport),
                          "lastError": f"{type(exc).__name__}: {exc}"}
        raise


def _run_cycle(config, store, state, raw_ref):
    snapshot = pull_snapshot(config.globs(), transport=config.transport)
    sessions = load_sessions(snapshot, publish=False)
    logs = build_logs(snapshot)
    by_runtime = {}
    for log in logs:
        by_runtime.setdefault(log["runtime"], []).append({"entries": log["_entries"]})
    tasks = build_tasks(snapshot, sessions, by_runtime)
    enrich_pulls(tasks)
    disabled = {entry.name for entry in config.repos if not entry.enabled}
    if disabled:
        tasks = [task for task in tasks if task.get("repoRaw") not in disabled]
    transitions = store.update_cycle(tasks, sessions, logs)
    for task in tasks:
        rows = transitions.get(task["id"], [])
        task["transitions"] = rows
        task["statusSince"] = rows[-1]["at"] if rows else None
        task["cost"] = token_cost(task.get("tokens"), config.cost)
    public_tasks = []
    for task in tasks:
        item = dict(task)
        item.pop("receipt", None)
        item.pop("_matched", None)
        public_tasks.append(item)
    public_logs = []
    for log in logs:
        item = dict(log)
        item.pop("_entries", None)
        public_logs.append(item)
    stories = build_stories(public_tasks)
    session_rows = [public_session(s) for s in sessions]
    gen = datetime.datetime.now().strftime("%m-%d %H:%M:%S")
    payload = {
        "generated": f"生成 {gen}",
        "interval": config.interval,
        "tasks": public_tasks,
        "stories": stories,
        "sessions": session_rows,
        "logs": public_logs,
        "runtimes": listed_runtimes(snapshot),
    }
    state.publish(payload)
    publish_context_sources(sessions)
    raw_ref.raw = snapshot
    raw_ref.health = {"status": "ok" if snapshot.get("runtimes") else "empty", "source": resolve_transport(config.transport), "lastSuccess": datetime.datetime.now(datetime.timezone.utc).isoformat(), "lastError": ""}
    changed = state.rev
    return changed, public_tasks, session_rows, public_logs, stories, sessions


def viewer_pages_for(sessions, interval):
    from symphony_board.pagegen import viewer_pages
    return viewer_pages(sessions, interval)


def write_context_pages(config, sessions):
    os.makedirs(os.path.join(ROOT, "prototypes"), exist_ok=True)
    from symphony_board.pagegen import write_if_changed
    changed = False
    for name, page in viewer_pages_for(sessions, config.interval):
        changed |= write_if_changed(os.path.join(ROOT, "prototypes", name), page)
    return changed


def report(tasks, sessions, logs, stories):
    print(f"tasks={len(tasks)} sessions={len(sessions)} logs={len(logs)}")
    for story in stories:
        print(f"  story {story['id']} attempts={story['attempts']} {story['outcome']} | {story['outcomeDetail']}")


def main():
    self_check()
    args = sys.argv[1:]
    once = "once" in args
    flags = {"--out", "--config", "--port"}
    out_path = config_path = port = None
    interval_args = []
    skip = False
    for arg in args:
        if skip:
            skip = False
            continue
        if arg in flags:
            skip = True
            continue
        if arg.isdigit():
            interval_args.append(arg)
    if "--out" in args:
        out_path = args[args.index("--out") + 1]
    if "--config" in args:
        config_path = args[args.index("--config") + 1]
    if "--port" in args:
        port = int(args[args.index("--port") + 1])
    config = load_config(config_path)
    common.REPO_ALIASES.update({
        entry.name: entry.alias for entry in config.repos if entry.alias
    })
    if interval_args:
        config.interval = int(interval_args[0])
    if port:
        config.port = port

    os.makedirs(DATA_DIR, exist_ok=True)
    store = BoardStore(os.path.join(DATA_DIR, "board.db"))
    state = BoardState()
    raw_ref = RawRef()
    raw_ref.health = {"status": "waiting", "source": resolve_transport(config.transport), "lastSuccess": None, "lastError": ""}

    if once:
        _changed, tasks, sessions, logs, stories, _raw = run_cycle(config, store, state, raw_ref)
        report(tasks, sessions, logs, stories)
        if out_path:
            payload, _etag, _rev = state.snapshot()
            with open(out_path, "w", encoding="utf-8", newline="\n") as handle:
                json.dump(payload, handle, ensure_ascii=False)
            print(f"payload written to {out_path}")
        store.close()
        return

    httpd = serve(state, config, raw_ref, store, port=port)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    shown = port or config.port
    print(f"serving http://127.0.0.1:{shown}/")
    print(f"lan http://0.0.0.0:{shown}/")
    while True:
        started = time.monotonic()
        try:
            _changed, tasks, sessions, logs, stories, raw_sessions = run_cycle(config, store, state, raw_ref)
            # 上下文页需要原始解析对象（含 local 缓存路径），不能用 public 字典
            write_context_pages(config, raw_sessions)
            summary = ", ".join(f"{task['id']}:{task['status']}" for task in tasks) or "no tasks"
            print(f"[{datetime.datetime.now():%H:%M:%S}] tasks={len(tasks)} sessions={len(sessions)} | {summary}")
        except Exception as exc:
            raw_ref.health = {**raw_ref.health, "status": "error", "lastError": f"{type(exc).__name__}: {exc}"}
            print(f"[{datetime.datetime.now():%H:%M:%S}] cycle error: {type(exc).__name__}: {exc}")
        pause = cycle_pause(time.monotonic() - started, config.interval)
        if pause:
            time.sleep(pause)


if __name__ == "__main__":
    main()
