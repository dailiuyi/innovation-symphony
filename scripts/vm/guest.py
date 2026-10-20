#!/usr/bin/env python3
"""Guest disk admission and quiescent backups. Python 3.12 standard library."""
import argparse
from contextlib import ExitStack, closing, contextmanager
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import socket
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import uuid

ROOT = '/var/tmp/innovation-symphony-linux-runtime'
RELEASE = '/opt/innovation-symphony/release'
CONFIG = '/var/lib/innovation-symphony'
FLOOR = 5 * 1024 ** 3
SERVICES = ('symphony-controller.service', 'symphony-model-settings.service', 'symphony-view.service')
MANIFEST = 'VM-BACKUP.json'


def default_settings():
    return dict(runtime_root=ROOT, config_root=CONFIG, state_dir=ROOT + '/state',
                workflow=CONFIG + '/WORKFLOW.md', release_root=RELEASE,
                model_settings=CONFIG + '/model-settings.json', view_config=CONFIG + '/view.toml',
                view_root=CONFIG + '/view', view_venv=CONFIG + '/view-venv',
                environment_file=CONFIG + '/runtime.env',
                auth_paths=[CONFIG + '/runtime.env', '/home/elma/.codex', '/home/elma/.ssh'],
                credential_inventory_reviewed=False)


def load_settings(path):
    return validate_settings(json.loads(Path(path).read_text()))


def overlaps(left, right):
    return left == right or left.is_relative_to(right) or right.is_relative_to(left)


def validate_settings(data):
    expected = default_settings()
    if set(data) != set(expected):
        raise ValueError('guest operations settings require every documented input, no unknown fields')
    for key in set(expected) - {'auth_paths', 'credential_inventory_reviewed'}:
        value = data[key]
        if not isinstance(value, str) or not re.fullmatch(r'/[A-Za-z0-9_./-]+', value) or Path(value).resolve() != Path(value):
            raise ValueError('settings paths must be canonical absolute paths without unit metacharacters')
    roots = {name: Path(data[name]) for name in ('runtime_root', 'config_root', 'release_root', 'view_root')}
    for left, right in (('runtime_root', 'config_root'), ('runtime_root', 'release_root'),
                        ('config_root', 'release_root'), ('view_root', 'runtime_root'), ('view_root', 'release_root')):
        if overlaps(roots[left], roots[right]):
            raise ValueError('guest runtime/config/release/View root relationship is invalid')
    if roots['view_root'] == roots['config_root'] or roots['config_root'].is_relative_to(roots['view_root']):
        raise ValueError('View must be a child of config_root or an independent root')
    for key in ('workflow', 'model_settings', 'view_config', 'view_venv', 'environment_file'):
        if Path(data[key]) == roots['config_root'] or not Path(data[key]).is_relative_to(roots['config_root']):
            raise ValueError('guest service configuration must be under config_root')
    if Path(data['state_dir']) == roots['runtime_root'] or not Path(data['state_dir']).is_relative_to(roots['runtime_root']):
        raise ValueError('state_dir must be explicitly rooted under the runtime')
    if not isinstance(data['auth_paths'], list) or not all(isinstance(p, str) and Path(p).is_absolute() for p in data['auth_paths']):
        raise ValueError('auth_paths must be a reviewed list of absolute credential paths')
    if type(data['credential_inventory_reviewed']) is not bool:
        raise ValueError('credential_inventory_reviewed must be boolean')
    if workflow_config(Path(data['workflow']).read_bytes())['state_dir'] != data['state_dir']:
        raise ValueError('configured state_dir differs from actual WORKFLOW mvp.state_dir')
    return data


def pause_path(settings):
    return Path(settings['state_dir']) / 'intake-paused'


def command(argv):
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f'{Path(argv[0]).name} failed (exit {result.returncode}); output withheld')
    return result.stdout.decode()


