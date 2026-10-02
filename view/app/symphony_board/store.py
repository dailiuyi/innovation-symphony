# -*- coding: utf-8 -*-
"""SQLite persistence: attempts, status transitions, sessions, evidence, logs.

The runtime directories remain the source of truth; the database is an index
that survives restarts and lets the UI show a status-transition timeline.
"""
import json
import os
import sqlite3
import threading

from .common import now_cn, role_of

SCHEMA = """
CREATE TABLE IF NOT EXISTS attempts (
  id TEXT PRIMARY KEY,
  repo TEXT, runtime TEXT, issue TEXT, attempt TEXT, workspace TEXT,
  title TEXT, status TEXT, status_label TEXT, reason TEXT,
  pr_state TEXT, pr_number INTEGER, pr_url TEXT,
  updated_at TEXT, first_seen TEXT, last_seen TEXT,
  payload TEXT
);
CREATE TABLE IF NOT EXISTS transitions (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  attempt_id TEXT, from_status TEXT, to_status TEXT, to_label TEXT,
  pr_state TEXT, at TEXT
);
CREATE INDEX IF NOT EXISTS transitions_attempt ON transitions(attempt_id, seq);
CREATE TABLE IF NOT EXISTS sessions_db (
  id TEXT PRIMARY KEY,
  runtime TEXT, repo TEXT, role TEXT, issue TEXT, short TEXT, cwd TEXT,
  start_ts TEXT, end_ts TEXT, entries INTEGER, tokens_json TEXT, bytes INTEGER,
  title TEXT, last_seen TEXT
);
CREATE TABLE IF NOT EXISTS evidence_files (
  attempt_id TEXT, name TEXT,
  path TEXT, bytes INTEGER, exit_code INTEGER, summary TEXT,
  approved INTEGER, open_stage TEXT, tail INTEGER, body TEXT,
  PRIMARY KEY (attempt_id, name)
);
CREATE TABLE IF NOT EXISTS log_files (
  id TEXT PRIMARY KEY,
  runtime TEXT, file TEXT, path TEXT, bytes INTEGER, lines INTEGER,
  levels_json TEXT, kinds_json TEXT, last_seen TEXT
);
"""


