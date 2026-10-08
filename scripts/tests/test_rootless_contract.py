"""Failure preservation and host-boundary contracts, without requiring root privileges."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sandbox_artifacts as artifacts
import rootless_sandbox as sandbox
import runtime_identity
import linux_bridge
import install_rootless_bridge
import rootless_dns


class RootlessContractTest(unittest.TestCase):
    def test_dns_rejects_invalid_or_unbound_responses(self):
        query = b'\x12\x34\x01\x00' + b'\0' * 8
        for invalid in (b'', b'x' * 4097, b'\x12\x34\x81\x00' + b'\0' * 8):
            with self.assertRaises(ValueError):
                rootless_dns.resolve(invalid)
        with patch.object(rootless_dns.http.client, 'HTTPSConnection') as client:
            response = client.return_value.getresponse.return_value
            response.status = 200
            response.getheader.return_value = 'application/dns-message'
            response.read.return_value = b'\x12\x34\x81\x00' + b'\0' * 8
            self.assertEqual(rootless_dns.resolve(query), response.read.return_value)
            self.assertEqual(client.call_args.args, ('1.1.1.1',))
            client.return_value.close.assert_called_once()
            for invalid in (b'bad', b'\x12\x35\x81\x00' + b'\0' * 8, query, b'x' * 4097):
                response.read.return_value = invalid
                with self.assertRaises(ValueError):
                    rootless_dns.resolve(query)
            response.status = 500
            with self.assertRaises(ValueError):
                rootless_dns.resolve(query)

    def test_installation_removes_inherited_write_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / 'trusted/scripts'
            scripts.mkdir(parents=True)
            code, wrapper = scripts / 'bridge.py', scripts / 'execution_sandbox.sh'
            code.write_text('pass')
            wrapper.write_text('#!/bin/bash\n')
            scripts.chmod(0o775)
            code.chmod(0o664)
            wrapper.chmod(0o775)
            install_rootless_bridge.protect_installation(root)
            self.assertEqual(scripts.stat().st_mode & 0o777, 0o755)
            self.assertEqual(code.stat().st_mode & 0o777, 0o644)
            self.assertEqual(wrapper.stat().st_mode & 0o777, 0o755)

    def test_installed_payload_contains_formatter_and_loads_fixed_runner(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary)
            source = Path(__file__).resolve().parents[1]
            install_rootless_bridge.copy_check_payload(source, target)
            self.assertEqual((target / 'check_formatter.exs').read_bytes(), (source / 'check_formatter.exs').read_bytes())
            self.assertEqual((target / 'check_formatter.exs').stat().st_mode & 0o777, 0o644)
            code = "import sys;sys.path.insert(0,sys.argv[1]);import check_results;print(check_results._runner_digest());print(check_results.FORMATTER.read_text()[:9])"
            result = subprocess.run([sys.executable, '-I', '-S', '-c', code, str(target)], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines()[1], 'defmodule')
            self.assertEqual(len(result.stdout.splitlines()[0]), 64)

    def test_bridge_accepts_only_exact_view_runner_and_candidate_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workspace, evidence, scratch = root / 'workspaces/task', root / 'state/receipt.evidence', root / 'sandboxes/run-1-2/sandbox'
            for path in (workspace, evidence / 'baseline', scratch.parent):
                path.mkdir(parents=True)
            fixed = {'--toolchain': '/trusted/toolchain', '--codex': '/trusted/codex', '--trusted-root': '/trusted/runtime',
                     '--dependencies': '/trusted/deps', '--memory-mb': '4096', '--disk-mb': '20480', '--pids': '512', '--cpus': '4'}
            rootless = {'--backend': 'rootless', '--image': 'image@sha256:' + 'a' * 64, '--worker': 'worker'}
            fields = dict(fixed, **rootless, **{'--workspace': str(workspace), '--evidence': str(evidence), '--baseline': str(evidence / 'baseline'),
                          '--scratch-root': str(scratch), '--timeout-seconds': '60', '--environment-recipe': ''})
            prefix = [item for pair in fields.items() for item in pair] + ['--']
            policy = dict(fixed=fixed, rootless=rootless, workspaces=str(root / 'workspaces'), state=str(root / 'state'), sandboxes=str(root / 'sandboxes'))
            command = ['/opt/toolchain/view-validation/python/bin/python', '-I', '-B', '/opt/symphony/scripts/check_view_isolated.py', '--candidate-sha', 'b' * 40]
            self.assertEqual(linux_bridge.validate(prefix + command, policy), scratch)
            changes = [command + ['--arbitrary'], command[:-1] + ['invalid'], ['python3', *command[1:]],
                       [*command[:3], '/workspace/check_view_isolated.py', *command[4:]],
                       [command[0], '-c', 'print(1)']]
            for changed in changes:
                with self.subTest(changed=changed), self.assertRaises(ValueError):
                    linux_bridge.validate(prefix + changed, policy)

    def test_view_stage_detaches_egress_and_uses_formal_environment(self):
        argv = ['/opt/toolchain/view-validation/python/bin/python', '-I', '-B', '/opt/symphony/scripts/check_view_isolated.py', '--candidate-sha', 'b' * 40]
        calls = []
        self.assertTrue(sandbox.formal_check(argv))
        self.assertTrue(sandbox.detach_view_network(argv, 'sn12345678', 'sp12345678', calls.append))
        self.assertEqual(calls, [['ip', '-n', 'sn12345678', 'link', 'delete', 'sp12345678']])
        calls.clear()
        self.assertFalse(sandbox.detach_view_network(['/opt/codex', 'exec-server'], 'sn12345678', 'sp12345678', calls.append))
        self.assertEqual(calls, [])

    def test_prepared_image_accepts_both_podman_id_forms(self):
        for output in ('a' * 64 + '\n', 'sha256:' + 'a' * 64 + '\n'):
            self.assertEqual(sandbox.image_identity(output), 'sha256:' + 'a' * 64)
        for output in ('', 'short', 'A' * 64, 'image:latest', 'a' * 64 + '\nextra'):
            with self.assertRaises(ValueError):
                sandbox.image_identity(output)

    def test_forwarding_exceptions_are_scoped_and_do_not_change_policy(self):
        rules = sandbox.forwarding_rules('sh1234abcd')
        self.assertEqual(rules[0], ['-i', 'sh1234abcd', '-j', 'ACCEPT'])
        self.assertIn('ESTABLISHED,RELATED', rules[1])
        self.assertNotIn('NEW', rules[1])
        for invalid in ('sh+', 'eth0', 'sh1234abcd -j ACCEPT'):
            with self.assertRaises(ValueError):
                sandbox.forwarding_rules(invalid)
        self.assertIn('hook forward priority -20', sandbox.network_rules('sy1234abcd', 'sh1234abcd'))

    def test_public_policy_rejects_private_metadata_and_all_ipv6(self):
        for address in ('127.0.0.1', '10.0.0.1', '172.16.3.1', '192.168.1.1', '169.254.169.254', '100.64.0.2', '::1', 'fd00::1', '2606:4700:4700::1111'):
            self.assertFalse(sandbox.public_destination(address), address)
        self.assertTrue(sandbox.public_destination('1.1.1.1'))
        rules = sandbox.network_rules('sy1234abcd', 'sh1234abcd')
        self.assertIn('meta nfproto ipv6 drop', rules)
        self.assertIn('iifname "sh1234abcd" drop', rules)
        self.assertIn('ct state established,related', rules)
        for table, interface in [('bad', 'sh1234abcd'), ('sy1234abcd', 'x"; accept')]:
            with self.assertRaises(ValueError):
                sandbox.network_rules(table, interface)

    def test_successful_export_hashes_modes_and_excludes_controller_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source'
            source.mkdir()
            (source / 'run.sh').write_bytes(b'hello')
            (source / 'run.sh').chmod(0o751)
            (source / '.git').mkdir()
            (source / '.git/config').write_text('controller credential')
            result = artifacts.export_source(source, root / 'export', 100)
            self.assertTrue(result['export_complete'])
            self.assertEqual(result['files']['run.sh'], dict(sha256=hashlib.sha256(b'hello').hexdigest(), size=5, mode=0o751))
            self.assertFalse((root / 'export/.git').exists())
            self.assertEqual(json.loads((root / 'export-report.json').read_text()), result)

    def test_symlink_special_and_size_rejection_retain_regular_work(self):
        for failure in ('symlink', 'special_file', 'size_limit'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = root / 'source'
                source.mkdir()
                (source / 'a.txt').write_text('keep')
                if failure == 'symlink':
                    (source / 'z.txt').symlink_to('/etc/passwd')
                elif failure == 'special_file':
                    os.mkfifo(source / 'z.txt')
                else:
                    (source / 'z.txt').write_text('oversized')
                result = artifacts.export_source(source, root / 'export', 4)
                self.assertFalse(result['export_complete'])
                self.assertEqual(result['rejected'][0]['reason'], failure)
                self.assertEqual((root / '.export-pending/a.txt').read_text(), 'keep')
                self.assertTrue((source / 'a.txt').exists())

    def test_export_io_error_retains_original_and_structured_reason(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'source').mkdir()
            (root / 'source/a').write_text('keep')
            with patch.object(artifacts.os, 'rename', side_effect=OSError('disk I/O failure')):
                result = artifacts.export_source(root / 'source', root / 'export', 100)
            self.assertFalse(result['export_complete'])
            self.assertEqual(result['rejected'][0]['reason'], 'OSError')
            self.assertTrue((root / '.export-pending/a').is_file())

    def test_native_identity_never_accepts_path_wrapper(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'codex'
            path.write_text('#!/bin/sh\necho codex-cli 0.160.0\n')
            path.chmod(0o755)
            with self.assertRaises(ValueError):
                runtime_identity.native_client(path)

    def test_worker_traversal_changes_only_the_private_bridge_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workspace, evidence = root / 'workspace', root / 'evidence'
            workspace.mkdir(mode=0o700)
            evidence.mkdir(mode=0o700)
            (evidence / 'private.txt').write_text('controlled evidence')
            (evidence / 'private.txt').chmod(0o600)
            argv = ['--workspace', str(workspace), '--evidence', str(evidence), '--baseline', str(evidence / 'baseline'), '--scratch-root', str(root / 'sandbox'), '--', '/opt/codex']
            stage, _ = linux_bridge.stage_inputs(argv, root / 'sandbox', 1000)
            try:
                self.assertEqual(stage.stat().st_mode & 0o777, 0o711)
                self.assertEqual((stage / 'workspace').stat().st_mode & 0o777, 0o711)
                self.assertEqual((stage / 'evidence/private.txt').stat().st_mode & 0o777, 0o444)
                self.assertEqual((evidence / 'private.txt').stat().st_mode & 0o777, 0o600)
            finally:
                import shutil
                (stage / 'evidence').chmod(0o700)
                shutil.rmtree(stage)

    def test_failed_publication_retains_persistent_disk(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            staged = root / 'stage'
            (staged / 'scratch').mkdir(parents=True)
            (staged / 'scratch/work.img').write_text('persistent source')
            artifacts.save_json(staged / 'scratch/result.json', dict(cleanup_complete=True, scratch_root=str(staged / 'scratch'), source_volume=str(staged / 'scratch/work.img')))
            with patch.object(linux_bridge, 'transfer_ownership', side_effect=OSError('ownership failed')):
                with self.assertRaises(OSError):
                    linux_bridge.publish_results(staged, root / 'sandbox', os.getuid(), os.getgid())
            preserved = list(root.glob('.sandbox-bridge-*/work.img'))
            self.assertEqual(len(preserved), 1)
            self.assertEqual(preserved[0].read_text(), 'persistent source')

    def test_successful_publication_rebinds_proof_without_copying_disk(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            staged = root / 'stage'
            (staged / 'scratch').mkdir(parents=True)
            disk = staged / 'scratch/work.img'
            disk.write_text('persistent source')
            inode = disk.stat().st_ino
            artifacts.save_json(staged / 'scratch/result.json', dict(cleanup_complete=True, scratch_root=str(staged / 'scratch'), source_volume=str(disk)))
            self.assertTrue(linux_bridge.publish_results(staged, root / 'sandbox', os.getuid(), os.getgid()))
            self.assertEqual((root / 'sandbox/work.img').stat().st_ino, inode)
            result = json.loads((root / 'sandbox/result.json').read_text())
            self.assertEqual(result['source_volume'], str(root / 'sandbox/work.img'))

    def test_output_limit_and_deadline_return_failure(self):
        for limit, seconds, expected in [(0, 5, 125), (100, -1, 124)]:
            process = subprocess.Popen([sys.executable, '-c', 'import time;print("output",flush=True);time.sleep(2)'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                self.assertEqual(sandbox.relay(process, time.monotonic() + seconds, limit), expected)
            finally:
                process.kill()
                process.wait()
                process.stdout.close()
                process.stderr.close()


if __name__ == '__main__':
    unittest.main()
