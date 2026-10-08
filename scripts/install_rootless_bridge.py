#!/usr/bin/env python3
"""Install the separate experimental bridge. Does not change the controller workflow."""
import argparse
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import sys
import sysconfig

INSTALL = Path('/opt/innovation-symphony-rootless-bridge')


def copy_check_payload(source, destination):
    """Copy the executable gate and its non-Python formatter dependency together."""
    for file in source.iterdir():
        if file.is_file() and file.suffix in ('.py', '.json', '.sh', '.exs'):
            shutil.copy2(file, destination / file.name)
            (destination / file.name).chmod(0o644)
    shutil.copytree(source / 'view_validation', destination / 'view_validation',
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))


def protect_installation(root):
    """Make copied trusted code independent of worktree modes and caller umask."""
    for directory, dirs, files in os.walk(root):
        Path(directory).chmod(0o755)
        for name in files:
            target = Path(directory) / name
            target.chmod(target.stat().st_mode & ~0o022)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--controller', required=True)
    parser.add_argument('--worker', default='symphony-worker')
    parser.add_argument('--image', required=True)
    for name in ('workspaces', 'state', 'sandboxes', 'toolchain', 'codex', 'dependencies'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    controller = pwd.getpwnam(args.controller)
    if controller.pw_uid == 0 or args.worker == args.controller or not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', args.worker):
        raise ValueError('dedicated non-root controller and worker required')
    if not re.fullmatch(r'[A-Za-z0-9./:_-]+@sha256:[0-9a-f]{64}', args.image):
        raise ValueError('provide a reviewed, digest-pinned image with bash, git, python3 and apt')
    source = Path(__file__).resolve().parent
    if INSTALL.exists():
        raise ValueError('installation already exists; preserve it and use a versioned reviewed update')
    paths = {name: Path(getattr(args, name)) for name in ('workspaces', 'state', 'sandboxes', 'toolchain', 'codex', 'dependencies')}
    for name, path in paths.items():
        if not path.is_absolute() or path.resolve() != path or any(c in str(path) for c in ':,\n\r'):
            raise ValueError('noncanonical path: ' + name)
        if name in ('toolchain', 'codex', 'dependencies') and not path.exists():
            raise ValueError('missing trusted input: ' + name)
    policy = dict(uid=controller.pw_uid, gid=controller.pw_gid,
                  workspaces=str(paths['workspaces']), state=str(paths['state']), sandboxes=str(paths['sandboxes']),
                  fixed={'--toolchain': str(paths['toolchain']), '--codex': str(paths['codex']),
                         '--trusted-root': str(INSTALL / 'trusted'), '--dependencies': str(paths['dependencies']),
                         '--cpus': '4', '--memory-mb': '4096', '--pids': '512', '--disk-mb': '20480'},
                  rootless={'--backend': 'rootless', '--image': args.image, '--worker': args.worker})
    print(json.dumps(policy, indent=2))
    if not args.apply:
        print('Preview only. --apply requires host administrator authentication. IPv4 forwarding must already be enabled.')
        return
    if os.geteuid() != 0:
        raise PermissionError('administrator authentication required')
    if Path('/proc/sys/net/ipv4/ip_forward').read_text().strip() != '1':
        raise ValueError('host IPv4 forwarding is not prepared; no sysctl is changed automatically')
    subprocess.run(['apt-get', 'install', '-y', 'podman', 'crun', 'uidmap', 'nftables', 'iptables', 'iproute2', 'e2fsprogs'], check=True)
    try:
        worker = pwd.getpwnam(args.worker)
    except KeyError:
        subprocess.run(['useradd', '--create-home', '--user-group', '--shell', '/usr/sbin/nologin', args.worker], check=True)
        worker = pwd.getpwnam(args.worker)
    if worker.pw_uid == 0 or worker.pw_uid == controller.pw_uid:
        raise ValueError('worker identity conflicts')
    for filename in ('/etc/subuid', '/etc/subgid'):
        if not any(line.startswith(args.worker + ':') for line in Path(filename).read_text().splitlines()):
            raise ValueError('worker requires registered subordinate IDs: ' + filename)
    INSTALL.mkdir(mode=0o755)
    scripts = INSTALL / 'trusted/scripts'
    scripts.mkdir(parents=True)
    copy_check_payload(source, scripts)
    shutil.copy2(source / 'linux_bridge.py', INSTALL / 'bridge.py')
    shutil.copy2(source / 'sandbox_artifacts.py', INSTALL / 'sandbox_artifacts.py')
    shutil.copy2(source / 'rootless_startup_guard.py', INSTALL / 'startup_guard.py')
    shutil.copy2(source / 'execution_sandbox.sh', scripts / 'execution_sandbox.root.sh')
    gate = INSTALL / 'trusted/gate-python'
    gate.mkdir()
    python = Path(sys.executable).resolve()
    binaries = [python, *Path(sysconfig.get_path('stdlib')).rglob('*.so')]
    libraries = ''.join(subprocess.run(['ldd', str(binary)], text=True, capture_output=True, check=False).stdout for binary in binaries)
    targets = [('/opt/gate-python', python), (sysconfig.get_path('stdlib'), Path(sysconfig.get_path('stdlib')))]
    for line in libraries.splitlines():
        match = re.search(r'(?:=>\s+)?(/[^ ]+)', line)
        if match:
            target = match.group(1)
            targets.append((target, Path(target).resolve()))
    targets = list(dict(targets).items())
    bindings = []
    for index, (target, origin) in enumerate(targets):
        destination = gate / str(index)
        if origin.is_dir():
            shutil.copytree(origin, destination, ignore=shutil.ignore_patterns('site-packages', '__pycache__'), symlinks=False)
        else:
            shutil.copy2(origin, destination)
        bindings.append(dict(source=str(destination), relative=str(index), target=target))
    (gate / 'empty-preload').write_text('')
    bindings.append(dict(source=str(gate / 'empty-preload'), relative='empty-preload', target='/etc/ld.so.preload'))
    (gate / 'bindings.json').write_text(json.dumps(bindings, indent=2) + '\n')
    wrapper = '#!/bin/bash\nset -eu\nexec /usr/bin/python3 -I ' + str(INSTALL / 'bridge.py') + ' --client "$@"\n'
    (scripts / 'execution_sandbox.sh').write_text(wrapper)
    (scripts / 'execution_sandbox.sh').chmod(0o755)
    (INSTALL / 'policy.json').write_text(json.dumps(policy, indent=2) + '\n')
    (INSTALL / 'policy.json').chmod(0o600)
    for name in ('workspaces', 'state', 'sandboxes'):
        paths[name].mkdir(parents=True, exist_ok=True)
        os.chown(paths[name], controller.pw_uid, controller.pw_gid)
    unit = '[Unit]\nDescription=Innovation Symphony experimental rootless execution bridge\nAfter=network.target\n\n[Service]\nType=simple\nExecStartPre=/usr/bin/python3 -I ' + str(INSTALL / 'startup_guard.py') + '\nExecStart=/usr/bin/python3 -I ' + str(INSTALL / 'bridge.py') + ' --server\nRestart=no\nKillMode=process\nTimeoutStopSec=180\n\n[Install]\nWantedBy=multi-user.target\n'
    protect_installation(INSTALL)
    service = Path('/etc/systemd/system/innovation-symphony-rootless-bridge.service')
    service.write_text(unit)
    service.chmod(0o644)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    print('Installed, not started. Review policy and start the separate bridge explicitly. Controller intake is unchanged.')


if __name__ == '__main__':
    main()