class BoardStore:
    def __init__(self, db_path):
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        self.db_path = db_path
        # HTTP threads read history while the collect loop writes.
        self.conn = sqlite3.connect(db_path, check_same_thread=False)
        self.lock = threading.RLock()
        self.conn.executescript(SCHEMA)
        self.conn.commit()

    def close(self):
        self.conn.close()

    def _attempt_row(self, task_id):
        row = self.conn.execute(
            "SELECT status, pr_state FROM attempts WHERE id = ?", (task_id,)
        ).fetchone()
        return row if row else (None, None)

    def update_cycle(self, tasks, sessions, logs):
        """Record one derive cycle. Returns {task_id: [transition, ...]}."""
        with self.lock:
            return self._update_cycle(tasks, sessions, logs)

    def _update_cycle(self, tasks, sessions, logs):
        now = now_cn()
        transitions = {}
        cur = self.conn.cursor()
        for task in tasks:
            pr = task.get("pr") or {}
            cur.execute(
                "SELECT payload FROM attempts WHERE id = ?", (task["id"],)
            )
            row = cur.fetchone()
            payload = json.dumps(
                {k: v for k, v in task.items() if k not in ("receipt", "_matched", "transitions")},
                ensure_ascii=False,
            )
            if row and row[0] == payload:
                transitions[task["id"]] = self.transitions_for(task["id"])
                continue
            old_status, old_pr = self._attempt_row(task["id"])
            new_status = task.get("status")
            new_pr = pr.get("state") or ""
            if row is None:
                cur.execute(
                    "INSERT INTO attempts (id, repo, runtime, issue, attempt, workspace,"
                    " title, status, status_label, reason, pr_state, pr_number, pr_url,"
                    " updated_at, first_seen, last_seen, payload)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (task["id"], task.get("repo"), task.get("runtime"), task.get("issue"),
                     task.get("attempt"), task.get("workspace"), task.get("title"),
                     new_status, task.get("statusLabel"), task.get("reason"),
                     new_pr, pr.get("number"), pr.get("url") or "",
                     task.get("updated"), now, now, payload),
                )
                cur.execute(
                    "INSERT INTO transitions (attempt_id, from_status, to_status, to_label, pr_state, at)"
                    " VALUES (?,?,?,?,?,?)",
                    (task["id"], None, new_status, task.get("statusLabel"), new_pr, now),
                )
            else:
                cur.execute(
                    "UPDATE attempts SET status=?, status_label=?, reason=?, pr_state=?,"
                    " pr_number=?, pr_url=?, updated_at=?, last_seen=?, payload=? WHERE id=?",
                    (new_status, task.get("statusLabel"), task.get("reason"), new_pr,
                     pr.get("number"), pr.get("url") or "", task.get("updated"), now, payload,
                     task["id"]),
                )
                if old_status != new_status or old_pr != new_pr:
                    cur.execute(
                        "INSERT INTO transitions (attempt_id, from_status, to_status, to_label, pr_state, at)"
                        " VALUES (?,?,?,?,?,?)",
                        (task["id"], old_status, new_status, task.get("statusLabel"), new_pr, now),
                    )
            transitions[task["id"]] = self.transitions_for(task["id"])
        for session in sessions:
            meta = session.get("meta") or {}
            sid = meta.get("session_id") or os.path.basename(session.get("remote") or "")
            cur.execute(
                "INSERT INTO sessions_db (id, runtime, repo, role, issue, short, cwd,"
                " start_ts, end_ts, entries, tokens_json, bytes, title, last_seen)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
                " ON CONFLICT(id) DO UPDATE SET runtime=excluded.runtime, repo=excluded.repo,"
                " role=excluded.role, issue=excluded.issue, end_ts=excluded.end_ts,"
                " entries=excluded.entries, tokens_json=excluded.tokens_json,"
                " bytes=excluded.bytes, last_seen=excluded.last_seen",
                (sid, session.get("runtime"), session.get("repo"), role_of(session),
                 session.get("issue"), (sid or "")[:8], session.get("cwd"),
                 session.get("first_ts"), session.get("last_ts"), session.get("entries"),
                 json.dumps(session.get("tokens"), ensure_ascii=False),
                 session.get("bytes"), session.get("title"), now),
            )
        for log in logs:
            cur.execute(
                "INSERT INTO log_files (id, runtime, file, path, bytes, lines, levels_json, kinds_json, last_seen)"
                " VALUES (?,?,?,?,?,?,?,?,?)"
                " ON CONFLICT(id) DO UPDATE SET bytes=excluded.bytes, lines=excluded.lines,"
                " levels_json=excluded.levels_json, kinds_json=excluded.kinds_json,"
                " last_seen=excluded.last_seen",
                (log["id"], log["runtime"], log["file"], log["path"], log["bytes"],
                 log["lines"], json.dumps(log["levels"]), json.dumps(log["kinds"]), now),
            )
        for task in tasks:
            cur.execute("DELETE FROM evidence_files WHERE attempt_id = ?", (task["id"],))
            for item in task.get("evidence") or []:
                cur.execute(
                    "INSERT OR REPLACE INTO evidence_files (attempt_id, name, path, bytes,"
                    " exit_code, summary, approved, open_stage, tail, body)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (task["id"], item.get("name"), item.get("path"), item.get("bytes"),
                     item.get("exit"), item.get("summary"),
                     None if item.get("approved") is None else int(bool(item["approved"])),
                     item.get("open"), int(bool(item.get("tail"))), item.get("body")),
                )
        self.conn.commit()
        return transitions

    def transitions_for(self, task_id):
        with self.lock:
            rows = self.conn.execute(
                "SELECT from_status, to_status, to_label, pr_state, at"
                " FROM transitions WHERE attempt_id = ? ORDER BY seq", (task_id,)
            ).fetchall()
        return [
            {"from": r[0], "to": r[1], "toLabel": r[2], "prState": r[3], "at": r[4]}
            for r in rows
        ]

    def history_counts(self):
        with self.lock:
            row = self.conn.execute(
                "SELECT (SELECT COUNT(*) FROM attempts), (SELECT COUNT(*) FROM transitions),"
                " (SELECT COUNT(*) FROM sessions_db)"
            ).fetchone()
        return {"attempts": row[0], "transitions": row[1], "sessions": row[2]}
