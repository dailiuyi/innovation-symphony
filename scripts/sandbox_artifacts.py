"""Controller-owned, durable source export. Call only after all writers stop."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile

EXCLUDED = (".git", ".codex", ".symphony-import", "elixir/deps",
            "elixir/_build", "elixir/cover", "elixir/bin")


def sync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def save_json(path: Path, value: dict) -> None:
    fd, temporary = tempfile.mkstemp(prefix=".publish-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def source_manifest(source: Path) -> dict:
    result = {}
    entries = 0
    for directory, dirs, files in os.walk(source, followlinks=False):
        relative = Path(directory).relative_to(source)
        dirs[:] = [name for name in dirs if not any(str(relative / name) == prefix for prefix in (*EXCLUDED, ".check-evidence"))]
        for name in files:
            entries += 1
            if entries > 100000:
                raise ValueError("source entry limit exceeded")
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file():
                continue
            digest = hashlib.sha256()
            with path.open("rb") as handle:
                while chunk := handle.read(1024 * 1024):
                    digest.update(chunk)
            info = path.stat()
            result[str(relative / name)] = dict(sha256=digest.hexdigest(), size=info.st_size, mode=info.st_mode & 0o777)
    return result


def export_source(source: Path, target: Path, limit: int, *, identity=None, original=None) -> dict:
    """Rejected exports retain their staged regular files and full diagnostics."""
    pending = target.with_name(".export-pending")
    report = dict(schema=1, identity=identity or {}, source=str(source), target=str(target),
                  snapshot_complete=False, export_complete=False, files={}, rejected=[], deleted=[], bytes=0)
    try:
        if source.is_symlink() or not source.is_dir() or target.exists() or target.is_symlink():
            raise ValueError("invalid source or existing export")
        pending.mkdir(mode=0o700)

        entries = 0
        def walk(directory, relative=""):
            nonlocal entries
            for item in sorted(os.scandir(directory), key=lambda entry: entry.name):
                name = relative + "/" + item.name if relative else item.name
                if any(name == prefix or name.startswith(prefix + "/") for prefix in EXCLUDED):
                    continue
                entries += 1
                if entries > 100000:
                    raise ValueError("source entry limit exceeded")
                info = item.stat(follow_symlinks=False)
                destination = pending / name
                if stat.S_ISDIR(info.st_mode):
                    destination.mkdir(mode=0o700)
                    walk(Path(item.path), name)
                    sync_directory(destination)
                elif stat.S_ISREG(info.st_mode):
                    if report["bytes"] + info.st_size > limit:
                        report["rejected"].append(dict(path=name, reason="size_limit", size=info.st_size))
                        continue
                    fd = os.open(item.path, os.O_RDONLY | os.O_NOFOLLOW)
                    digest = hashlib.sha256()
                    with os.fdopen(fd, "rb") as incoming, destination.open("xb") as outgoing:
                        actual = 0
                        while chunk := incoming.read(1024 * 1024):
                            actual += len(chunk)
                            if report["bytes"] + actual > limit:
                                raise ValueError("source changed or exceeded size limit")
                            digest.update(chunk)
                            outgoing.write(chunk)
                        after = os.fstat(incoming.fileno())
                        if (info.st_ino, info.st_dev, info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (after.st_ino, after.st_dev, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                            raise ValueError("source changed while exporting: " + name)
                        os.fchmod(outgoing.fileno(), info.st_mode & 0o777)
                        outgoing.flush()
                        os.fsync(outgoing.fileno())
                    report["bytes"] += actual
                    report["files"][name] = dict(sha256=digest.hexdigest(), size=actual, mode=info.st_mode & 0o777)
                else:
                    report["rejected"].append(dict(path=name, reason="symlink" if stat.S_ISLNK(info.st_mode) else "special_file"))

        walk(source)
        sync_directory(pending)
        if not report["rejected"]:
            os.rename(pending, target)
            sync_directory(target.parent)
            report.update(snapshot_complete=True, export_complete=True)
            report["deleted"] = sorted(set(original or {}) - set(report["files"]))
    except (OSError, ValueError) as error:
        report["rejected"].append(dict(path="", reason=type(error).__name__, detail=str(error)))
    save_json(target.parent / "export-report.json", report)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    parser.add_argument("limit_mb", type=int)
    args = parser.parse_args()
    raise SystemExit(0 if export_source(args.source, args.target, args.limit_mb * 1048576)["export_complete"] else 1)
