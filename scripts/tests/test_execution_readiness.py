"""Admission inventory failure and authenticated transport regressions."""
import array
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import execution_readiness as readiness
import linux_bridge


def inputs():
    sandbox = dict(root='/var/tmp/sandboxes', toolchain='/opt/toolchain', codex='/usr/bin/codex',
                   dependencies='/opt/dependencies', trusted_root='/opt/bridge/trusted',
                   image='docker.io/library/ubuntu@sha256:' + 'a' * 64, worker='symphony-worker',
                   profile='rootless-open-v1', network='public-egress-v1', memory_mb=4096,
                   disk_mb=20480, pids=512, cpus=4, environment_recipe='scripts/rootless_environment.sh')
    request = dict(sandbox=sandbox, state_dir='/var/tmp/state', workspace_root='/var/tmp/workspaces', checks=['candidate', 'baseline'])
    policy = dict(uid=os.getuid(), gid=os.getgid(), workspaces=request['workspace_root'], state=request['state_dir'],
                  sandboxes=sandbox['root'], rootless={'--backend': 'rootless', '--image': sandbox['image'], '--worker': sandbox['worker']},
                  fixed={'--' + key.replace('_', '-'): str(sandbox[key]) for key in ('toolchain', 'codex', 'dependencies', 'trusted_root', 'memory_mb', 'disk_mb', 'pids', 'cpus')})
    return request, policy


