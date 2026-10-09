"""Read-only host readiness for the fixed rootless execution contract.

This inventory never runs a task/container/model or claims formal acceptance.
The authenticated bridge owns the policy and supplies the request.
"""
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import stat
import subprocess
import zipfile

LIMIT = 16384
SANDBOX_FIELDS = set('root toolchain codex dependencies trusted_root image worker profile network memory_mb disk_mb pids cpus environment_recipe'.split())
TOOLS = ('podman', 'crun', 'newuidmap', 'newgidmap', 'ip', 'nft', 'mount', 'umount', 'mkfs.ext4', 'setpriv', 'timeout', 'iptables', 'nsenter')
INIT_PATH = Path('/usr/bin/catatonit')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate request field: ' + key)
        result[key] = value
    return result


def validate_request(raw, policy):
    if not isinstance(raw, str) or len(raw.encode()) > LIMIT:
        raise ValueError('readiness request exceeds limit or is not JSON text')
    request = json.loads(raw, object_pairs_hook=unique_object)
    if not isinstance(request, dict) or set(request) != {'sandbox', 'state_dir', 'workspace_root', 'checks'}:
        raise ValueError('invalid readiness request fields')
    sandbox = request['sandbox']
    if not isinstance(sandbox, dict) or set(sandbox) != SANDBOX_FIELDS:
        raise ValueError('invalid readiness sandbox fields')
    if sandbox['profile'] != 'rootless-open-v1' or sandbox['network'] != 'public-egress-v1':
        raise ValueError('unsupported readiness profile or network')
    if not isinstance(sandbox['image'], str) or not re.fullmatch(r'[A-Za-z0-9./:_-]+@sha256:[0-9a-f]{64}', sandbox['image']):
        raise ValueError('digest-pinned image required')
    if not isinstance(sandbox['worker'], str) or not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', sandbox['worker']):
        raise ValueError('invalid worker')
    for key in ('root', 'toolchain', 'codex', 'dependencies', 'trusted_root'):
        value = sandbox[key]
        if not isinstance(value, str) or not value.startswith('/') or any(c in value for c in '\x00\n\r:,'):
            raise ValueError('invalid canonical path: ' + key)
    for key, upper in (('memory_mb', 65536), ('disk_mb', 65536), ('pids', 65536), ('cpus', 64)):
        value = sandbox[key]
        if type(value) is not int or not 1 <= value <= upper or (key in ('memory_mb', 'disk_mb') and value < 128):
            raise ValueError('invalid resource: ' + key)
    recipe = sandbox['environment_recipe']
    if not isinstance(recipe, str) or Path(recipe).is_absolute() or '..' in Path(recipe).parts or any(c in recipe for c in '\x00\n\r'):
        raise ValueError('invalid environment recipe')
    checks = request['checks']
    if not isinstance(checks, list) or not checks or len(checks) > 3 or any(kind not in ('candidate', 'baseline', 'view') for kind in checks) or len(set(checks)) != len(checks):
        raise ValueError('invalid declared check kinds')
    for key in ('state_dir', 'workspace_root'):
        value = request[key]
        if not isinstance(value, str) or not value.startswith('/') or any(c in value for c in '\x00\n\r:,'):
            raise ValueError('invalid ' + key)
    rootless = policy.get('rootless', {})
    for field, value in (('--backend', 'rootless'), ('--image', sandbox['image']), ('--worker', sandbox['worker'])):
        if rootless.get(field) != value:
            raise ValueError('rootless policy mismatch: ' + field)
    for field, key in (('--toolchain', 'toolchain'), ('--codex', 'codex'), ('--dependencies', 'dependencies'), ('--trusted-root', 'trusted_root'), ('--memory-mb', 'memory_mb'), ('--disk-mb', 'disk_mb'), ('--pids', 'pids'), ('--cpus', 'cpus')):
        if policy.get('fixed', {}).get(field) != str(sandbox[key]):
            raise ValueError('fixed policy mismatch: ' + field)
    for key, expected in (('workspaces', request['workspace_root']), ('state', request['state_dir']), ('sandboxes', sandbox['root'])):
        if policy.get(key) != expected:
            raise ValueError('root binding mismatch: ' + key)
    return request


