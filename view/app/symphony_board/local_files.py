"""Read regular runtime artifacts beneath a root without following symlinks."""
import os
import stat

FORBIDDEN_ROOT = "/root/.codex/sessions"


def normalized(path):
    path = os.path.abspath(os.path.normpath(os.fspath(path)))
    if path == FORBIDDEN_ROOT or path.startswith(FORBIDDEN_ROOT + os.sep):
        raise PermissionError("runtime path is outside the permitted collection scope")
    return path


def _directory(path):
    path = normalized(path)
    fd = os.open(os.path.sep, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.split(os.sep):
            if not part:
                continue
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def _relative(root, path):
    root, path = normalized(root), normalized(path)
    if os.path.commonpath((root, path)) != root:
        raise PermissionError("artifact escapes the configured runtime root")
    return root, os.path.relpath(path, root)


def open_artifact(root, path):
    root, relative = _relative(root, path)
    parts = relative.split(os.sep)
    fd = _directory(root)
    try:
        for part in parts[:-1]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        file_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        try:
            if not stat.S_ISREG(os.fstat(file_fd).st_mode):
                raise PermissionError("runtime artifact is not a regular file")
            return os.fdopen(file_fd, "rb")
        except BaseException:
            os.close(file_fd)
            raise
    finally:
        os.close(fd)


def list_directory(root, path):
    _relative(root, path)
    fd = _directory(path)
    try:
        return os.listdir(fd)
    finally:
        os.close(fd)


def walk_directory(root, path):
    """os.walk-shaped iterator; directory listing and descent use held dirfds."""
    _relative(root, path)
    def walk(fd, base):
        directories, files = [], []
        for name in sorted(os.listdir(fd)):
            info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if stat.S_ISLNK(info.st_mode):
                raise PermissionError("runtime scan refuses symbolic links")
            if stat.S_ISDIR(info.st_mode):
                directories.append(name)
            else:
                files.append(name)
        # Callers may prune directories in place (e.g. receipt evidence).
        yield base, directories, files
        for name in directories:
            child_path = normalized(os.path.join(base, name))
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            try:
                yield from walk(child, child_path)
            finally:
                os.close(child)
    fd = _directory(path)
    try:
        yield from walk(fd, normalized(path))
    finally:
        os.close(fd)


def glob_directories(pattern):
    """Expand directory globs without traversing symbolic-link components."""
    import fnmatch
    pattern = normalized(pattern)
    parts = [part for part in pattern.split(os.sep) if part]
    def expand(fd, base, index):
        if index == len(parts):
            yield base
            return
        part = parts[index]
        names = os.listdir(fd) if any(char in part for char in '*?[') else [part]
        for name in sorted(names):
            if name.startswith(".") and not part.startswith("."):
                continue
            if not fnmatch.fnmatchcase(name, part):
                continue
            try:
                info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if stat.S_ISLNK(info.st_mode):
                raise PermissionError("runtime glob refuses symbolic links")
            if not stat.S_ISDIR(info.st_mode):
                continue
            child_path = normalized(os.path.join(base, name))
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            try:
                yield from expand(child, child_path, index + 1)
            finally:
                os.close(child)
    fd = _directory(os.sep)
    try:
        return list(expand(fd, os.sep, 0))
    finally:
        os.close(fd)