@contextmanager
def maintenance(settings):
    # Guest and host locks are separate. Even direct systemctl stop cannot
    # interrupt an ongoing backup with a poweroff request.
    validate_settings(settings)
    with (Path(settings['state_dir']) / '.vm-maintenance.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def unique_object(pairs):
    data = {}
    for key, value in pairs:
        if key in data:
            raise ValueError('duplicate configuration key')
        data[key] = value
    return data


def workflow_config(content):
    """Read the explicitly supported ASCII YAML subset or JSON front matter.

    Direct mvp keys must be literal unquoted keys; aliases, tags, merge keys,
    duplicate keys and nonliteral state_dir are refused rather than guessed.
    """
    text = content.decode('utf-8')
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].rstrip('\r\n') != '---':
        raise ValueError('WORKFLOW requires YAML front matter')
    end = next((i for i in range(1, len(lines)) if lines[i].rstrip('\r\n') == '---'), None)
    if end is None:
        raise ValueError('WORKFLOW front matter is incomplete')
    header = ''.join(lines[1:end])
    header.encode('ascii')
    result = {'lines': lines, 'end': end}
    if header.lstrip().startswith('{'):
        config = json.loads(header, object_pairs_hook=unique_object)
        if not isinstance(config, dict) or not isinstance(config.get('mvp'), dict):
            raise ValueError('WORKFLOW JSON requires an mvp object')
        selected = config['mvp']
        result.update(kind='json', config=config)
    else:
        top = {}
        for i in range(1, end):
            line = lines[i]
            if not line.strip() or line.lstrip().startswith('#') or line.startswith(' '):
                continue
            match = re.fullmatch(r'([A-Za-z_][A-Za-z0-9_-]*):([^\r\n]*)\r?\n?', line)
            if not match or match[1] in top:
                raise ValueError('unsupported or duplicate WORKFLOW top-level key')
            top[match[1]] = (i, match[2])
        if 'mvp' not in top or top['mvp'][1].split('#', 1)[0].strip():
            raise ValueError('require one literal top-level mvp mapping')
        start = top['mvp'][0]
        result.update(kind='yaml', start=start)
        selected = {}
        selected_locations = {}
        boundary = min((i for i, _ in top.values() if i > start), default=end)
        meaningful = [(i, line) for i, line in enumerate(lines[start + 1:boundary], start + 1)
                      if line.strip() and not line.lstrip().startswith('#')]
        indent = min((len(line) - len(line.lstrip(' ')) for _, line in meaningful), default=0)
        for i, line in meaningful:
            if '\t' in line[:len(line) - len(line.lstrip())]:
                raise ValueError('tabs unsupported in WORKFLOW indentation')
            if len(line) - len(line.lstrip(' ')) != indent:
                continue
            match = re.fullmatch(r' +([A-Za-z_][A-Za-z0-9_-]*):([^\r\n]*)\r?\n?', line)
            if not match or match[1] in selected:
                raise ValueError('unsupported or duplicate direct mvp key')
            selected[match[1]] = match[2].split('#', 1)[0].strip()
            selected_locations[match[1]] = i
        if selected.get('enabled') not in ('true', 'false'):
            raise ValueError('require one literal mvp.enabled: true|false')
        raw_state = selected.get('state_dir', '')
        if raw_state.startswith('"'):
            state = json.loads(raw_state)
        elif raw_state.startswith("'") and raw_state.endswith("'"):
            state = raw_state[1:-1].replace("''", "'")
        else:
            state = raw_state
        selected = {'enabled': selected['enabled'] == 'true', 'state_dir': state}
        result['enabled_index'] = selected_locations['enabled']
    if type(selected.get('enabled')) is not bool:
        raise ValueError('require boolean mvp.enabled')
    state = selected.get('state_dir')
    if not isinstance(state, str) or not re.fullmatch(r'/[A-Za-z0-9_./-]+', state) or str(PurePosixPath(state)) != state or '..' in PurePosixPath(state).parts:
        raise ValueError('WORKFLOW mvp.state_dir must be a literal canonical absolute path')
    return {**result, 'enabled': selected['enabled'], 'state_dir': state}


def workflow_edit(content, enabled):
    parsed = workflow_config(content)
    lines, end = parsed['lines'], parsed['end']
    if parsed['kind'] == 'json':
        parsed['config']['mvp']['enabled'] = enabled
        return (lines[0] + json.dumps(parsed['config'], indent=2) + '\n' + ''.join(lines[end:])).encode(), parsed['enabled']
    index = parsed['enabled_index']
    match = re.fullmatch(r'( +enabled:[ \t]*)(true|false)([ \t]*(?:#.*)?)(\r?\n)?', lines[index])
    lines[index] = match[1] + ('true' if enabled else 'false') + match[3] + (match[4] or '')
    return ''.join(lines).encode(), parsed['enabled']


def pause(settings, reason):
    validate_settings(settings)
    marker = pause_path(settings)
    with intake_lock(marker):
        return create_marker(marker, (reason + '\nManual resume requires disk checks and explicit intake authorization.\n').encode())


