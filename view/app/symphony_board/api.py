# -*- coding: utf-8 -*-
"""HTTP layer: JSON API + static web shell + generated context pages.

Routes:
  GET /                       app/web/index.html (the Linear-style shell)
  GET /assets/<file>          app/web/assets files
  GET /prototypes/<name>      generated pages (context-*.html, legacy workbench)
  GET /prototypes/workbench.html   302 -> / for old links
  GET /api/bootstrap          board config summary
  GET /api/snapshot           full board payload, ETag/304 on unchanged
  GET /api/sessions/<id>/context bounded rollout context
"""
import json
import os
import re
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

from .collector import context_sources
from .context import read_session_context, valid_session_id

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WEB_DIR = os.path.join(ROOT, "app", "web")
PROTOTYPE_DIR = os.path.join(ROOT, "prototypes")

MIME = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".woff2": "font/woff2",
}
NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")


class BoardHTTPServer(ThreadingHTTPServer):
    """Refuse a second process binding the same board port."""

    allow_reuse_address = False

    def server_bind(self):
        if os.name == "nt":
            exclusive = getattr(socket, "SO_EXCLUSIVEADDRUSE", None)
            if exclusive is not None:
                self.socket.setsockopt(socket.SOL_SOCKET, exclusive, 1)
        super().server_bind()


class RawRef:
    """Mutable holder for the latest raw WSL snapshot (pending-repo lookup)."""

    def __init__(self):
        self.raw = {}
        self.health = {"status": "unknown"}


def make_handler(board_state, config, raw_ref, history_store):
    def read_json_file(path):
        try:
            with open(path, "rb") as handle:
                return handle.read()
        except (FileNotFoundError, PermissionError, IsADirectoryError):
            return None

    class Handler(BaseHTTPRequestHandler):
        server_version = "SymphonyBoard/1.0"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass

        def _send(self, code, body, content_type, extra=None):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            for key, value in (extra or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(body)

        def _json(self, obj, extra=None, status=200):
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            headers = {"Cache-Control": "no-store"}
            headers.update(extra or {})
            self._send(status, body, "application/json; charset=utf-8", headers)

        def _file(self, path, cache="no-store"):
            body = read_json_file(path)
            if body is None:
                self._send(404, b"not found", "text/plain; charset=utf-8")
                return
            ext = os.path.splitext(path)[1]
            self._send(200, body, MIME.get(ext, "application/octet-stream"), {"Cache-Control": cache})

        def do_GET(self):
            split = urlsplit(self.path)
            path, query = split.path, parse_qs(split.query, keep_blank_values=True)
            if path in ("/", "/index.html", "/board"):
                self._file(os.path.join(WEB_DIR, "index.html"))
                return
            if path.startswith("/assets/"):
                rel = path[len("/assets/"):].replace("/", os.sep)
                if not rel or rel.startswith(os.sep) or ".." in rel.split(os.sep):
                    self._send(404, b"not found", "text/plain; charset=utf-8")
                    return
                self._file(os.path.join(WEB_DIR, "assets", rel), cache="no-store")
                return
            if path == "/prototypes/workbench.html":
                self.send_response(302)
                self.send_header("Location", "/")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if path.startswith("/prototypes/"):
                name = path[len("/prototypes/"):]
                if not NAME_RE.match(name) or not name.endswith(".html"):
                    self._send(404, b"not found", "text/plain; charset=utf-8")
                    return
                self._file(os.path.join(PROTOTYPE_DIR, name))
                return
            if path == "/api/bootstrap":
                payload, _etag, rev = board_state.snapshot()
                history = {}
                if history_store is not None:
                    try:
                        history = history_store.history_counts()
                    except Exception:
                        history = {}
                self._json({
                    "title": config.title,
                    "interval": config.interval,
                    "port": config.port,
                    "rev": rev,
                    "generated": payload.get("generated") or "",
                    "configPath": config.path,
                    "configExists": config.exists,
                    "stallHours": config.stall_hours,
                    "cost": {
                        "currency": config.cost.currency,
                        "enabled": config.cost.enabled,
                        "inputPerM": config.cost.input_per_m,
                        "cachedInputPerM": config.cost.cached_input_per_m,
                        "outputPerM": config.cost.output_per_m,
                    },
                    "repos": [
                        {"name": item.name, "alias": item.alias, "glob": item.glob, "enabled": item.enabled}
                        for item in config.repos
                    ],
                    "pending": config.pending(raw_ref.raw),
                    "history": history,
                    "collection": dict(raw_ref.health) if isinstance(getattr(raw_ref, "health", None), dict) else {"status": "unknown"},
                })
                return
            if path == "/api/snapshot":
                payload, etag, rev = board_state.snapshot()
                if not payload:
                    self._json({"empty": True, "rev": rev})
                    return
                if self.headers.get("If-None-Match") == etag:
                    self.send_response(304)
                    self.send_header("ETag", etag)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
                self._send(200, body, "application/json; charset=utf-8",
                           {"ETag": etag, "Cache-Control": "no-store"})
                return
            context_prefix = "/api/sessions/"
            context_suffix = "/context"
            if path.startswith(context_prefix) and path.endswith(context_suffix):
                encoded_id = path[len(context_prefix):-len(context_suffix)]
                session_id = unquote(encoded_id)
                if "/" in encoded_id or not valid_session_id(session_id):
                    self._json({"status": "missing", "reason": "invalid_session_id"}, status=400)
                    return
                payload, _etag, _rev = board_state.snapshot()
                matches = [row for row in payload.get("sessions", []) if row.get("id") == session_id]
                if not matches:
                    self._json({"status": "missing", "reason": "session_not_found", "sessionId": session_id}, status=404)
                    return
                if len(matches) != 1:
                    self._json({"status": "ambiguous", "reason": "duplicate_published_session_id", "sessionId": session_id}, status=409)
                    return
                values = {key: items[-1] for key, items in query.items() if items}
                try:
                    limit = int(values.get("limit", "50"))
                    if limit < 1 or limit > 100:
                        raise ValueError("limit must be from 1 to 100")
                    raw_before = values.get("before")
                    if raw_before is not None and (len(raw_before) > 20 or not raw_before.isdigit()):
                        raise ValueError("before must be a non-negative byte cursor")
                    before = int(raw_before) if raw_before is not None else None
                except ValueError as exc:
                    self._json({"status": "invalid_request", "reason": str(exc)}, status=400)
                    return
                entry_type = values.get("type", "all")
                if entry_type not in {"all", "message", "tool", "reasoning", "event", "meta"}:
                    entry_type = "all"
                search = values.get("q", "")
                if len(search) > 200:
                    self._json({"status": "invalid_request", "reason": "q must be at most 200 characters"}, status=400)
                    return
                result = read_session_context(
                    session_id, matches[0], context_sources(session_id),
                    limit=limit, before=before, entry_type=entry_type, search=search,
                )
                result_status = result.get("status")
                code = 503 if result_status == "unavailable" else 409 if result_status == "ambiguous" else 200
                self._json(result, status=code)
                return
            self._send(404, b"not found", "text/plain; charset=utf-8")

    return Handler


def serve(board_state, config, raw_ref, history_store=None, port=None):
    handler = make_handler(board_state, config, raw_ref, history_store)
    return BoardHTTPServer(("0.0.0.0", port or config.port), handler)
