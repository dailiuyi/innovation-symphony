#!/usr/bin/env python3
"""Local QEMU lifecycle. No installation, downloads or implicit mutation."""
import argparse
from contextlib import contextmanager
import errno
import fcntl
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
import uuid

GIB = 1024 ** 3
DEFAULT_ROOT = Path('/data/symphony-vm')
GUEST_ROOT = '/var/tmp/innovation-symphony-linux-runtime'
GUEST_CONFIG = '/var/lib/innovation-symphony/vm-operations.json'
GUEST_TOOL = '/var/lib/innovation-symphony/vm-tools/guest.py'
PORTS = {'staging': (14000, 18613, 18765), 'production': (4000, 8613, 8765)}
UNIT = 'symphony-vm.service'


def run(argv, **kwargs):
    """Never expose subprocess output: it can contain guest credentials."""
    try:
        result = subprocess.run([str(x) for x in argv], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, **kwargs)
    except subprocess.TimeoutExpired:
        raise TimeoutError('external operation timed out; no QEMU signal issued') from None
    if result.returncode:
        raise RuntimeError(f'{Path(str(argv[0])).name} failed (exit {result.returncode}); output withheld')
    return result.stdout


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def safe_root(root):
    root = Path(root).absolute()
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(root)) or root == Path('/'):
        raise ValueError('VM root must be an absolute path without whitespace or shell/unit metacharacters')
    if root.resolve() != root:
        raise ValueError('VM root must be canonical and must not traverse symlinks')
    return root


def deployment(root):
    data = json.loads((root / 'deployment.json').read_text())
    uuid.UUID(data['vm_uuid'])
    for key, value in {'vcpus': 8, 'memory_mib': 12288, 'disk_gib': 50}.items():
        if type(data[key]) is not int or data[key] != value:
            raise ValueError(f'approved {key} must be {value}')
    if not re.fullmatch(r'[a-f0-9]{64}', data['image_sha256']):
        raise ValueError('deployment must pin image_sha256')
    return data


def verify_image(root, expected, *, keyring=None, signer=None, external=False):
    image = root / 'noble-server-cloudimg-amd64.img'
    if not re.fullmatch(r'[a-f0-9]{64}', expected) or sha256(image) != expected:
        raise ValueError('Ubuntu image SHA256 mismatch')
    lines = (root / 'SHA256SUMS').read_text().splitlines()
    matches = [line.split()[0] for line in lines
               if len(line.split()) == 2 and line.split()[1].lstrip('*') == image.name]
    if matches != [expected]:
        raise ValueError('signed SHA256SUMS must contain exactly the pinned image entry')
    if external:
        if keyring or signer:
            raise ValueError('select inside verification or explicit outside verification, not both')
        if not (root / 'SHA256SUMS.gpg').is_file():
            raise ValueError('preserve the externally verified detached signature')
        return 'external-signature-verification-explicitly-attested'
    if not keyring or not signer or not re.fullmatch(r'[A-Fa-f0-9]{40}', signer):
        raise ValueError('supply trusted Ubuntu cloud image keyring AND full signer fingerprint, or explicitly attest outside verification')
    status = run(['gpgv', '--homedir', '/usr/share/keyrings', '--keyring', str(Path(keyring).resolve()),
                  '--status-fd', '1', root / 'SHA256SUMS.gpg', root / 'SHA256SUMS']).decode()
    valid = [line.split()[2:] for line in status.splitlines() if line.startswith('[GNUPG:] VALIDSIG ')]
    if not any(signer.upper() in (fields[0], fields[-1]) for fields in valid):
        raise ValueError('signature was not made by the independently trusted Ubuntu signer')
    return 'gpgv:' + signer.upper()


def qemu_command(root, data=None):
    root = safe_root(root)
    data = data or deployment(root)
    return ['/usr/bin/qemu-system-x86_64', '-name', 'symphony-vm', '-uuid', data['vm_uuid'],
            '-machine', 'q35,accel=kvm', '-cpu', 'host', '-smp', '8', '-m', '12288',
            '-drive', f'file={root}/system.qcow2,if=virtio,format=qcow2',
            '-drive', f'file={root}/seed.img,media=cdrom,readonly=on',
            '-netdev', 'user,id=nat,hostfwd=tcp:127.0.0.1:22220-:22',
            '-device', 'virtio-net-pci,netdev=nat', '-display', 'none',
            '-serial', f'file:{root}/console.log', '-monitor', 'none',
            '-qmp', f'unix:{root}/qmp.sock,server=on,wait=off']