@contextmanager
def intake_lock(marker):
    # Guard runs concurrently with backup. Serialize its adoption of a disk
    # fence with the backup's ownership check/unlink, without the long-lived
    # maintenance lock that would prevent timely disk checks.
    with (marker.parent / '.vm-intake.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def disk_pause(settings):
    validate_settings(settings)
    marker = pause_path(settings)
    with intake_lock(marker):
        if marker.is_symlink() or (marker.exists() and not stat.S_ISREG(marker.lstat().st_mode)):
            # Already fenced, and backup cleanup cannot own this nonregular
            # marker. Preserve it while allowing the paused controller to run.
            return
        # Atomic replacement changes inode ownership without ever opening a
        # gap in the fence. A backup may no longer delete this disk-owned pause.
        with tempfile.NamedTemporaryFile(dir=marker.parent, prefix='.intake-disk-', delete=False) as stream:
            stream.write(b'Disk admission paused: host below 15 GiB or guest below 5 GiB.\nManual resume required.\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(stream.name, marker)


def create_marker(path, content):
    # Return exact ownership, never overwrite a preexisting marker.
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return None
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
        identity = os.fstat(stream.fileno())
    return path, identity.st_dev, identity.st_ino, content


def remove_owned_marker(owned):
    if owned is None:
        return
    path, device, inode, content = owned
    if path.name == 'intake-paused':
        with intake_lock(path):
            remove_marker_identity(path, device, inode, content)
    else:
        remove_marker_identity(path, device, inode, content)


def remove_marker_identity(path, device, inode, content):
    try:
        current = path.lstat()
    except FileNotFoundError:
        return
    if stat.S_ISREG(current.st_mode) and (current.st_dev, current.st_ino) == (device, inode) and path.read_bytes() == content:
        path.unlink()


def maintenance_path(settings):
    return Path(settings['state_dir']) / 'maintenance.json'


def read_maintenance(settings):
    path = maintenance_path(settings)
    observed = path.lstat()
    if not stat.S_ISREG(observed.st_mode) or observed.st_size > 4096:
        raise ValueError('maintenance marker must be a regular file')
    data = json.loads(path.read_text(), object_pairs_hook=unique_object)
    if not isinstance(data, dict) or set(data) != {'nonce', 'reason'} or not isinstance(data['nonce'], str) or not re.fullmatch('[a-f0-9]{32}', data['nonce']) or not isinstance(data['reason'], str):
        raise ValueError('maintenance marker requires nonce32hex and reason')
    return data


def request_maintenance(settings, reason):
    validate_settings(settings)
    owned = create_marker(maintenance_path(settings), json.dumps({'nonce': uuid.uuid4().hex, 'reason': reason}).encode())
    return read_maintenance(settings)['nonce'], owned


def check(settings, *, apply=False, host_paused=False):
    validate_settings(settings)
    free = min(shutil.disk_usage(settings[name]).free for name in ('runtime_root', 'config_root', 'view_root'))
    marker = pause_path(settings)
    paused = free < FLOOR or host_paused or marker.exists() or marker.is_symlink()
    if apply and (free < FLOOR or host_paused):
        disk_pause(settings)
    return {'guest_free_bytes': free, 'guest_floor_bytes': FLOOR,
            'admission_paused': paused, 'pause_path': str(marker),
            'disk_admitted': not paused, 'applied': apply}


def require_stopped():
    for service in SERVICES:
        data = command(['systemctl', 'show', service, '--property=LoadState,ActiveState,MainPID,ControlGroup'])
        state = dict(line.split('=', 1) for line in data.splitlines() if '=' in line)
        if (state.get('LoadState') not in ('loaded', 'not-found')
                or state.get('ActiveState') not in ('inactive', 'failed') or state.get('MainPID') != '0'):
            raise ValueError(f'backup requires known stopped/absent guest service: {service}')
        group = state.get('ControlGroup')
        if group:
            pending = [Path('/sys/fs/cgroup') / group.lstrip('/')]
            while pending:
                directory = pending.pop()
                if (directory / 'cgroup.procs').read_text().strip():
                    raise ValueError('guest service still has processes; no backup')
                pending.extend(path for path in directory.iterdir() if stat.S_ISDIR(path.stat().st_mode))


    # A manually launched controller outside these units is not a stopped service.
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(('127.0.0.1', 4000))


def require_paused(settings):
    validate_settings(settings)
    marker = pause_path(settings)
    if not marker.exists() and not marker.is_symlink():
        raise ValueError('requires persistent state_dir/intake-paused marker')


class MaintenanceBusy(ValueError):
    """The fenced controller acknowledged maintenance but has not drained."""


def controller_identity():
    raw = command(['systemctl', 'show', SERVICES[0], '--property=LoadState,ActiveState,MainPID'])
    state = dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)
    pid = state.get('MainPID', '')
    if state.get('LoadState') != 'loaded' or state.get('ActiveState') != 'active' or not pid.isdecimal() or int(pid) <= 0:
        raise ValueError('controller identity is not an active loaded systemd MainPID')
    return int(pid), boot_identity()


def boot_identity():
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    if str(uuid.UUID(boot)) != boot:
        raise ValueError('guest boot identity is invalid')
    return boot


def require_idle(settings, nonce=None, timeout=30):
    require_paused(settings)
    nonce = nonce or read_maintenance(settings)['nonce']
    deadline = time.monotonic() + timeout
    while True:
        if read_maintenance(settings)['nonce'] != nonce:
            raise ValueError('maintenance marker changed; refusing maintenance')
        before = controller_identity()
        with urllib.request.urlopen('http://127.0.0.1:4000/api/v1/state', timeout=5) as response:
            data = json.load(response)
        after = controller_identity()
        ack = data.get('maintenance') if isinstance(data, dict) else None
        if (before == after and isinstance(ack, dict) and ack.get('nonce') == nonce
                and ack.get('acknowledged') is True and type(ack.get('pid')) is int
                and (ack['pid'], ack.get('boot_id')) == after):
            if read_maintenance(settings)['nonce'] != nonce:
                raise ValueError('maintenance marker changed during acknowledgement')
            if ack.get('drained') is False:
                raise MaintenanceBusy('maintenance acknowledged but controller has not drained')
            if ack.get('drained') is True:
                return ack
        if time.monotonic() >= deadline:
            raise TimeoutError('no matching serial maintenance acknowledgement; services left running')
        time.sleep(0.1)


def shutdown(settings):
    validate_settings(settings)
    pause(settings, 'Normal guest shutdown requested; existing task authorization preserved.')
    nonce, _ = request_maintenance(settings, 'Normal guest shutdown')
    # If controller is already stopped, all service cgroups must be empty.
    state = command(['systemctl', 'show', SERVICES[0], '--property=ActiveState', '--value']).strip()
    if state == 'inactive':
        require_paused(settings)
        require_stopped()
    elif state == 'active':
        require_idle(settings, nonce)
    else:
        raise ValueError('controller state unknown; refusing shutdown')
    if read_maintenance(settings)['nonce'] != nonce:
        raise ValueError('maintenance marker changed before poweroff')
    command(['sudo', '-n', 'systemctl', 'poweroff', '--no-block'])


def entries(root):
    # Do not traverse links. External references require a reviewed expanded
    # backup inventory, never silently omit them or infer that they are stale.
    for base, directories, files in os.walk(root, followlinks=False):
        for name in sorted(directories + files):
            path = Path(base) / name
            if not path.is_symlink() and not path.is_dir() and not path.is_file():
                raise ValueError('runtime has special file; quiesce and review instead of omitting it')
            yield path


def backup_roots(settings):
    return {name: Path(settings[key]).resolve() for name, key in
            (('runtime', 'runtime_root'), ('config', 'config_root'), ('view', 'view_root'))}


def archive_name(path, roots):
    # Longest root wins when View lives under config_root.
    for alias, root in sorted(roots.items(), key=lambda item: len(str(item[1])), reverse=True):
        if path == root or path.is_relative_to(root):
            return alias + ('/' + path.relative_to(root).as_posix() if path != root else '')
    raise ValueError('backup has external recovery reference; expand the reviewed inventory first')


def excluded(path, settings):
    if any(part in ('.ssh', 'auth.json', 'credentials.json', 'secrets.env', 'runtime.env') for part in path.parts):
        return True
    runtime = Path(settings['runtime_root'])
    if path.is_relative_to(runtime):
        parts = path.relative_to(runtime).parts
        if parts[:3] == ('codex-home', 'tmp', 'arg0-linux'):
            return True
        if (len(parts) >= 5 and parts[0] == 'sandboxes' and parts[1].startswith('run-')
                and parts[2:5] == ('codex-home', 'tmp', 'arg0-linux')):
            return True
    # Recreate the Python environment from the fixed release requirements.
    return any(path == Path(p) or path.is_relative_to(p) for p in
               settings['auth_paths'] + [settings['view_venv'], settings['environment_file']])


def backup(settings, output):
    require_paused(settings)
    read_maintenance(settings)
    require_stopped()
    if settings['credential_inventory_reviewed'] is not True:
        raise ValueError('review and declare all credential paths before backing up')
    roots = backup_roots(settings)
    paths = {}
    for alias, root in roots.items():
        if not root.is_dir():
            raise ValueError('every configured backup root must exist')
        paths[alias] = root
        for path in entries(root):
            name = archive_name(path, roots)
            if name.startswith(alias + '/') and not excluded(path, settings):
                paths[name] = path
    sidecars = set()
    # SQLite backup() incorporates committed WAL content. Never copy live WAL or
    # omit unrelated files merely because their names end in -wal/-shm.
    manifest = {'format': 1, 'source_roots': {name: str(path) for name, path in roots.items()},
                'intake': 'paused', 'entries': {}, 'state_path': archive_name(Path(settings['state_dir']), roots),
                'workflow_path': archive_name(Path(settings['workflow']), roots),
                'editable_configs': [archive_name(Path(settings[key]), roots) for key in
                                     ('workflow', 'model_settings', 'view_config')],
                'credentials': 'excluded; restore authentication separately'}
    with tempfile.TemporaryDirectory(prefix='symphony-sqlite-', dir=Path(settings['runtime_root']).parent) as temporary:
        with tarfile.open(fileobj=output, mode='w|') as archive:
            for name, path in sorted(paths.items()):
                if path in sidecars:
                    continue
                if name == MANIFEST:
                    raise ValueError('reserved backup manifest already exists in source')
                observed = path.lstat()
                mode = stat.S_IMODE(observed.st_mode)
                info = tarfile.TarInfo(name)
                info.mode = mode
                record = {'mode': mode}
                if stat.S_ISLNK(observed.st_mode):
                    info.type = tarfile.SYMTYPE
                    linked = archive_name(path.resolve(), roots)
                    if excluded(path.resolve(), settings):
                        raise ValueError('backup symlink points to excluded authentication')
                    info.linkname = os.path.relpath(linked, str(PurePosixPath(name).parent))
                    record.update(type='symlink', link=info.linkname)
                    archive.addfile(info)
                elif stat.S_ISDIR(observed.st_mode):
                    info.type = tarfile.DIRTYPE
                    record.update(type='directory')
                    archive.addfile(info)
                elif stat.S_ISREG(observed.st_mode):
                    with ExitStack() as stack:
                        # Pin one inode for header detection, metadata, digest
                        # and tar content. Atomic marker replacement may unlink
                        # this inode, but must not switch the exported bytes.
                        stream = stack.enter_context(path.open('rb', buffering=0))
                        metadata = os.fstat(stream.fileno())
                        if not stat.S_ISREG(metadata.st_mode):
                            raise ValueError('backup source is no longer a regular file')
                        database = stream.read(16) == b'SQLite format 3\x00'
                        stream.seek(0)
                        if database:
                            # Sorted paths put each database before its own
                            # WAL/SHM, without opening every regular file twice.
                            sidecars.update(Path(str(path) + suffix) for suffix in ('-wal', '-shm'))
                            snapshot = Path(temporary) / uuid.uuid4().hex
                            with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)) as connection:
                                with closing(sqlite3.connect(snapshot)) as target:
                                    connection.backup(target)
                            stream = stack.enter_context(snapshot.open('rb', buffering=0))
                            os.fchmod(stream.fileno(), stat.S_IMODE(metadata.st_mode))
                            metadata = os.fstat(stream.fileno())
                        info.mode = stat.S_IMODE(metadata.st_mode)
                        info.size = metadata.st_size
                        record.update(type='file', mode=info.mode, size=info.size,
                                      sha256=hashlib.file_digest(stream, 'sha256').hexdigest(), sqlite=database)
                        stream.seek(0)
                        archive.addfile(info, stream)
                else:
                    raise ValueError('backup source changed to a special file')
                manifest['entries'][name] = record
            encoded = json.dumps(manifest, sort_keys=True).encode()
            info = tarfile.TarInfo(MANIFEST)
            info.size, info.mode = len(encoded), 0o600
            archive.addfile(info, io.BytesIO(encoded))