class ExecutionReadinessTest(unittest.TestCase):
    def test_request_binds_every_fixed_contract_and_rejects_unknown_fields(self):
        request, policy = inputs()
        self.assertEqual(readiness.validate_request(json.dumps(request), policy), request)
        for key in policy['fixed']:
            changed = json.loads(json.dumps(policy))
            changed['fixed'][key] = 'wrong'
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'fixed policy mismatch'):
                readiness.validate_request(json.dumps(request), changed)
        for key in ('workspaces', 'state', 'sandboxes'):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'root binding mismatch'):
                readiness.validate_request(json.dumps(request), {**policy, key: '/other'})
        for changed in ({**request, 'command': 'touch /tmp/oops'}, {**request, 'sandbox': {**request['sandbox'], 'extra': True}}):
            with self.assertRaises(ValueError):
                readiness.validate_request(json.dumps(changed), policy)

    def test_request_rejects_duplicate_fields_invalid_resources_recipe_and_checks(self):
        request, policy = inputs()
        raw = json.dumps(request)
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            readiness.validate_request(raw[:-1] + ',"checks":["view"]}', policy)
        for key, value in (('cpus', True), ('disk_mb', 127), ('pids', 65537), ('memory_mb', 1.0),
                           ('environment_recipe', '../host'), ('environment_recipe', '/host'), ('profile', 'other')):
            altered = {**request, 'sandbox': {**request['sandbox'], key: value}}
            self.assertEqual(readiness.inspect_readiness(json.dumps(altered), policy)['status'], 'blocked')
        for checks in ([], ['candidate', 'candidate'], ['custom'], 'candidate', [None], [{'kind': 'candidate'}]):
            self.assertEqual(readiness.inspect_readiness(json.dumps({**request, 'checks': checks}), policy)['status'], 'blocked')
        for raw in ('x' * 17000, '{invalid', '[]', '[' * 2000 + ']' * 2000):
            self.assertEqual(readiness.inspect_readiness(raw, policy)['status'], 'blocked')

    def test_empty_and_task_relative_recipes_do_not_require_trusted_template(self):
        request, policy = inputs()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            gate = root / 'gate-python'
            gate.mkdir()
            (gate / '0').write_text('python inventory fixture')
            (gate / 'empty-preload').write_text('')
            (gate / 'bindings.json').write_text(json.dumps([
                dict(source=str(gate / '0'), relative='0', target='/opt/gate-python'),
                dict(source=str(gate / 'empty-preload'), relative='empty-preload', target='/etc/ld.so.preload')]))
            for recipe in ('', '.symphony/environment.sh'):
                with self.subTest(recipe=recipe):
                    request['sandbox']['environment_recipe'] = recipe
                    readiness.validate_request(json.dumps(request), policy)
                    config = {**request['sandbox'], 'trusted_root': str(root)}
                    with patch.object(readiness, 'protected', side_effect=lambda path, directory=False: Path(path)) as protected:
                        detail = readiness.trusted_inventory(config)
                    self.assertIn('task recipe content', detail)
                    self.assertIn('workspace stage and real container checks', detail)
                    self.assertFalse((root / '.symphony/environment.sh').exists())
                    self.assertFalse(any(call.args[0] == root / '.symphony/environment.sh' for call in protected.call_args_list))

    def test_report_preserves_all_blockers_request_hash_and_acceptance_boundary(self):
        request, policy = inputs()
        raw = json.dumps(request, indent=2)
        with ExitStack() as stack:
            for name in ('task_roots', 'trusted_inventory', 'toolchain_inventory', 'runtime_inventory', 'image_inventory'):
                stack.enter_context(patch.object(readiness, name, side_effect=ValueError(name + ' missing')))
            report = readiness.inspect_readiness(raw, policy)
        self.assertEqual(report['status'], 'blocked')
        self.assertEqual(len(report['blockers']), 5)
        self.assertEqual(report['request_sha256'], hashlib.sha256(raw.encode()).hexdigest())
        self.assertFalse(report['formal_acceptance'])

    def test_view_probe_only_for_declared_check_and_timeouts_block(self):
        request, policy = inputs()
        with ExitStack() as stack:
            for name in ('task_roots', 'trusted_inventory', 'toolchain_inventory', 'runtime_inventory', 'image_inventory'):
                stack.enter_context(patch.object(readiness, name, return_value='present'))
            view = stack.enter_context(patch.object(readiness, 'view_inventory', side_effect=subprocess.TimeoutExpired('node', 15)))
            self.assertEqual(readiness.inspect_readiness(json.dumps(request), policy)['status'], 'ready')
            view.assert_not_called()
            request['checks'].append('view')
            report = readiness.inspect_readiness(json.dumps(request), policy)
            self.assertEqual(report['status'], 'blocked')
            self.assertEqual(report['blockers'][0]['name'], 'view')

    def test_protected_paths_refuse_links_and_writable_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source'
            source.write_text('data')
            source.chmod(0o666)
            linked = root / 'linked'
            linked.symlink_to(source)
            with self.assertRaisesRegex(ValueError, 'noncanonical'):
                readiness.protected(linked)
            with self.assertRaisesRegex(ValueError, 'unprotected'):
                readiness.protected(source)

    def test_gate_inventory_cannot_escape_or_omit_formal_interpreter(self):
        request, _ = inputs()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            gate = root / 'gate-python'
            gate.mkdir()
            request['sandbox']['trusted_root'] = str(root)
            for entries in ([dict(source='/tmp/foreign', relative='../foreign', target='/opt/gate-python')],
                            [dict(source=str(gate / '0'), relative='0', target='/etc/ld.so.preload')], []):
                (gate / 'bindings.json').write_text(json.dumps(entries))
                with patch.object(readiness, 'protected', side_effect=lambda path, directory=False: Path(path)):
                    with self.assertRaises(ValueError):
                        readiness.trusted_inventory(request['sandbox'])

    def test_task_roots_are_existing_disjoint_controller_writable_and_have_capacity(self):
        request, policy = inputs()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            roots = [root / name for name in ('state', 'workspace', 'sandbox')]
            for path in roots:
                path.mkdir()
                path.chmod(0o700)
            request['state_dir'], request['workspace_root'], request['sandbox']['root'] = map(str, roots)
            minimum = (request['sandbox']['disk_mb'] + 192) * 1048576
            disk = type('Disk', (), dict(f_flag=0, f_bavail=minimum, f_frsize=1))()
            with patch.object(readiness.os, 'statvfs', return_value=disk), patch.object(readiness.os, 'access', side_effect=AssertionError('root access must not determine controller permissions')):
                self.assertIn('disjoint', readiness.task_roots(request, policy))
                roots[0].chmod(0o500)
                with self.assertRaisesRegex(ValueError, 'controller lacks'):
                    readiness.task_roots(request, policy)
                roots[0].chmod(0o700)
                roots[0].rmdir()
                roots[0].symlink_to(roots[1], target_is_directory=True)
                with self.assertRaisesRegex(ValueError, 'canonical'):
                    readiness.task_roots(request, policy)
                roots[0].unlink()
                roots[0].mkdir()
                with self.assertRaisesRegex(ValueError, 'overlap'):
                    readiness.task_roots({**request, 'state_dir': request['workspace_root']}, policy)
                with self.assertRaises(FileNotFoundError):
                    readiness.task_roots({**request, 'state_dir': str(root / 'missing')}, policy)
                self.assertFalse((root / 'missing').exists())
                disk.f_bavail = minimum - 1
                with self.assertRaisesRegex(ValueError, 'insufficient'):
                    readiness.task_roots(request, policy)
                disk.f_bavail = minimum
                disk.f_flag = getattr(os, 'ST_RDONLY', 1)
                with self.assertRaisesRegex(ValueError, 'read-only'):
                    readiness.task_roots(request, policy)

    def test_image_readiness_does_not_require_unrelated_worker_cache(self):
        request, _ = inputs()
        with patch.object(readiness, 'command') as command:
            detail = readiness.image_inventory(request['sandbox'])
            self.assertIn('task pull and container launch not tested', detail)
            command.assert_not_called()
        with self.assertRaises(ValueError):
            readiness.image_inventory({**request['sandbox'], 'image': 'ubuntu:latest'})

    def test_runtime_missing_tools_worker_allocation_and_controllers_block(self):
        request, _ = inputs()
        worker = type('Worker', (), dict(pw_name='symphony-worker', pw_uid=1001))()
        def contents(path, *args, **kwargs):
            return {'/proc/sys/net/ipv4/ip_forward': '1', '/sys/fs/cgroup/cgroup.controllers': 'cpu memory pids',
                    '/etc/subuid': 'symphony-worker:165536:65536', '/etc/subgid': 'symphony-worker:165536:65536'}[str(path)]
        with patch.object(readiness.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(ValueError, 'missing runtime'):
                readiness.runtime_inventory(request['sandbox'])
        with patch.object(readiness.shutil, 'which', return_value='/usr/bin/true'), patch.object(readiness, 'protected'), patch.object(readiness, 'init_inventory'), patch.object(Path, 'read_text', contents), patch.object(readiness.os, 'access', return_value=True), patch.object(readiness.pwd, 'getpwnam', return_value=worker):
            self.assertIn('present', readiness.runtime_inventory(request['sandbox']))
            with patch.object(Path, 'read_text', return_value='cpu memory'):
                with self.assertRaisesRegex(ValueError, 'forwarding'):
                    readiness.runtime_inventory(request['sandbox'])
            with patch.object(readiness.pwd, 'getpwnam', return_value=type('Root', (), dict(pw_uid=0))()):
                with self.assertRaisesRegex(ValueError, 'non-root'):
                    readiness.runtime_inventory(request['sandbox'])
            with patch.object(readiness.os, 'access', return_value=False):
                with self.assertRaisesRegex(ValueError, 'cgroup'):
                    readiness.runtime_inventory(request['sandbox'])

    def test_toolchain_rejects_native_client_wrapper_before_version_execution(self):
        request, _ = inputs()
        with tempfile.TemporaryDirectory() as temporary:
            client = Path(temporary) / 'codex'
            client.write_text('#!/bin/sh\nexit 0\n')
            client.chmod(0o755)
            request['sandbox']['codex'] = str(client)
            with patch.object(readiness, 'protected', side_effect=lambda path, directory=False: Path(path)), patch.object(readiness, 'command') as command:
                with self.assertRaisesRegex(ValueError, 'native executable'):
                    readiness.toolchain_inventory(request['sandbox'])
                command.assert_not_called()

    def test_readonly_command_failure_and_version_mismatch_are_not_ready(self):
        for status, output in ((1, b''), (0, b'wrong version'), (0, b'x' * 65537)):
            response = subprocess.CompletedProcess(['binary'], status, output, b'')
            with patch.object(readiness.subprocess, 'run', return_value=response):
                with self.assertRaises(ValueError):
                    readiness.command(['/usr/bin/binary', '--version'], 'expected')

    def bridge_request(self, argv, policy):
        server, client = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        read_fd, write_fd = os.pipe()
        null = os.open(os.devnull, os.O_RDONLY)
        try:
            worker = threading.Thread(target=linux_bridge.serve_connection, args=(server, policy, Path('/must-not-run')))
            worker.start()
            client.sendmsg([json.dumps(argv).encode()], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [null, write_fd, write_fd]))])
            status = client.recv(16)
            worker.join(timeout=3)
            self.assertFalse(worker.is_alive())
            # Rejected identities leave the SCM_RIGHTS message unread. Closing
            # that socket releases its queued write descriptors before EOF.
            server.close()
            os.close(write_fd)
            write_fd = None
            output = os.read(read_fd, 65536)
            return status, output
        finally:
            for fd in (read_fd, write_fd, null):
                if fd is not None:
                    os.close(fd)
            server.close()
            client.close()

    def test_bridge_returns_complete_blocked_json_without_task_or_subprocess(self):
        request, policy = inputs()
        raw = json.dumps(request)
        report = {'status': 'blocked', 'blockers': [{'name': 'image', 'detail': 'image missing'}]}
        with patch.object(readiness, 'inspect_readiness', return_value=report), patch.object(linux_bridge, 'stage_inputs') as stage, patch.object(linux_bridge.subprocess, 'Popen') as process:
            status, output = self.bridge_request(['--readiness', raw], policy)
        self.assertEqual(status, b'0')
        self.assertEqual(json.loads(output), report)
        stage.assert_not_called()
        process.assert_not_called()

    def test_bridge_real_inventory_report_roundtrip_preserves_binding_and_failures(self):
        request, policy = inputs()
        raw = json.dumps(request, indent=2)
        with ExitStack() as stack:
            for name in ('task_roots', 'trusted_inventory', 'toolchain_inventory', 'runtime_inventory', 'image_inventory'):
                stack.enter_context(patch.object(readiness, name, return_value='present'))
            process = stack.enter_context(patch.object(linux_bridge.subprocess, 'Popen'))
            status, output = self.bridge_request(['--readiness', raw], policy)
            report = json.loads(output)
            self.assertEqual((status, report['status']), (b'0', 'ready'))
            self.assertEqual(report['request_sha256'], hashlib.sha256(raw.encode()).hexdigest())
            self.assertEqual({item['name'] for item in report['checks']}, {'task_roots', 'trusted_inventory', 'toolchain', 'runtime', 'image'})
            self.assertTrue(all(item['status'] == 'passed' for item in report['checks']))
            with patch.object(readiness, 'runtime_inventory', side_effect=ValueError('cgroup unavailable')):
                status, output = self.bridge_request(['--readiness', raw], policy)
            report = json.loads(output)
            self.assertEqual((status, report['status']), (b'0', 'blocked'))
            self.assertEqual(report['blockers'], [{'name': 'runtime', 'detail': 'cgroup unavailable'}])
            self.assertFalse(report['formal_acceptance'])
            process.assert_not_called()

    def test_bridge_rejects_invalid_request_and_unauthorized_identity(self):
        request, policy = inputs()
        report = {'status': 'blocked', 'blockers': [{'name': 'request', 'detail': 'policy mismatch'}]}
        with patch.object(readiness, 'inspect_readiness', return_value=report):
            status, output = self.bridge_request(['--readiness', json.dumps(request)], policy)
        self.assertEqual(status, b'125')
        self.assertEqual(json.loads(output), report)
        with patch.object(readiness, 'inspect_readiness') as inspect:
            status, output = self.bridge_request(['--readiness', json.dumps(request)], {**policy, 'uid': os.getuid() + 1})
        self.assertEqual(status, b'125')
        self.assertEqual(output, b'')
        inspect.assert_not_called()


if __name__ == '__main__':
    unittest.main()
