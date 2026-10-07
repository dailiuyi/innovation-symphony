"""Local, single-controller stdio bridge to the existing Linux sandbox runner.

The controller user is trusted; guest processes cannot access this socket.
No shell commands, environment values or privileged host executables are accepted.
"""
import array
import json
import os
from pathlib import Path
import re
import select
import signal
import shutil
import tempfile
import socket
import stat
import struct
import subprocess
import sys

# -I suppresses script-directory imports; only this protected installation is added.
sys.path.insert(0, str(Path(__file__).resolve().parent))

INSTALL = Path('/opt/innovation-symphony-rootless-bridge')
SOCKET = INSTALL / 'execution.sock'
LIMIT = 16384


def validate(argv, policy):
    if argv == ['--check']:
        return None
    if not isinstance(argv, list) or not all(isinstance(v, str) and '\0' not in v for v in argv):
        raise ValueError('invalid arguments')
    delimiter = argv.index('--')
    before, command = argv[:delimiter], argv[delimiter + 1:]
    if len(before) % 2:
        raise ValueError('named fields must occur exactly once')
    fields = dict(zip(before[::2], before[1::2]))
    expected = {'--workspace', '--scratch-root', '--toolchain', '--codex', '--trusted-root',
                '--dependencies', '--baseline', '--evidence', '--timeout-seconds',
                '--memory-mb', '--disk-mb', '--pids', '--cpus'}
    if fields.get('--backend') == 'rootless':
        expected.update({'--backend', '--image', '--worker', '--environment-recipe'})
        for key in ('--backend', '--image', '--worker'):
            if fields[key] != policy.get('rootless', {}).get(key):
                raise ValueError('rootless policy mismatch: ' + key)
        if '--preflight' in fields:
            if fields['--preflight'] != 'true':
                raise ValueError('invalid preflight')
            expected.add('--preflight')
        recipe = Path(fields['--environment-recipe'])
        if fields['--environment-recipe'] and (recipe.is_absolute() or '..' in recipe.parts):
            raise ValueError('unsafe environment recipe')
    elif '--backend' in fields:
        raise ValueError('invalid backend')
    if '--read-only-workspace' in fields:
        if fields['--read-only-workspace'] != 'true':
            raise ValueError('invalid read-only mode')
        expected.add('--read-only-workspace')
    if len(before) != 2 * len(expected) or len(fields) != len(expected) or set(fields) != expected:
        raise ValueError('invalid or duplicate fields')
    for key, value in policy['fixed'].items():
        if fields[key] != value:
            raise ValueError('fixed policy mismatch: ' + key)
    timeout = fields['--timeout-seconds']
    if not re.fullmatch(r'[1-9][0-9]*', timeout) or int(timeout) > 7200:
        raise ValueError('timeout exceeds local policy')
    dynamic = {}
    for key, base in (('--workspace', policy['workspaces']), ('--evidence', policy['state'])):
        path = Path(fields[key])
        if not path.is_absolute() or str(path.resolve(strict=True)) != str(path):
            raise ValueError('path must be canonical')
        path.relative_to(Path(base))
        if path == Path(base) or not path.is_dir():
            raise ValueError('path must be a task directory')
        dynamic[key] = path
    if Path(fields['--baseline']) != dynamic['--evidence'] / 'baseline':
        raise ValueError('baseline must belong to this evidence directory')
    baseline = Path(fields['--baseline'])
    if not baseline.is_dir() or baseline.resolve(strict=True) != baseline:
        raise ValueError('invalid baseline')
    scratch = Path(fields['--scratch-root'])
    if scratch.parent.parent != Path(policy['sandboxes']) or scratch.name != 'sandbox':
        raise ValueError('scratch must belong to a prepared sandbox run')
    if not re.fullmatch(r'run-[0-9]+-[0-9]+', scratch.parent.name):
        raise ValueError('invalid run identifier')
    if scratch.parent.resolve(strict=True) != scratch.parent:
        raise ValueError('invalid scratch parent')
    if scratch.exists() or scratch.is_symlink():
        raise ValueError('scratch must be new')
    allowed = command == ['/opt/codex', 'exec-server', '--listen', 'stdio']
    if len(command) == 5 and command[:2] == ['python3', '/opt/symphony/scripts/check_isolated.py']:
        allowed = command[2] in ('candidate', 'baseline') and command[3] == '--candidate-sha' and bool(re.fullmatch(r'[0-9a-f]{40}', command[4]))
    if (len(command) == 6 and command[:5] == [
            '/opt/toolchain/view-validation/python/bin/python', '-I', '-B',
            '/opt/symphony/scripts/check_view_isolated.py', '--candidate-sha']):
        allowed = bool(re.fullmatch(r'[0-9a-f]{40}', command[5]))
    if len(command) == 4 and command[:3] == ['python3', '/opt/symphony/scripts/probe_rootless.py', '--candidate-sha']:
        allowed = fields.get('--backend') == 'rootless' and bool(re.fullmatch(r'[0-9a-f]{40}', command[3]))
    if not allowed:
        raise ValueError('command is not an approved executor or fixed check')
    return None if fields.get('--preflight') == 'true' else scratch