def member_name(name):
    if not isinstance(name, str):
        raise ValueError('archive paths must be strings')
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or name != path.as_posix() or name in ('', '.'):
        raise ValueError('unsafe archive path')
    return path


def validate_manifest(manifest, observed):
    required = {'format', 'intake', 'source_roots', 'entries', 'state_path', 'workflow_path'}
    if (not isinstance(manifest, dict) or not required.issubset(manifest)
            or set(manifest) - required - {'credentials', 'editable_configs'}
            or type(manifest['format']) is not int or manifest['format'] != 1 or manifest['intake'] != 'paused'):
        raise ValueError('invalid backup manifest schema')
    roots = manifest['source_roots']
    if not isinstance(roots, dict) or set(roots) != {'runtime', 'config', 'view'}:
        raise ValueError('backup requires runtime/config/View roots')
    parsed = {}
    for name, value in roots.items():
        if not isinstance(value, str) or not re.fullmatch('/[A-Za-z0-9_./-]+', value):
            raise ValueError('backup source roots must be absolute canonical paths')
        path = PurePosixPath(value)
        if path == PurePosixPath('/') or str(path) != value or '..' in path.parts:
            raise ValueError('backup source roots must be absolute canonical paths')
        parsed[name] = path
    if overlaps(parsed['runtime'], parsed['config']) or overlaps(parsed['runtime'], parsed['view']):
        raise ValueError('backup runtime must be independent of config and View')
    if parsed['view'] == parsed['config'] or parsed['config'].is_relative_to(parsed['view']):
        raise ValueError('backup View root relationship is invalid')
    entries = manifest['entries']
    if not isinstance(entries, dict) or set(entries) != set(observed):
        raise ValueError('backup inventory mismatch')
    for name in observed:
        path = member_name(name)
        if path.parts[0] not in roots or (len(path.parts) > 1 and archive_name(parsed[path.parts[0]] / PurePosixPath(*path.parts[1:]), parsed) != name):
            raise ValueError('backup entry has inconsistent source root mapping')
        if not isinstance(entries[name], dict):
            raise ValueError('invalid backup entry metadata')
    for alias in roots:
        if observed.get(alias, {}).get('type') != 'directory':
            raise ValueError('backup root directory is missing')
    for field, alias, kind in (('state_path', 'runtime', 'directory'), ('workflow_path', 'config', 'file')):
        path = member_name(manifest[field])
        if len(path.parts) < 2 or path.parts[0] != alias or observed.get(str(path), {}).get('type') != kind:
            raise ValueError('backup lacks its correctly rooted workflow or state directory')
    edits = manifest.get('editable_configs', [])
    if not isinstance(edits, list) or not all(isinstance(name, str) for name in edits) or len(set(edits)) != len(edits):
        raise ValueError('editable_configs must be a list of distinct paths')
    for name in edits:
        if member_name(name).parts[0] not in ('config', 'view'):
            raise ValueError('editable configs cannot rewrite runtime recovery evidence')
        if name in observed and observed[name]['type'] != 'file':
            raise ValueError('editable configuration must be a regular file')
    return manifest


