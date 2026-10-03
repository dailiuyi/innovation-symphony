"""Platform selection and read-only snapshot/rollout transport.

Unmarked snapshots and copy_session's two-argument public entrypoint retain
legacy WSL semantics. Every snapshot collected here records its actual source.
"""
import hashlib
import json
import os
import shlex
import subprocess
import sys
import tempfile
import time

from . import wslpull
from .common import short_runtime
from .local_files import normalized, open_artifact

TIMEOUT_SECONDS = 30


def resolve_transport(transport="auto", platform=None):
    platform = sys.platform if platform is None else platform
    if transport not in ("auto", "local", "wsl"):
        raise ValueError("board.transport must be auto, local, or wsl")
    mode = ("wsl" if platform == "win32" else "local") if transport == "auto" else transport
    if mode == "wsl" and platform != "win32":
        raise ValueError("wsl transport requires Windows; use local inside WSL")
    if mode == "local" and not platform.startswith("linux"):
        raise ValueError("local transport requires Linux (including inside WSL)")
    return mode


def pull_snapshot(globs=None, transport="auto"):
    mode = resolve_transport(transport)
    if mode == "wsl":
        snapshot = wslpull.pull_snapshot(globs)
    else:
        args = [sys.executable, "-I", "-B", os.path.join(os.path.dirname(__file__), "local_scan.py"),
                json.dumps(list(globs or [wslpull.DEFAULT_GLOB]), ensure_ascii=False)]
        result = subprocess.run(args, capture_output=True, timeout=TIMEOUT_SECONDS)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.decode("utf-8", "replace")[-1500:] or "local runtime snapshot failed")
        snapshot = json.loads(result.stdout.decode("utf-8"))
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get("runtimes"), list):
        raise ValueError("invalid runtime snapshot shape")
    for runtime in snapshot["runtimes"]:
        runtime["name"] = short_runtime(runtime["root"])
    snapshot["_transport"] = mode
    return snapshot


def _atomic_write(path, writer):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".rollout-", suffix=".tmp", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "wb") as handle:
            writer(handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def copy_session(remote, size, cache, transport="wsl", mtime_ns=None, root=None):
    size = int(size)
    if transport == "local":
        if root is None or mtime_ns is None:
            raise ValueError("local rollout requires its discovered root and mtime_ns")
        remote, root = normalized(remote), normalized(root)
        relative = os.path.relpath(remote, root).split(os.sep)
        top_level = relative[:2] == ["codex-home", "sessions"]
        sandbox = (len(relative) >= 5 and relative[0] == "sandboxes"
                   and relative[2:4] == ["codex-home", "sessions"])
        if not (top_level or sandbox) or not os.path.basename(remote).startswith("rollout-") or not remote.endswith(".jsonl"):
            raise PermissionError("rollout was not discovered beneath a runtime session directory")
        key = hashlib.sha256(("local\0" + remote).encode("utf-8")).hexdigest()[:16]
        # Local versions are immutable: an unsuccessful cycle cannot change the
        # transcript still referenced by the last published snapshot.
        local = os.path.join(cache, f"local-{key}-{size}-{int(mtime_ns)}-{os.path.basename(remote)}")
        with open_artifact(root, remote) as source:
            initial = os.fstat(source.fileno())
            expected = (size, int(mtime_ns))
            if (initial.st_size, initial.st_mtime_ns) != expected:
                raise RuntimeError("rollout changed after discovery; retry next cycle")
            if os.path.isfile(local) and os.path.getsize(local) == size:
                return local
            deadline = time.monotonic() + TIMEOUT_SECONDS
            def writer(handle):
                copied = 0
                while True:
                    if time.monotonic() > deadline:
                        raise TimeoutError("local rollout copy timed out")
                    chunk = source.read(min(1024 * 1024, size - copied + 1))
                    if not chunk:
                        break
                    handle.write(chunk)
                    copied += len(chunk)
                    if copied > size:
                        raise RuntimeError("rollout grew during copy")
                final = os.fstat(source.fileno())
                if copied != size or (final.st_size, final.st_mtime_ns) != expected:
                    raise RuntimeError("rollout changed during copy")
            _atomic_write(local, writer)
        return local
    if transport != "wsl":
        raise ValueError("invalid rollout transport")
    # Preserve the old WSL cache identity exactly.
    key = hashlib.sha256(remote.encode("utf-8", "replace")).hexdigest()[:16]
    local = os.path.join(cache, f"{key}-{os.path.basename(remote)}")
    metadata = local + ".stat.json"
    if os.path.isfile(local) and os.path.getsize(local) == size:
        if mtime_ns is None:
            return local
        try:
            with open(metadata, encoding="utf-8") as handle:
                if json.load(handle) == [size, int(mtime_ns)]:
                    return local
        except (OSError, ValueError):
            pass
    data = wslpull.wsl("cat " + shlex.quote(remote))
    if not data.strip():
        raise RuntimeError("WSL rollout read returned no data")
    _atomic_write(local, lambda handle: handle.write(data.encode("utf-8")))
    if mtime_ns is not None:
        _atomic_write(metadata, lambda handle: handle.write(json.dumps([size, int(mtime_ns)]).encode("utf-8")))
    return local