def protected(path, directory=False):
    path = Path(path)
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise ValueError('noncanonical protected path: ' + str(path))
    info = path.lstat()
    if info.st_uid != 0 or info.st_mode & 0o022 or (not stat.S_ISDIR(info.st_mode) if directory else not stat.S_ISREG(info.st_mode)):
        raise ValueError('unprotected ' + str(path))
    for parent in path.parents:
        info = parent.stat()
        if info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError('unprotected parent: ' + str(parent))
    return path


def command(argv, expected=None, env=None):
    result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=15, check=False, cwd='/', env=env or {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8', 'HOME': '/nonexistent', 'CODEX_HOME': '/nonexistent'})
    if result.returncode != 0:
        raise ValueError('read-only command failed: ' + Path(argv[0]).name)
    if len(result.stdout) > 65536 or len(result.stderr) > 65536:
        raise ValueError('read-only command output exceeds limit')
    output = result.stdout.decode('utf-8', 'strict').strip()
    if expected is not None and output != expected:
        raise ValueError('unexpected version: ' + Path(argv[0]).name)
    return output


def trusted_inventory(sandbox):
    root = protected(sandbox['trusted_root'], True)
    for name in ('execution_sandbox.sh', 'execution_sandbox.root.sh', 'rootless_sandbox.py', 'rootless_dns.py', 'sandbox_artifacts.py', 'runtime_identity.py', 'runtime-identity.json', 'check_isolated.py', 'check_results.py', 'check_formatter.exs'):
        protected(root / 'scripts' / name)
    gate = protected(root / 'gate-python', True)
    inventory = json.loads(protected(gate / 'bindings.json').read_text())
    if not isinstance(inventory, list) or not inventory or len(inventory) > 256:
        raise ValueError('invalid formal Python inventory')
    targets = []
    for item in inventory:
        if not isinstance(item, dict) or set(item) != {'source', 'relative', 'target'} or not all(isinstance(v, str) for v in item.values()):
            raise ValueError('invalid formal Python binding')
        source = Path(item['source'])
        if source != gate / item['relative'] or not source.is_relative_to(gate) or '..' in Path(item['relative']).parts or not Path(item['target']).is_absolute():
            raise ValueError('unbound formal Python inventory')
        protected(source, source.is_dir())
        targets.append(item['target'])
    if '/opt/gate-python' not in targets or '/etc/ld.so.preload' not in targets or len(targets) != len(set(targets)):
        raise ValueError('incomplete formal Python inventory')
    protected(sandbox['dependencies'], True)
    return ('protected runner, formal Python inventory and dependencies present; task recipe content '
            'and installation success are verified in the workspace stage and real container checks')


def toolchain_inventory(sandbox):
    root = protected(sandbox['toolchain'], True)
    for name in ('data/installs/elixir/1.19.5-otp-28/bin/elixir', 'data/installs/elixir/1.19.5-otp-28/bin/mix', 'data/installs/erlang/28.5/bin/erl'):
        protected(root / name)
    for name in ('mix', 'hex'):
        protected(root / name, True)
    client = protected(sandbox['codex'])
    with client.open('rb') as handle:
        if handle.read(4) != b'\x7fELF' or not os.access(client, os.X_OK):
            raise ValueError('native executable Codex required')
    manifest = json.loads((Path(sandbox['trusted_root']) / 'scripts/runtime-identity.json').read_text())
    command([str(client), '--version'], 'codex-cli ' + manifest['codex']['version'])
    return 'fixed Elixir/OTP paths, Mix/Hex caches and native Codex version present'


def init_inventory():
    init = protected(INIT_PATH)
    if init.stat().st_mode & 0o005 != 0o005:
        raise ValueError('fixed container init must be readable and executable by the worker')
    with init.open('rb') as handle:
        if handle.read(4) != b'\x7fELF':
            raise ValueError('fixed container init must be a native ELF executable')


def runtime_inventory(sandbox):
    for name in TOOLS:
        binary = shutil.which(name, path='/usr/sbin:/usr/bin:/sbin:/bin')
        if not binary:
            raise ValueError('missing runtime: ' + name)
        protected(Path(binary).resolve())
    init_inventory()
    if Path('/proc/sys/net/ipv4/ip_forward').read_text().strip() != '1':
        raise ValueError('IPv4 forwarding is unavailable')
    controllers = set(Path('/sys/fs/cgroup/cgroup.controllers').read_text().split())
    if not {'cpu', 'memory', 'pids'}.issubset(controllers) or not os.access('/sys/fs/cgroup/cgroup.subtree_control', os.W_OK):
        raise ValueError('writable cgroup v2 controllers unavailable')
    worker = pwd.getpwnam(sandbox['worker'])
    if worker.pw_uid == 0:
        raise ValueError('rootless worker must be non-root')
    for name in ('/etc/subuid', '/etc/subgid'):
        if not any(len(parts) == 3 and parts[0] == worker.pw_name and parts[1].isdigit() and parts[2].isdigit() and int(parts[2]) >= 65536
                   for parts in (line.split(':') for line in Path(name).read_text().splitlines())):
            raise ValueError('missing worker subordinate allocation: ' + name)
    return 'runtime executables, fixed native catatonit init, worker allocation, forwarding and cgroup prerequisites present'


def image_inventory(sandbox):
    # Each task pulls into its own bounded Podman store. A worker-home cache
    # would be an unrelated admission condition and cannot prove that pull.
    if not re.fullmatch(r'[A-Za-z0-9./:_-]+@sha256:[0-9a-f]{64}', sandbox['image']):
        raise ValueError('digest-pinned image required')
    return 'digest-pinned image matches trusted policy; registry reachability, task pull and container launch not tested'


def task_roots(request, policy):
    """Check controller DAC permissions without root's os.access bypass."""
    uid, gid = policy['uid'], policy['gid']
    if type(uid) is not int or uid <= 0 or type(gid) is not int or gid < 0:
        raise ValueError('invalid controller uid/gid')

    def permissions(path, required):
        info = path.stat()
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError('task root or parent is not a directory: ' + str(path))
        shift = 6 if info.st_uid == uid else (3 if info.st_gid == gid else 0)
        if ((info.st_mode >> shift) & required) != required:
            raise ValueError('controller lacks directory permissions: ' + str(path))

    roots = [Path(request['state_dir']), Path(request['workspace_root']), Path(request['sandbox']['root'])]
    for path in roots:
        if path.resolve(strict=True) != path:
            raise ValueError('task root must be canonical and non-linked: ' + str(path))
        permissions(path, 0o7)
        for parent in path.parents:
            permissions(parent, 0o1)
    for index, left in enumerate(roots):
        for right in roots[index + 1:]:
            if left == right or left.is_relative_to(right) or right.is_relative_to(left):
                raise ValueError('task roots overlap')
    minimum = (request['sandbox']['disk_mb'] + 192) * 1048576
    for path in roots:
        disk = os.statvfs(path)
        if disk.f_flag & getattr(os, 'ST_RDONLY', 1):
            raise ValueError('task root filesystem is read-only: ' + str(path))
        if disk.f_bavail * disk.f_frsize < minimum:
            raise ValueError('task root has insufficient bounded disk and reserve: ' + str(path))
    return ('canonical disjoint task roots permit controller access and creation; per-attempt disk '
            'plus 192 MiB reserve available; cumulative task storage is not proven')


def view_inventory(sandbox):
    tools = Path(sandbox['toolchain']) / 'view-validation'
    python = tools / 'python/bin/python'
    # A venv interpreter is normally a symlink. Its resolved executable and the
    # protected venv configuration are validated separately.
    protected(python.resolve(strict=True))
    protected(tools / 'python/pyvenv.cfg')
    node = protected(tools / 'node/bin/node')
    command([str(node), '--version'], 'v24.19.0')
    command([str(python), '-I', '-B', '-c', "import importlib.metadata;print(importlib.metadata.version('codex-transcript-viewer'))"], '0.5.0')
    package = tools / 'playwright/node_modules/playwright'
    if json.loads(protected(package / 'package.json').read_text()).get('version') != '1.62.1':
        raise ValueError('Playwright 1.62.1 unavailable')
    browsers = tools / 'playwright/browsers'
    browser_manifest = json.loads(protected(tools / 'playwright/node_modules/playwright-core/browsers.json').read_text())
    chromium = next((entry for entry in browser_manifest.get('browsers', []) if entry.get('name') == 'chromium'), None)
    if not chromium or not str(chromium.get('revision', '')).isdigit():
        raise ValueError('Playwright Chromium revision unavailable')
    chrome = list(browsers.glob('chromium-' + str(chromium['revision']) + '/chrome-linux*/chrome'))
    if not chrome:
        raise ValueError('matching Chromium executable unavailable')
    for binary in chrome:
        protected(binary)
    source = Path(sandbox['trusted_root']) / 'scripts/view_validation/source'
    archive = protected(source / 'view-source.zip')
    manifest = json.loads(protected(source / 'source-manifest.json').read_text())
    if not isinstance(manifest, dict) or not manifest:
        raise ValueError('invalid fixed View source manifest')
    if archive.stat().st_size > 67108864:
        raise ValueError('fixed View source archive exceeds inventory limit')
    packed = archive.read_bytes()
    if manifest.get('schema_version') != 1 or manifest.get('archive') != {'name': 'view-source.zip', 'bytes': len(packed), 'sha256': hashlib.sha256(packed).hexdigest()}:
        raise ValueError('fixed View source archive does not match manifest')
    packager = protected(Path(sandbox['trusted_root']) / 'scripts/prepare_view_source.py')
    if manifest.get('packager_sha256') != hashlib.sha256(packager.read_bytes()).hexdigest():
        raise ValueError('fixed View source packager does not match manifest')
    with zipfile.ZipFile(archive) as package_file:
        if not package_file.infolist() or package_file.testzip() is not None:
            raise ValueError('corrupt fixed View source archive')
    protected(Path(sandbox['trusted_root']) / 'scripts/check_view_isolated.py')
    return 'fixed View Python, Node, Playwright, Chromium and source archive present; browser launch not tested'


def inspect_readiness(raw, policy):
    report = {'schema': 1, 'status': 'blocked', 'backend': 'rootless', 'profile': 'rootless-open-v1', 'checks': [], 'blockers': [],
              'formal_acceptance': False, 'detail': 'Static environment readiness only; real container checks, model and acceptance chain remain separate.',
              'request_sha256': hashlib.sha256(raw.encode()).hexdigest() if isinstance(raw, str) else None}
    try:
        request = validate_request(raw, policy)
    except (ValueError, TypeError, KeyError, OSError, RecursionError) as error:
        report['blockers'].append({'name': 'request', 'detail': str(error)[:1024]})
        return report
    sandbox = request['sandbox']
    probes = [('task_roots', lambda _: task_roots(request, policy)), ('trusted_inventory', trusted_inventory), ('toolchain', toolchain_inventory), ('runtime', runtime_inventory), ('image', image_inventory)]
    if 'view' in request['checks']:
        probes.append(('view', view_inventory))
    for name, probe in probes:
        try:
            detail = probe(sandbox)
            report['checks'].append({'name': name, 'status': 'passed', 'detail': detail})
        except (ValueError, TypeError, KeyError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
            detail = str(error)[:1024]
            report['checks'].append({'name': name, 'status': 'failed', 'detail': detail})
            report['blockers'].append({'name': name, 'detail': detail})
    if not report['blockers']:
        report['status'] = 'ready'
    return report