def read_archive(archive, target=None):
    observed = {}
    manifest = None
    links = []
    for info in archive:
        name = member_name(info.name).as_posix()
        if name in observed or (name == MANIFEST and manifest is not None):
            raise ValueError('duplicate backup member')
        if manifest is not None:
            raise ValueError('backup manifest must be last')
        mode = info.mode & 0o777  # Restores never materialize setuid/setgid bits.
        if name == MANIFEST:
            if not info.isfile() or info.size > 64 * 1024 ** 2:
                raise ValueError('invalid backup manifest')
            manifest = json.load(archive.extractfile(info), object_pairs_hook=unique_object)
            continue
        record = {'mode': mode}
        destination = target / name if target is not None else None
        if info.isdir():
            record['type'] = 'directory'
            if target is not None:
                destination.mkdir(parents=True, exist_ok=True)
        elif info.issym():
            if PurePosixPath(info.linkname).is_absolute():
                raise ValueError('absolute symlink forbidden in restore')
            # Lexically normalize through the virtual root, without host FS IO.
            stack = list(PurePosixPath(name).parent.parts)
            for part in PurePosixPath(info.linkname).parts:
                if part == '..':
                    if not stack:
                        raise ValueError('escaping symlink forbidden')
                    stack.pop()
                elif part != '.':
                    stack.append(part)
            record.update(type='symlink', link=info.linkname)
            links.append((name, info.linkname))
        elif info.isfile():
            hasher = hashlib.sha256()
            record.update(type='file', size=info.size)
            if target is not None:
                destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(info) as source:
                if target is None:
                    while chunk := source.read(1024 * 1024):
                        hasher.update(chunk)
                else:
                    with destination.open('xb') as output:
                        while chunk := source.read(1024 * 1024):
                            hasher.update(chunk)
                            output.write(chunk)
                    os.chmod(destination, mode)
            record['sha256'] = hasher.hexdigest()
        else:
            raise ValueError('unsupported archive member (device/hardlink/socket)')
        observed[name] = record
    validate_manifest(manifest, observed)
    expected = manifest['entries']
    for name, record in observed.items():
        if any(expected[name].get(key) != value for key, value in record.items()):
            raise ValueError('backup content hash/metadata mismatch')
    # Links are last, so a malicious archive cannot write through one. No file
    # or directory may occupy a symlink's subtree, even before link creation.
    for name, _ in links:
        if any(other.startswith(name + '/') for other in observed):
            raise ValueError('archive writes through symlink')
    if target is not None:
        for name, link in links:
            (target / name).parent.mkdir(parents=True, exist_ok=True)
            (target / name).symlink_to(link)
        for name, _ in links:
            if not (target / name).resolve().is_relative_to(target):
                raise ValueError('symlink chain escapes independent restore target')
        for name, record in observed.items():
            if record['type'] == 'directory':
                os.chmod(target / name, record['mode'])
    return manifest