def transfer_ownership(path, uid, gid):
    # Results are created by the root runner; do not follow exported links.
    if not path or not path.is_dir() or path.is_symlink():
        return
    for directory, dirs, files in os.walk(path, followlinks=False):
        for name in dirs + files:
            target = Path(directory) / name
            os.chown(target, uid, gid, follow_symlinks=False)
    os.chown(path, uid, gid, follow_symlinks=False)


def stage_inputs(argv, scratch, budget):
    temporary = Path(tempfile.mkdtemp(prefix='symphony-bridge-', dir='/var/tmp'))
    used = 0
    def bounded_copy(source, destination):
        nonlocal used
        used += os.stat(source, follow_symlinks=False).st_size
        if used > budget:
            raise ValueError('input snapshot exceeds local disk budget')
        return shutil.copy2(source, destination)
    fields = dict(zip(argv[:argv.index('--'):2], argv[1:argv.index('--'):2]))
    try:
        for key, name in (('--workspace', 'workspace'), ('--evidence', 'evidence')):
            shutil.copytree(fields[key], temporary / name, symlinks=True, copy_function=bounded_copy)
        # The worker can traverse only this private snapshot, not controller roots.
        os.chmod(temporary, 0o711)
        os.chmod(temporary / 'workspace', 0o711)
        for directory, dirs, files in os.walk(temporary / 'evidence', followlinks=False):
            os.chmod(directory, 0o555)
            for filename in files:
                target = Path(directory) / filename
                if not target.is_symlink():
                    os.chmod(target, 0o444 | (target.stat().st_mode & 0o111))
        rewritten = list(argv)
        replacements = {'--workspace': temporary / 'workspace', '--evidence': temporary / 'evidence',
                        '--baseline': temporary / 'evidence/baseline', '--scratch-root': temporary / 'scratch'}
        for key, path in replacements.items():
            rewritten[rewritten.index(key) + 1] = str(path)
        return temporary, rewritten
    except Exception:
        shutil.rmtree(temporary)
        raise


def publish_results(temporary, scratch, uid, gid):
    source = temporary / 'scratch'
    proof = source / 'result.json'
    if proof.is_symlink() or not proof.is_file():
        return False
    result = json.loads(proof.read_text())
    if result.get('cleanup_complete') is not True:
        return False
    if result.get('scratch_root') != str(source):
        raise ValueError('unexpected runner completion source')
    pending_tree = Path(tempfile.mkdtemp(prefix='.sandbox-bridge-', dir=scratch.parent))
    try:
        pending_tree.rmdir()
        source.rename(pending_tree)
        result['transport_source_scratch'] = result['scratch_root']
        result['scratch_root'] = str(scratch)
        if result.get('source_volume') == str(source / 'work.img'):
            result['source_volume'] = str(scratch / 'work.img')
        from sandbox_artifacts import save_json
        save_json(pending_tree / 'result.json', result)
        transfer_ownership(pending_tree, uid, gid)
        # Publish directory, ownership and proof together: polling must never see
        # a root-only scratch directory and mistake EACCES for incomplete cleanup.
        pending_tree.rename(scratch)
        from sandbox_artifacts import sync_directory
        sync_directory(scratch.parent)
    except Exception:
        # Publication failure must preserve the durable source, including work.img.
        print('preserved failed result publication: ' + str(pending_tree), file=sys.stderr, flush=True)
        raise
    return result.get('cleanup_complete') is True