def ssh_command(root, remote=(), *, tunnels=None):
    root = safe_root(root)
    argv = ['/usr/bin/ssh', '-F', '/dev/null', '-T', '-p', '22220', '-i', str(root / 'ssh_ed25519'),
            '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none', '-o', 'ForwardAgent=no',
            '-o', 'BatchMode=yes', '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no',
            '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={root}/known_hosts',
            '-o', 'ConnectTimeout=5', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3']
    if tunnels:
        argv += ['-N', '-o', 'ExitOnForwardFailure=yes']
        for local, guest in zip(PORTS[tunnels], PORTS['production']):
            argv += ['-L', f'127.0.0.1:{local}:127.0.0.1:{guest}']
    argv.append('elma@127.0.0.1')
    if remote:
        argv.append(shlex.join([str(x) for x in remote]))
    return argv


def systemd_command(argv):
    return ' '.join('"' + str(x).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"' for x in argv)


def host_units(root, data):
    tool = root / 'generated/tools/operations.py'
    cli = ['/usr/bin/python3', str(tool), '--root', str(root)]
    units = {UNIT: '\n'.join([
        '[Unit]', 'Description=Symphony local Ubuntu VM (8 CPU, 12 GiB, 50 GiB)',
        '[Service]', 'Type=simple', 'UMask=0077',
        'ExecStartPre=' + systemd_command(cli + ['launch-check']),
        'ExecStart=' + systemd_command(['/usr/bin/flock', '--nonblock', '--no-fork', str(root / 'qemu.lock')] + qemu_command(root, data)),
        # Internal callback avoids contending with the public stop caller's CLI
        # lock when QEMU exits. Guest maintenance is independently locked.
        'ExecStop=' + systemd_command(cli + ['guest-poweroff', '--apply', '--timeout', '120']),
        '# A failed normal shutdown MUST leave QEMU alive, including systemctl stop.',
        'KillMode=none', 'SendSIGKILL=no', 'TimeoutStopSec=infinity', 'Restart=on-failure', 'RestartSec=10',
        '[Install]', 'WantedBy=default.target', ''])}
    for mode in PORTS:
        units[f'symphony-vm-tunnels-{mode}.service'] = '\n'.join([
            '[Unit]', f'Description=Symphony SSH tunnels ({mode})', f'After={UNIT}', f'BindsTo={UNIT}',
            '[Service]', 'Type=simple', 'UMask=0077',
            'ExecStart=' + systemd_command(ssh_command(root, tunnels=mode)),
            'Restart=on-failure', 'RestartSec=10', '[Install]', f'WantedBy={UNIT}', ''])
    units['symphony-vm-disk.service'] = '\n'.join([
        '[Unit]', 'Description=Pause Symphony intake below disk floors',
        '[Service]', 'Type=oneshot', 'UMask=0077',
        'ExecStart=' + systemd_command(cli + ['check', '--apply']), ''])
    units['symphony-vm-disk.timer'] = '\n'.join([
        '[Unit]', 'Description=Check VM disk floors every 15 seconds', '[Timer]',
        'OnBootSec=30', 'OnUnitActiveSec=15', '[Install]', 'WantedBy=timers.target', ''])
    units['symphony-vm-backup.service'] = '\n'.join([
        '[Unit]', 'Description=Daily idle Symphony application backup', f'After={UNIT}',
        '[Service]', 'Type=oneshot', 'UMask=0077', 'TimeoutStartSec=infinity',
        'ExecStart=' + systemd_command(cli + ['daily-backup', '--apply']), ''])
    units['symphony-vm-backup.timer'] = '\n'.join([
        '[Unit]', 'Description=Daily Symphony idle backup (three successful generations)',
        '[Timer]', 'OnCalendar=*-*-* 03:00:00', 'RandomizedDelaySec=15m', 'Persistent=true',
        '[Install]', 'WantedBy=timers.target', ''])
    return units


def write_new(path, content, mode=0o600):
    with Path(path).open('x', encoding='utf-8') as stream:
        os.chmod(path, mode)
        stream.write(content)


def generate(root, data, verification):
    out = root / 'generated'
    out.mkdir(mode=0o700)  # Exclusive: partial or previous generations require operator review.
    (out / 'host').mkdir()
    (out / 'tools').mkdir()
    for name in ('operations.py', 'guest.py', 'bootstrap-guest.sh', 'artifacts.py', 'check-native.sh', 'isolated-check.sh'):
        shutil.copyfile(Path(__file__).with_name(name), out / 'tools' / name)
        os.chmod(out / 'tools' / name, 0o700)
    for name, contents in host_units(root, data).items():
        write_new(out / 'host' / name, contents)
    # Import works both as package and as the installed standalone script.
    sys.path.insert(0, str(Path(__file__).parent))
    import guest
    (out / 'guest').mkdir()
    for name, contents in guest.units().items():
        write_new(out / 'guest' / name, contents)
    write_new(out / 'verification.json', json.dumps({
        'vm_uuid': data['vm_uuid'], 'image_sha256': data['image_sha256'],
        'signature_verification': verification,
        'seed_sha256': sha256(root / 'seed.img'),
    }, indent=2) + '\n')
    return {'generated': str(out), 'installed': False, 'started': False}


def adopt(root, *, apply=False, keyring=None, signer=None, external=False):
    root = safe_root(root)
    data = deployment(root)
    if (root / 'generated').exists():
        raise FileExistsError('generated already exists; refusing to replace it')
    verification = verify_image(root, data['image_sha256'], keyring=keyring, signer=signer, external=external)
    for name in ('ssh_ed25519', 'ssh_ed25519.pub', 'user-data', 'meta-data', 'seed.img', 'system.qcow2'):
        if not (root / name).is_file() or (root / name).is_symlink():
            raise ValueError(f'adoption requires regular existing {name}')
    if (root / 'ssh_ed25519').stat().st_mode & 0o077:
        raise ValueError('dedicated SSH identity must have mode 0600 or stricter')
    info = json.loads(run(['qemu-img', 'info', '--force-share', '--output=json', root / 'system.qcow2']))
    if info['format'] != 'qcow2' or info['virtual-size'] != 50 * GIB or info.get('backing-filename'):
        raise ValueError('require standalone qcow2 with exactly 50 GiB virtual size')
    if not apply:
        return {'action': 'adopt', 'writes': [str(root / 'generated')], 'applied': False}
    return generate(root, data, verification)


def cloud_init(public_key, vm_uuid):
    fields = public_key.strip().split()
    if len(fields) < 2 or fields[0] != 'ssh-ed25519' or not re.fullmatch(r'[A-Za-z0-9+/=]+', fields[1]):
        raise ValueError('supply the existing guest-only ed25519 public key')
    # Drop comments. Never accept private keys, passwords or host credentials in seed.
    key = ' '.join(fields[:2])
    return ('#cloud-config\nusers:\n  - name: elma\n    groups: [adm, sudo]\n'
            '    shell: /bin/bash\n    lock_passwd: true\n    sudo: "ALL=(ALL) NOPASSWD:ALL"\n'
            f'    ssh_authorized_keys:\n      - {key}\nssh_pwauth: false\ndisable_root: true\n'
            'write_files:\n  - path: /etc/symphony-vm\n    permissions: "0644"\n'
            '    content: symphony-local-ubuntu2404-amd64\n'), (
                f'instance-id: {vm_uuid}\nlocal-hostname: symphony-vm\n')


def prepare(root, inputs, *, apply=False, keyring=None, signer=None, external=False):
    root = safe_root(root)
    if root.exists():
        raise FileExistsError('VM directory exists; use explicit adopt after reviewing it')
    inputs = Path(inputs).resolve()
    # Inputs use the same names as the reviewed deployment; no downloads/key generation.
    expected = json.loads((inputs / 'deployment.json').read_text())['image_sha256']
    deployment(inputs)
    verify_image(inputs, expected, keyring=keyring, signer=signer, external=external)
    cloud_init((inputs / 'ssh_ed25519.pub').read_text(), str(uuid.uuid4()))
    if shutil.disk_usage(root.parent).free < 15 * GIB:
        raise ValueError('host free space below 15 GiB')
    if not apply:
        return {'action': 'prepare', 'writes': [str(root)], 'applied': False}
    root.mkdir(mode=0o700)
    for name in ('noble-server-cloudimg-amd64.img', 'SHA256SUMS', 'SHA256SUMS.gpg', 'ssh_ed25519', 'ssh_ed25519.pub'):
        shutil.copyfile(inputs / name, root / name)
        os.chmod(root / name, 0o600)
    data = {**expected_deployment(expected), 'vm_uuid': str(uuid.uuid4())}
    write_new(root / 'deployment.json', json.dumps(data, indent=2) + '\n')
    user, meta = cloud_init((root / 'ssh_ed25519.pub').read_text(), data['vm_uuid'])
    write_new(root / 'user-data', user)
    write_new(root / 'meta-data', meta)
    run(['cloud-localds', root / 'seed.img', root / 'user-data', root / 'meta-data'])
    run(['qemu-img', 'convert', '-f', 'qcow2', '-O', 'qcow2', root / 'noble-server-cloudimg-amd64.img', root / 'system.qcow2'])
    run(['qemu-img', 'resize', root / 'system.qcow2', '50G'])
    return adopt(root, apply=True, keyring=keyring, signer=signer, external=external)


def expected_deployment(image_hash):
    return {'image_sha256': image_hash, 'vcpus': 8, 'memory_mib': 12288, 'disk_gib': 50}


def qmp_running(root):
    path = root / 'qmp.sock'
    if not path.exists():
        return False
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(3)
        try:
            sock.connect(str(path))
        except OSError as error:
            if error.errno in (errno.ECONNREFUSED, errno.ENOENT):
                return False
            raise  # Inaccessible or unresponsive QMP is unknown, not permission to start.
        with sock.makefile('rwb', buffering=0) as stream:
            json.loads(stream.readline())
            for command in ('qmp_capabilities', 'query-status'):
                stream.write((json.dumps({'execute': command}) + '\n').encode())
                while True:
                    response = json.loads(stream.readline())
                    if 'error' in response:
                        raise ValueError('QMP query failed')
                    if 'return' in response:
                        break
            return True  # Paused/prelaunch QEMU still owns the disk.


def launch_check(root):
    deployment(root)
    if shutil.disk_usage(root).free < 15 * GIB:
        raise ValueError('host free space below 15 GiB; no new VM start')
    if qmp_running(root):
        raise ValueError('QEMU exists; refusing duplicate launch')
    # QEMU may leave a stale socket after crashing. It replaces its socket on
    # restart; a live lock (including an unresponsive managed QEMU) forbids that.
    with (root / 'qemu.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(lock, fcntl.LOCK_UN)
    if not os.access('/dev/kvm', os.R_OK | os.W_OK):
        raise ValueError('current user requires read/write access to /dev/kvm')
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 22220))
    return {'launch_check': 'passed'}


def start(root, *, apply=False, tunnels=None):
    if qmp_running(root):
        raise ValueError('QEMU already exists; refusing duplicate start')
    if not apply:
        return {'action': 'start', 'applied': False}
    launch_check(root)
    run(['systemctl', '--user', 'start', UNIT])
    deadline = time.monotonic() + 10
    while not qmp_running(root):
        if time.monotonic() >= deadline:
            raise ValueError('unit start returned but QMP is unavailable; inspect unit without starting another QEMU')
        time.sleep(0.1)
    if tunnels:
        run(['systemctl', '--user', 'start', f'symphony-vm-tunnels-{tunnels}.service'])
    return {'qemu': 'running', 'guest_readiness': 'not_verified'}


def stop(root, *, apply=False, timeout=120):
    if not qmp_running(root):
        return {'qemu': 'not_running'}
    if not apply:
        return {'action': 'guest-normal-shutdown', 'applied': False}
    # Guest helper requires the intake-only marker and no running/retrying work.
    run(ssh_command(root, ['python3', GUEST_TOOL, 'shutdown', '--config', GUEST_CONFIG, '--apply']), timeout=timeout)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not qmp_running(root):
            return {'qemu': 'stopped_normally'}
        time.sleep(0.25)
    raise TimeoutError('normal guest shutdown timed out; QEMU LEFT RUNNING; no signal/kill issued')


def check(root, *, apply=False):
    host_free = shutil.disk_usage(root).free
    marker = root / 'admission-paused'
    paused = host_free < 15 * GIB or marker.exists() or marker.is_symlink()
    if apply and paused and not (marker.exists() or marker.is_symlink()):
        try:
            write_new(marker, 'host free space below 15 GiB; manual resume required\n')
        except FileExistsError:
            # Another independent check created the latch. Confirm it remains
            # present, then still propagate the host pause to the guest.
            marker.lstat()
    command = ['python3', GUEST_TOOL, 'guard' if apply else 'check', '--config', GUEST_CONFIG]
    if apply:
        command += ['--apply']
        if paused:
            command += ['--host-paused']
    guest = json.loads(run(ssh_command(root, command)))
    return {'host_free_bytes': host_free, 'host_floor_bytes': 15 * GIB,
            'host_paused': paused, 'guest': guest, 'applied': apply}


def backup(root, destination, *, apply=False, daily=False):
    destination = Path(destination).absolute()
    if destination.exists() or destination.is_symlink():
        raise FileExistsError('backup destination exists')
    if not apply:
        return {'action': 'backup', 'destination': str(destination), 'applied': False}
    if shutil.disk_usage(destination.parent).free < 15 * GIB:
        raise ValueError('backup filesystem below host floor')
    # Exclusive partial is preserved on failure; never delete possible recovery material.
    partial = destination.with_name(destination.name + '.partial')
    with partial.open('xb') as output:
        os.chmod(partial, 0o600)
        argv = ssh_command(root, ['python3', GUEST_TOOL, 'daily-backup' if daily else 'backup',
                                 '--config', GUEST_CONFIG, '--apply'])
        result = subprocess.run(argv, stdout=output, stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError('guest backup failed; partial retained; guest output withheld')
    sys.path.insert(0, str(Path(__file__).parent))
    import guest
    guest.verify_archive(partial)
    # link() is exclusive, unlike rename() which can overwrite another operator's file.
    os.link(partial, destination)
    partial.unlink()
    return {'backup': str(destination), 'sha256': sha256(destination)}


def rotation_candidates(directory, vm_uuid):
    successful = []
    if not directory.exists():
        return []
    for receipt in directory.glob('daily-*.tar.success.json'):
        if receipt.is_symlink():
            continue
        data = json.loads(receipt.read_text())
        name = receipt.name.removesuffix('.success.json')
        archive = directory / name
        if (not re.fullmatch(r'daily-\d{8}T\d{12}Z-[a-f0-9]{32}\.tar', name)
                or data.get('kind') != 'symphony-vm-daily-backup' or data.get('vm_uuid') != vm_uuid
                or data.get('archive') != name or not archive.is_file() or archive.is_symlink()):
            continue
        # Receipt AND hash prove this is a completed backup owned by this tool.
        if sha256(archive) != data.get('sha256'):
            continue
        successful.append((archive, receipt))
    successful.sort(key=lambda pair: pair[0].name, reverse=True)
    return [pair for pair in successful[3:] if not pair[0].with_suffix('.tar.keep').exists()]


def daily_backup(root, *, apply=False):
    directory = root / 'backups'
    if directory.is_symlink():
        raise ValueError('managed backup directory must not be a symlink')
    vm_uuid = deployment(root)['vm_uuid']
    if not apply:
        return {'action': 'daily-backup', 'applied': False,
                'rotation_candidates': [str(path) for pair in rotation_candidates(directory, vm_uuid) for path in pair]}
    directory.mkdir(mode=0o700, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    destination = directory / f'daily-{stamp}-{uuid.uuid4().hex}.tar'
    result = backup(root, destination, apply=True, daily=True)
    write_new(destination.with_name(destination.name + '.success.json'), json.dumps({
        'kind': 'symphony-vm-daily-backup', 'vm_uuid': vm_uuid,
        'archive': destination.name, 'sha256': result['sha256']}, indent=2) + '\n')
    removed = []
    for archive, receipt in rotation_candidates(directory, vm_uuid):
        archive.unlink()
        receipt.unlink()
        removed += [str(archive), str(receipt)]
    return {**result, 'rotated': removed}


def restore(root, archive, target, *, apply=False):
    target = str(safe_root(target))
    if any(target == live or target.startswith(live + '/') or live.startswith(target + '/')
           for live in (GUEST_ROOT, '/var/lib/innovation-symphony', '/opt/innovation-symphony/release')):
        raise ValueError('restore must use an independent guest target')
    sys.path.insert(0, str(Path(__file__).parent))
    import guest
    guest.verify_archive(Path(archive))
    if not apply:
        return {'action': 'restore-disabled-intake', 'target': target, 'applied': False}
    with Path(archive).open('rb') as source:
        result = subprocess.run(ssh_command(root, ['python3', GUEST_TOOL, 'restore', '--config', GUEST_CONFIG,
                                                 '--target', target, '--apply']),
                                stdin=source, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError('guest restore failed; partial independent target retained; output withheld')
    return {'restored_target': target, 'intake': 'disabled', 'activated': False}


@contextmanager
def operation_lock(root):
    # Kept forever; deleting lock files allows different operators to lock
    # different inodes. The QEMU lifetime lock is separate from this CLI lock.
    with (root / '.operations.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=DEFAULT_ROOT)
    sub = parser.add_subparsers(dest='action', required=True)
    for action in ('prepare', 'adopt', 'check', 'start', 'stop', 'guest-poweroff', 'backup', 'daily-backup', 'restore', 'command', 'launch-check'):
        p = sub.add_parser(action)
        if action not in ('command', 'launch-check'):
            p.add_argument('--apply', action='store_true')
        if action in ('prepare', 'adopt'):
            p.add_argument('--keyring', type=Path)
            p.add_argument('--signer-fingerprint')
            p.add_argument('--signature-verified-externally', action='store_true',
                           help='explicit attestation: trusted Ubuntu signer AND detached SHA256SUMS signature already verified outside this tool')
        if action == 'prepare':
            p.add_argument('--inputs', type=Path, required=True)
        if action == 'start':
            p.add_argument('--tunnels', choices=PORTS)
        if action in ('stop', 'guest-poweroff'):
            p.add_argument('--timeout', type=float, default=120)
        if action == 'backup':
            p.add_argument('--destination', type=Path, required=True)
        if action == 'restore':
            p.add_argument('--archive', type=Path, required=True)
            p.add_argument('--target', required=True)
        if action == 'command':
            p.add_argument('kind', choices=['qemu', 'ssh', 'staging', 'production'])
    a = parser.parse_args(argv)
    root = safe_root(a.root)
    if a.action == 'command':
        command = qemu_command(root) if a.kind == 'qemu' else ssh_command(root, tunnels=a.kind if a.kind in PORTS else None)
        print(shlex.join(command))
        return 0
    # Disk admission must run during long backup/restore operations. Host
    # latch creation is exclusive/idempotent; guest guard owns its short lock.
    if getattr(a, 'apply', False) and a.action not in ('prepare', 'guest-poweroff', 'check'):
        with operation_lock(root):
            result = dispatch(a, root)
    else:
        result = dispatch(a, root)
    print(json.dumps(result, indent=2))
    return 0


def dispatch(a, root):
    if a.action in ('prepare', 'adopt'):
        kwargs = dict(apply=a.apply, keyring=a.keyring, signer=a.signer_fingerprint,
                      external=a.signature_verified_externally)
        result = prepare(root, a.inputs, **kwargs) if a.action == 'prepare' else adopt(root, **kwargs)
    elif a.action == 'launch-check':
        result = launch_check(root)
    elif a.action == 'check':
        result = check(root, apply=a.apply)
    elif a.action == 'start':
        result = start(root, apply=a.apply, tunnels=a.tunnels)
    elif a.action in ('stop', 'guest-poweroff'):
        if a.timeout <= 0:
            raise ValueError('shutdown timeout must be positive')
        result = stop(root, apply=a.apply, timeout=a.timeout)
    elif a.action == 'backup':
        result = backup(root, a.destination, apply=a.apply)
    elif a.action == 'daily-backup':
        result = daily_backup(root, apply=a.apply)
    else:
        result = restore(root, a.archive, a.target, apply=a.apply)
    return result


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print(f'vm: {error}', file=sys.stderr)
        sys.exit(1)