def verify_archive(path):
    with tarfile.open(path, mode='r:*') as archive:
        return read_archive(archive)


def restore(stream, target, settings):
    validate_settings(settings)
    target = Path(target).absolute()
    live_roots = list(backup_roots(settings).values()) + [Path(settings['release_root']).resolve()]
    if target.resolve() != target or any(target == root or target.is_relative_to(root) or root.is_relative_to(target) for root in live_roots):
        raise ValueError('restore requires independent canonical target')
    target.mkdir(mode=0o700)  # Never overwrite even an empty existing directory.
    # On failure preserve the partial target for examination; never start it.
    with tarfile.open(fileobj=stream, mode='r|*') as archive:
        manifest = read_archive(archive, target)
    original_roots = manifest['source_roots']
    preserved = target / 'restore-originals' / uuid.uuid4().hex
    preserved.mkdir(parents=True, mode=0o700)
    # A manifest cannot opt out of disabling/remapping its mandatory workflow.
    for name in dict.fromkeys([manifest['workflow_path'], *manifest.get('editable_configs', [])]):
        member_name(name)
        path = target / name
        if path.is_symlink():
            raise ValueError('runtime configuration must be a regular file')
        if path.is_file():
            saved = preserved / name
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, saved)
            content = path.read_bytes()
            for alias, old in sorted(original_roots.items(), key=lambda item: len(item[1]), reverse=True):
                content = content.replace(old.encode(), str(target / alias).encode())
            if name == manifest['workflow_path']:
                content, _ = workflow_edit(content, False)
            path.write_bytes(content)
    if not (target / member_name(manifest['workflow_path'])).is_file():
        raise ValueError('restored runtime has no WORKFLOW.md')
    state = target / member_name(manifest['state_path'])
    if not state.is_dir():
        raise ValueError('restored state directory is missing')
    restored_workflow = workflow_config((target / manifest['workflow_path']).read_bytes())
    if restored_workflow['enabled'] is not False or restored_workflow['state_dir'] != str(state):
        raise ValueError('restored WORKFLOW must be disabled and bound to the restored state directory')
    create_marker(state / 'intake-paused', b'Restored independent runtime; activation requires separate review.\n')
    with (target / 'RESTORE-NOT-ACTIVATED.json').open('x') as output:
        json.dump({'source_roots': original_roots, 'target': str(target), 'intake': 'disabled',
                   'activated': False, 'note': 'Review absolute refs, credentials, release and units before activation.'}, output)
    return {'restored_target': str(target), 'intake': 'disabled', 'activated': False}


