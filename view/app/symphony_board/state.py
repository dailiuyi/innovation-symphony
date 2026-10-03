# -*- coding: utf-8 -*-
"""Shared published-board state between the collect loop and the HTTP API."""
import hashlib
import json
import threading


class BoardState:
    def __init__(self):
        self._lock = threading.Lock()
        self.payload = {}
        self.etag = ""
        self.rev = 0

    def publish(self, payload):
        blob = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        etag = '"' + hashlib.sha256(blob).hexdigest()[:20] + '"'
        with self._lock:
            if etag != self.etag:
                self.rev += 1
            self.etag = etag
            self.payload = payload
        return self.rev

    def snapshot(self):
        with self._lock:
            return dict(self.payload), self.etag, self.rev
