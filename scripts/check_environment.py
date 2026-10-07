"""Keep controller secrets out of checks and bound inherited Erlang VMs."""

import os
from pathlib import Path
import shlex


def _cgroup_limits(root: Path = Path('/sys/fs/cgroup'),
                   membership: Path = Path('/proc/self/cgroup')) -> tuple[int | None, int | None]:
    """Read the current cgroup and ancestors; a private namespace may hide /sys."""
    try:
        group = next(line[3:] for line in membership.read_text().splitlines() if line.startswith('0::'))
    except (OSError, StopIteration):
        return None, None
    current = root / group.lstrip('/')
    if '..' in current.relative_to(root).parts:
        return None, None
    cpus, pids = [], []
    for directory in (current, *current.parents):
        if not directory.is_relative_to(root):
            break
        for name, limits in (('cpu.max', cpus), ('pids.max', pids)):
            try:
                fields = (directory / name).read_text().split()
            except OSError:
                continue
            if fields[0] == 'max':
                continue
            if name == 'cpu.max':
                limits.append(max(1, int(fields[0]) // int(fields[1])))
            else:
                limits.append(int(fields[0]))
    return min(cpus) if cpus else None, min(pids) if pids else None


def check_resource_budget() -> dict[str, int | str]:
    """Sandbox limits come from the fixed runner, not from candidate policy."""
    values = [os.environ.get(name) for name in ('SYMPHONY_CHECK_CPUS', 'SYMPHONY_CHECK_PIDS')]
    if any(value is not None for value in values):
        if any(value is None or not value.isdecimal() for value in values):
            raise ValueError('Erlang resource configuration rejects invalid trusted CPU and PID limits')
        cpus, pids = map(int, values)
        if not (1 <= cpus <= 64 and 1 <= pids <= 65536):
            raise ValueError('Erlang resource configuration rejects trusted CPU or PID limit outside supported range')
        source = 'sandbox'
    else:
        cpu_limit, pid_limit = _cgroup_limits()
        affinity = len(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else (os.cpu_count() or 1)
        cpus, pids = min(4, affinity, cpu_limit or 4), min(256, pid_limit or 256)
        source = 'host_cgroup_or_conservative_default'
    # PID quotas count OS threads. Leave capacity for control threads, the test
    # runner, and nested escripts; native peak/event evidence still proves capacity.
    schedulers = min(cpus, max(1, pids // 32))
    return dict(cpus=cpus, pids=pids, schedulers=schedulers,
                dirty_cpu_schedulers=1, dirty_io_schedulers=1, source=source)


def isolated_environment() -> dict[str, str]:
    environment = {
        name: value
        for name, value in os.environ.items()
        if name not in {"GITHUB_REPO", "GITHUB_TOKEN", "GH_TOKEN", "SSH_AUTH_SOCK"}
        and not name.startswith(("OPENAI_", "AZURE_OPENAI_", "ANTHROPIC_", "AWS_"))
    }
    budget = check_resource_budget()
    # These control arguments can stop VM flag parsing or load a second source
    # after the inherited flags were inspected. Stop instead of dropping them.
    for name in ('ERL_FLAGS', 'ERL_ZFLAGS'):
        try:
            arguments = shlex.split(environment.get(name, ''))
        except ValueError as error:
            raise ValueError(f'Erlang resource configuration rejects invalid quoted flags in {name}') from error
        if any(argument in {'-extra', '-args_file'} for argument in arguments):
            raise ValueError(f'Erlang resource configuration rejects -extra and -args_file in {name}')
    flags = (f'+S {budget["schedulers"]}:{budget["schedulers"]} +SDcpu 1:1 +SDio 1 '
             '+SP 100:100 +SDPcpu 100:100')
    # ERL_FLAGS also reaches escript subprocesses. ERL_ZFLAGS is parsed after
    # command-line and other environment arguments, so inherited overrides cannot
    # silently undo the budget. Reset percentage multipliers too: +SP/+SDPcpu
    # combine with the absolute counts regardless of their argument order.
    # Preserve unrelated settings (e.g. test CA paths).
    for name in ('ERL_FLAGS', 'ERL_ZFLAGS'):
        environment[name] = (environment.get(name, '') + ' ' + flags).strip()
    return environment