def wait_healthy(services, timeout=30):
    ports = dict(zip(SERVICES, (4000, 8765, 8613)))
    deadline = time.monotonic() + timeout
    pending = set(services)
    while pending:
        for service in list(pending):
            state = command(['systemctl', 'show', service, '--property=ActiveState', '--value']).strip()
            if state == 'active':
                try:
                    with socket.create_connection(('127.0.0.1', ports[service]), timeout=1):
                        pending.remove(service)
                except OSError:
                    pass  # Network health boundary: retry within the explicit restart timeout.
        if not pending:
            return
        if time.monotonic() >= deadline:
            raise TimeoutError('backup finished but restarted services are not healthy; intake remains paused')
        time.sleep(0.25)


def daily_backup(settings, output):
    validate_settings(settings)
    active = []
    for service in SERVICES:
        raw = command(['systemctl', 'show', service, '--property=LoadState,ActiveState'])
        state = dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)
        if state.get('LoadState') not in ('loaded', 'not-found') or state.get('ActiveState') not in ('active', 'inactive'):
            raise ValueError('guest service state unknown; no daily backup')
        if state['ActiveState'] == 'active':
            active.append(service)
    reason = 'Daily backup ' + uuid.uuid4().hex
    owned_intake = pause(settings, reason)
    nonce, owned_maintenance = request_maintenance(settings, reason)
    completed = False
    stopped = False
    busy = False
    try:
        if SERVICES[0] in active:
            require_idle(settings, nonce)
        else:
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 4000))
        if read_maintenance(settings)['nonce'] != nonce:
            raise ValueError('maintenance marker changed before service stop')
        stopped = True
        if active:
            command(['sudo', '-n', 'systemctl', 'stop', *active])
        backup(settings, output)
        completed = True
    except MaintenanceBusy:
        busy = True
        raise
    finally:
        if stopped and active:
            # Attempt ALL originally active units even if one restart fails.
            errors = []
            for service in active:
                try:
                    command(['sudo', '-n', 'systemctl', 'start', service])
                except RuntimeError as error:
                    errors.append(error)
            if errors:
                raise RuntimeError('previously active service restart failed; intake remains paused') from errors[0]
            wait_healthy(active)
        if busy:
            # A safe busy skip is not a failed maintenance operation. Restore
            # precisely the marker state observed before this daily request.
            remove_owned_marker(owned_maintenance)
            remove_owned_marker(owned_intake)
        elif completed:
            remove_owned_marker(owned_maintenance)
            if min(shutil.disk_usage(settings[k]).free for k in ('runtime_root', 'config_root', 'view_root')) >= FLOOR:
                remove_owned_marker(owned_intake)