def serve_connection(connection, policy, runner):
    fds = []
    child = None
    scratch = None
    temporary = None
    safe_to_remove = False
    try:
        _, uid, gid = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        if uid != policy['uid'] or gid != policy['gid']:
            raise ValueError('unauthorized controller identity')
        connection.settimeout(5)
        data, ancillary, flags, _ = connection.recvmsg(LIMIT + 1, socket.CMSG_SPACE(3 * array.array('i').itemsize))
        for level, kind, value in ancillary:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                received = array.array('i')
                received.frombytes(value[:len(value) - len(value) % received.itemsize])
                fds.extend(received)
        if flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC) or len(data) > LIMIT or len(fds) != 3:
            raise ValueError('invalid request or standard streams')
        argv = json.loads(data)
        scratch = validate(argv, policy)
        if scratch:
            temporary, argv = stage_inputs(argv, scratch, int(policy['fixed']['--disk-mb']) * 1048576)
        child = subprocess.Popen(['/bin/bash', str(runner), *argv], stdin=fds[0], stdout=fds[1], stderr=fds[2],
                                 cwd='/', env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8', 'HOME': '/root'},
                                 start_new_session=True, close_fds=True)
        connection.settimeout(None)
        while child.poll() is None:
            if select.select([connection], [], [], 0.2)[0]:
                # The client sends exactly one request. Disconnect aborts the run.
                if connection.recv(1) != b'':
                    raise ValueError('unexpected second request')
                raise ConnectionError('controller disconnected')
        if temporary:
            safe_to_remove = publish_results(temporary, scratch, uid, gid)
        connection.sendall(str(max(0, child.returncode) if child.returncode >= 0 else 128 - child.returncode).encode())
    except Exception as error:
        print('bridge refused or failed: ' + str(error), file=sys.stderr, flush=True)
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        # Interrupted or uncertain runs keep their evidence; no completion is forged.
        if temporary and scratch and not scratch.exists():
            safe_to_remove = publish_results(temporary, scratch, policy['uid'], policy['gid'])
        try:
            connection.sendall(b'125')
        except OSError:
            pass
    finally:
        if temporary and safe_to_remove:
            shutil.rmtree(temporary)
        elif temporary:
            print('preserved uncertain bridge stage: ' + str(temporary), file=sys.stderr, flush=True)
        for fd in fds:
            os.close(fd)


def client(argv, address=SOCKET, expected_peer_uid=0):
    with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as connection:
        connection.connect(str(address))
        _, uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        if uid != expected_peer_uid:
            raise PermissionError('unexpected helper identity')
        message = json.dumps(argv).encode()
        if len(message) > LIMIT:
            raise ValueError('request too large')
        connection.sendmsg([message], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [0, 1, 2]))])
        status = connection.recv(16)
        return int(status) if status else 125


def server():
    if os.geteuid() != 0:
        raise PermissionError('root server required')
    def interrupted(_signal, _frame):
        raise InterruptedError("bridge stopped; task cleanup required")
    signal.signal(signal.SIGTERM, interrupted)
    policy = json.loads((INSTALL / 'policy.json').read_text())
    runner = INSTALL / 'trusted/scripts/execution_sandbox.root.sh'
    for path in (INSTALL, INSTALL / 'policy.json', Path(__file__), runner):
        info = path.lstat()
        if info.st_uid != 0 or info.st_mode & 0o022 or stat.S_ISLNK(info.st_mode):
            raise PermissionError('installation must be root-owned and protected')
    with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as listener:
        # Never replace an existing socket from another active helper.
        listener.bind(str(SOCKET))
        os.chown(SOCKET, policy['uid'], policy['gid'])
        os.chmod(SOCKET, 0o600)
        listener.listen(4)
        print('local sandbox bridge ready', flush=True)
        try:
            while True:
                connection, _ = listener.accept()
                with connection:
                    serve_connection(connection, policy, runner)
        finally:
            SOCKET.unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['--server']:
            server()
        elif sys.argv[1:2] == ['--client']:
            raise SystemExit(client(sys.argv[2:]))
        else:
            raise ValueError('use --server or --client')
    except (ValueError, OSError) as error:
        print('sandbox bridge: ' + str(error), file=sys.stderr)
        raise SystemExit(125)
