"""Report which same-uid processes expose /proc/<pid>/fd, the evidence the retention scan depends on."""
import errno
import json
import os
from pathlib import Path


def describe(pid, uid):
    root = Path("/proc") / str(pid)
    try:
        if root.stat().st_uid != uid:
            return None
        command = (root / "comm").read_text().strip()
    except OSError:
        return None
    try:
        fds = len(os.listdir(root / "fd"))
        outcome = f"ok:{fds}"
    except OSError as error:
        outcome = errno.errorcode.get(error.errno, str(error.errno))
    return dict(pid=pid, command=command, fd=outcome)


def snapshot():
    uid = os.getuid()
    status = Path("/proc/self/status").read_text().splitlines()
    processes = [item for name in os.listdir("/proc") if name.isdecimal()
                 if (item := describe(int(name), uid))]
    return dict(
        uid=uid, groups=os.getgroups(), pid_namespace=os.readlink("/proc/self/ns/pid"),
        capabilities=next(line.split()[1] for line in status if line.startswith("CapEff:")),
        proc_mount=[line for line in Path("/proc/mounts").read_text().splitlines() if " /proc " in line],
        ptrace_scope=Path("/proc/sys/kernel/yama/ptrace_scope").read_text().strip()
        if Path("/proc/sys/kernel/yama/ptrace_scope").exists() else None,
        processes=processes,
        unreadable=[item for item in processes if not item["fd"].startswith("ok:")])


if __name__ == "__main__":
    print(json.dumps(snapshot(), indent=1))