def units(settings=None):
    settings = settings or default_settings()
    runtime, release, config = (settings[name] for name in ('runtime_root', 'release_root', 'config_root'))
    tool = config + '/vm-tools/guest.py'
    guard = f'/usr/bin/python3 {tool} guard --config {config}/vm-operations.json --apply'
    common = ['[Unit]', 'After=network-online.target', 'Wants=network-online.target',
              '[Service]', 'User=elma', 'Group=elma', 'UMask=0077',
              f'EnvironmentFile={config}/runtime-paths.env',
              f'EnvironmentFile={settings["environment_file"]}',
              'Restart=on-failure', 'RestartSec=5', 'KillMode=control-group', 'TimeoutStopSec=120',
              # Normal TERM only. Preserve evidence when a service won't stop.
              'SendSIGKILL=no']
    binary = release + '/elixir/bin/symphony'
    starts = {
        SERVICES[0]: [f'WorkingDirectory={release}/elixir', f'ExecStartPre={guard}',
                      f'ExecStart={binary} --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4000 --logs-root {runtime}/logs {settings["workflow"]}'],
        SERVICES[1]: [f'WorkingDirectory={release}/elixir', f'ExecStart={binary} --model-settings {settings["model_settings"]}'],
        SERVICES[2]: [f'WorkingDirectory={settings["view_root"]}',
                      f'ExecStart={settings["view_venv"]}/bin/python {settings["view_root"]}/app/run.py --port 8613 --config {settings["view_config"]}'],
    }
    result = {name: '\n'.join(common + lines + ['[Install]', 'WantedBy=multi-user.target', ''])
              for name, lines in starts.items()}
    result['symphony-disk.service'] = '\n'.join([
        '[Unit]', 'Description=Guest disk intake admission', '[Service]', 'Type=oneshot',
        'User=elma', 'Group=elma', 'UMask=0077', f'ExecStart={guard}', ''])
    result['symphony-disk.timer'] = '\n'.join([
        '[Unit]', 'Description=Guest disk floors', '[Timer]', 'OnBootSec=15',
        'OnUnitActiveSec=15', '[Install]', 'WantedBy=timers.target', ''])
    result['symphony-runtime.conf'] = f'# Preserve all active/recovery artifacts, including task TMPDIR.\nx {runtime} - - - - -\n'
    result['runtime-paths.env'] = '\n'.join([
        'PATH=/usr/local/bin:/usr/bin:/bin',
        f'TMPDIR={runtime}/tmp', f'MIX_HOME={runtime}/mix', f'HEX_HOME={runtime}/hex',
        f'CODEX_HOME={runtime}/codex-home', 'DOCKER_HOST=unix:///var/run/docker.sock', ''])
    result['vm-operations.example.json'] = json.dumps(settings, indent=2) + '\n'
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('check', 'guard', 'pause', 'quiesce', 'idle', 'shutdown', 'backup', 'daily-backup', 'restore'))
    parser.add_argument('--config', type=Path, default=Path(CONFIG) / 'vm-operations.json')
    parser.add_argument('--target', type=Path)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--host-paused', action='store_true')
    a = parser.parse_args(argv)
    settings = load_settings(a.config)
    if a.action in ('check', 'guard'):
        result = check(settings, apply=a.action == 'guard' and a.apply, host_paused=a.host_paused)
    elif a.action == 'idle':
        require_idle(settings)
        result = {'idle': True, 'intake': 'paused'}
    elif not a.apply:
        result = {'action': a.action, 'applied': False}
    elif a.action in ('backup', 'daily-backup'):
        with maintenance(settings):
            (daily_backup if a.action == 'daily-backup' else backup)(settings, sys.stdout.buffer)
        return
    elif a.action == 'restore':
        if a.target is None:
            raise ValueError('restore requires --target')
        result = restore(sys.stdin.buffer, a.target, settings)
    elif a.action == 'pause':
        pause(settings, 'Explicit operator pause for maintenance; existing task authorization preserved.')
        result = {'intake': 'paused', 'pause_path': str(pause_path(settings))}
    elif a.action == 'quiesce':
        with maintenance(settings):
            pause(settings, 'Explicit maintenance; existing task authorization preserved.')
            nonce, _ = request_maintenance(settings, 'Explicit maintenance')
            result = {'maintenance': require_idle(settings, nonce)}
    else:
        with maintenance(settings):
            shutdown(settings)
        result = {'normal_poweroff_requested': True}
    print(json.dumps(result))


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, sqlite3.Error, tarfile.TarError) as error:
        # File content/SQL/subprocess errors can contain secrets: print type only.
        print(f'guest operation refused ({type(error).__name__}); inspect policy and local state', file=sys.stderr)
        sys.exit(1)
