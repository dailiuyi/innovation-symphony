"""VM tooling regressions: temporary files and mocked external operations only."""
import hashlib
from contextlib import closing, contextmanager
import io
import json
import os
from pathlib import Path
import sqlite3
import shlex
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vm import operations as vm
from vm import guest
from vm import artifacts
import runtime_identity


class VmOperationsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / 'vm'
        self.root.mkdir()
        image = b'ubuntu-image-fixture'
        self.image_hash = hashlib.sha256(image).hexdigest()
        self.data = dict(vm_uuid=str(uuid.uuid4()), image_sha256=self.image_hash,
                         vcpus=8, memory_mib=12288, disk_gib=50)
        (self.root / 'deployment.json').write_text(json.dumps(self.data))
        (self.root / 'noble-server-cloudimg-amd64.img').write_bytes(image)
        (self.root / 'SHA256SUMS').write_text(self.image_hash + ' *noble-server-cloudimg-amd64.img\n')
        for name in ('SHA256SUMS.gpg', 'seed.img', 'system.qcow2', 'user-data', 'meta-data', 'ssh_ed25519'):
            (self.root / name).write_bytes(b'fixture')
        (self.root / 'ssh_ed25519').chmod(0o600)
        (self.root / 'ssh_ed25519.pub').write_text('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIguest comment\n')
        self.info = json.dumps({'format': 'qcow2', 'virtual-size': 50 * vm.GIB}).encode()

    def settings(self):
        settings = guest.default_settings()
        settings.update(runtime_root=str(self.base / 'runtime'), config_root=str(self.base / 'config'),
                        view_root=str(self.base / 'config/view'), release_root=str(self.base / 'release'),
                        state_dir=str(self.base / 'runtime/state'), workflow=str(self.base / 'config/WORKFLOW.md'),
                        model_settings=str(self.base / 'config/model-settings.json'),
                        view_config=str(self.base / 'config/view.toml'), view_venv=str(self.base / 'config/view-venv'),
                        environment_file=str(self.base / 'config/runtime.env'), credential_inventory_reviewed=True)
        settings['auth_paths'] = [settings['environment_file']]
        for key in ('runtime_root', 'config_root', 'view_root', 'release_root', 'state_dir'):
            Path(settings[key]).mkdir(parents=True, exist_ok=True)
        Path(settings['workflow']).write_bytes(b'---\nserver:\n  host: 127.0.0.1\nmvp:\n  enabled: true # retain in-flight\n  state_dir: ' +
                                               settings['state_dir'].encode() + b'\n---\nRun instructions\n')
        return settings

    def test_qemu_resources_nat_no_shares_and_normal_reboot(self):
        argv = vm.qemu_command(self.root)
        text = ' '.join(argv)
        self.assertIn('q35,accel=kvm', text)
        self.assertEqual(argv[argv.index('-smp') + 1], '8')
        self.assertEqual(argv[argv.index('-m') + 1], '12288')
        self.assertIn('hostfwd=tcp:127.0.0.1:22220-:22', text)
        self.assertNotIn('-no-reboot', argv)
        for forbidden in ('-virtfs', '-fsdev', '-chardev', '-daemonize'):
            self.assertNotIn(forbidden, argv)

    def test_ssh_dedicated_identity_no_agent_strict_hosts_and_tunnels(self):
        for mode, ports in vm.PORTS.items():
            argv = vm.ssh_command(self.root, tunnels=mode)
            text = ' '.join(argv)
            for option in ('IdentityAgent=none', 'ForwardAgent=no', 'IdentitiesOnly=yes',
                           'BatchMode=yes', 'StrictHostKeyChecking=yes', 'ExitOnForwardFailure=yes'):
                self.assertIn(option, argv)
            self.assertIn(str(self.root / 'ssh_ed25519'), argv)
            for host, port in zip(ports, vm.PORTS['production']):
                self.assertIn(f'127.0.0.1:{host}:127.0.0.1:{port}', text)
        argv = vm.ssh_command(self.root, ['printf', 'literal; value'])
        self.assertTrue(argv[-1].endswith("'literal; value'"))

    def test_units_leave_qemu_alive_and_have_lifetime_lock_and_daily_timer(self):
        units = vm.host_units(self.root, self.data)
        unit = units[vm.UNIT]
        for field in ('KillMode=none', 'SendSIGKILL=no', 'TimeoutStopSec=infinity',
                      'Restart=on-failure', '/usr/bin/flock', '--no-fork'):
            self.assertIn(field, unit)
        self.assertIn('OnCalendar=', units['symphony-vm-backup.timer'])
        self.assertIn('daily-backup', units['symphony-vm-backup.service'])

    def test_adopt_dry_run_no_writes_and_apply_preserves_originals(self):
        before = {p.name: p.read_bytes() for p in self.root.iterdir()}
        with patch.object(vm, 'run', return_value=self.info):
            result = vm.adopt(self.root, external=True)
            self.assertFalse(result['applied'])
            self.assertEqual(before, {p.name: p.read_bytes() for p in self.root.iterdir()})
            vm.adopt(self.root, apply=True, external=True)
        self.assertEqual(before, {name: (self.root / name).read_bytes() for name in before})
        self.assertTrue((self.root / 'generated/host/symphony-vm.service').is_file())
        self.assertTrue((self.root / 'generated/guest/vm-operations.example.json').is_file())
        with self.assertRaises(FileExistsError):
            vm.adopt(self.root, apply=True, external=True)

    def test_adopt_rejects_backing_disk_or_unapproved_resource(self):
        with patch.object(vm, 'run', return_value=json.dumps({'format': 'qcow2', 'virtual-size': 50 * vm.GIB,
                                                             'backing-filename': '/host/live'}).encode()):
            with self.assertRaisesRegex(ValueError, 'standalone'):
                vm.adopt(self.root, external=True)
        self.data['vcpus'] = 4
        (self.root / 'deployment.json').write_text(json.dumps(self.data))
        with self.assertRaisesRegex(ValueError, 'vcpus'):
            vm.deployment(self.root)

    def test_signature_requires_explicit_attestation_or_trusted_signer(self):
        with self.assertRaisesRegex(ValueError, 'trusted Ubuntu'):
            vm.verify_image(self.root, self.image_hash)
        fingerprint = 'A' * 40
        with patch.object(vm, 'run', return_value=f'[GNUPG:] VALIDSIG {fingerprint} 2026 1 0 4 0 1 8 00 {fingerprint}\n'.encode()):
            self.assertEqual(vm.verify_image(self.root, self.image_hash, keyring='/trusted/keyring', signer=fingerprint),
                             'gpgv:' + fingerprint)
            with self.assertRaisesRegex(ValueError, 'independently trusted'):
                vm.verify_image(self.root, self.image_hash, keyring='/trusted/keyring', signer='B' * 40)
        (self.root / 'noble-server-cloudimg-amd64.img').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            vm.verify_image(self.root, self.image_hash, external=True)

    def test_prepare_dry_run_and_existing_vm_refusal(self):
        target = self.base / 'new-vm'
        with patch.object(vm.shutil, 'disk_usage', return_value=Mock(free=30 * vm.GIB)), patch.object(vm, 'run') as run:
            self.assertFalse(vm.prepare(target, self.root, external=True)['applied'])
            self.assertFalse(target.exists())
            run.assert_not_called()
        with self.assertRaises(FileExistsError):
            vm.prepare(self.root, self.root, apply=True, external=True)

    def test_cloud_seed_has_public_key_only_no_password_or_runtime_credentials(self):
        seed, meta = vm.cloud_init((self.root / 'ssh_ed25519.pub').read_text(), self.data['vm_uuid'])
        self.assertIn('name: elma', seed)
        self.assertIn('NOPASSWD:ALL', seed)
        self.assertIn('lock_passwd: true', seed)
        self.assertNotIn('comment', seed)
        self.assertNotIn('fixture', seed)
        self.assertIn(self.data['vm_uuid'], meta)
        with self.assertRaises(ValueError):
            vm.cloud_init('-----BEGIN OPENSSH PRIVATE KEY-----', self.data['vm_uuid'])

    def test_stop_timeout_only_normal_shutdown_no_signal(self):
        with patch.object(vm, 'qmp_running', return_value=True), patch.object(vm, 'run', return_value=b'{}') as run, \
             patch.object(vm.time, 'monotonic', side_effect=[0, 0, 10]), patch.object(vm.time, 'sleep'):
            with self.assertRaisesRegex(TimeoutError, 'LEFT RUNNING'):
                vm.stop(self.root, apply=True, timeout=2)
        self.assertEqual(run.call_count, 1)
        argv = run.call_args.args[0]
        self.assertEqual(argv[0], '/usr/bin/ssh')
        self.assertIn('shutdown', argv[-1])
        self.assertNotIn('kill', str(argv))

    def test_start_readonly_and_duplicate_refusal(self):
        with patch.object(vm, 'qmp_running', return_value=False), patch.object(vm, 'launch_check') as launch, \
             patch.object(vm, 'run') as run:
            self.assertFalse(vm.start(self.root)['applied'])
            launch.assert_not_called()
            run.assert_not_called()
        with patch.object(vm, 'qmp_running', return_value=True), self.assertRaisesRegex(ValueError, 'duplicate'):
            vm.start(self.root, apply=True)

    def test_guest_disk_pause_marker_never_rewrites_workflow_and_guard_returns_success(self):
        settings = self.settings()
        original = Path(settings['workflow']).read_bytes()
        with patch.object(guest.shutil, 'disk_usage', return_value=Mock(free=guest.FLOOR - 1)):
            self.assertTrue(guest.check(settings)['admission_paused'])
            self.assertFalse(guest.pause_path(settings).exists())
            result = guest.check(settings, apply=True)
        self.assertTrue(result['admission_paused'])
        self.assertTrue(guest.pause_path(settings).exists())
        self.assertEqual(original, Path(settings['workflow']).read_bytes())
        with patch.object(guest.shutil, 'disk_usage', return_value=Mock(free=guest.FLOOR + 1)):
            self.assertTrue(guest.check(settings)['admission_paused'])

    def test_host_floor_marker_propagates_without_stopping_services(self):
        with patch.object(vm.shutil, 'disk_usage', return_value=Mock(free=vm.GIB)), \
             patch.object(vm, 'run', return_value=b'{"admission_paused":true}') as run:
            result = vm.check(self.root, apply=True)
        self.assertTrue(result['host_paused'])
        self.assertTrue((self.root / 'admission-paused').exists())
        self.assertIn('--host-paused', run.call_args.args[0][-1])
        self.assertNotIn('stop', run.call_args.args[0][-1])

    def test_stopped_services_allow_known_absence_but_refuse_unknown_and_busy(self):
        for load, active in (('not-found', 'inactive'), ('loaded', 'inactive')):
            with patch.object(guest, 'command', return_value=f'LoadState={load}\nActiveState={active}\nControlGroup=\n'), \
                 patch.object(guest.socket, 'socket'):
                guest.require_stopped()
        for raw in ('LoadState=error\nActiveState=inactive\n', 'LoadState=loaded\nActiveState=active\n'):
            with patch.object(guest, 'command', return_value=raw), self.assertRaises(ValueError):
                guest.require_stopped()

    def backup_settings(self, json_workflow=False):
        settings = self.settings()
        if json_workflow:
            Path(settings['workflow']).write_text('---\n' + json.dumps({'mvp': {'enabled': True, 'state_dir': settings['state_dir']}}) + '\n---\nTask body\n')
        runtime = Path(settings['runtime_root'])
        (runtime / 'migration-backups').mkdir()
        (runtime / 'migration-backups/important.receipt').write_bytes(b'original migration evidence')
        (runtime / 'active-recovery.json').write_bytes(b'keep candidate recovery')
        (runtime / 'codex-home').mkdir()
        (runtime / 'codex-home/auth.json').write_bytes(b'MUST NOT BACK UP AUTH')
        Path(settings['environment_file']).write_bytes(b'MUST NOT BACK UP ENV')
        database = Path(settings['view_root']) / 'board.sqlite'
        connection = sqlite3.connect(database)
        self.addCleanup(connection.close)
        connection.execute('PRAGMA journal_mode=WAL')
        connection.execute('CREATE TABLE evidence(value TEXT)')
        connection.execute("INSERT INTO evidence VALUES ('committed WAL data')")
        connection.commit()
        database.chmod(0o600)
        return settings

    def create_backup(self, json_workflow=False):
        settings = self.backup_settings(json_workflow)
        guest.pause(settings, 'test maintenance')
        guest.request_maintenance(settings, 'test maintenance')
        stream = io.BytesIO()
        with patch.object(guest, 'require_stopped'):
            guest.backup(settings, stream)
        return settings, stream.getvalue()

    def test_sqlite_backup_wal_config_runtime_view_auth_exclusion_and_independent_restore(self):
        settings, content = self.create_backup()
        with tarfile.open(fileobj=io.BytesIO(content)) as archive:
            names = archive.getnames()
            self.assertIn('config/WORKFLOW.md', names)
            self.assertIn('view/board.sqlite', names)
            self.assertIn('runtime/migration-backups/important.receipt', names)
            self.assertNotIn('runtime/codex-home/auth.json', names)
            self.assertNotIn('config/runtime.env', names)
            self.assertNotIn('view/board.sqlite-wal', names)
        self.assertNotIn(b'MUST NOT BACK UP', content)
        original = Path(settings['workflow']).read_bytes()
        target = self.base / 'restored'
        result = guest.restore(io.BytesIO(content), target, settings)
        self.assertEqual(result['intake'], 'disabled')
        self.assertFalse(result['activated'])
        self.assertEqual(Path(settings['workflow']).read_bytes(), original)
        self.assertIn(b'enabled: false', (target / 'config/WORKFLOW.md').read_bytes())
        self.assertTrue((target / 'runtime/state/intake-paused').exists())
        self.assertEqual((target / 'runtime/active-recovery.json').read_bytes(), b'keep candidate recovery')
        with closing(sqlite3.connect(target / 'view/board.sqlite')) as db:
            self.assertEqual(db.execute('SELECT value FROM evidence').fetchone()[0], 'committed WAL data')
        for existing in (target, Path(settings['runtime_root'])):
            with self.assertRaises((ValueError, FileExistsError)):
                guest.restore(io.BytesIO(content), existing, settings)

    def test_backup_requires_marker_quiescence_and_reviewed_auth_inventory(self):
        settings = self.settings()
        with self.assertRaisesRegex(ValueError, 'intake-paused'):
            guest.backup(settings, io.BytesIO())
        guest.pause(settings, 'pause')
        with self.assertRaises(FileNotFoundError):
            guest.backup(settings, io.BytesIO())
        guest.request_maintenance(settings, 'pause')
        with patch.object(guest, 'require_stopped', side_effect=ValueError('busy')), self.assertRaisesRegex(ValueError, 'busy'):
            guest.backup(settings, io.BytesIO())
        settings['credential_inventory_reviewed'] = False
        with patch.object(guest, 'require_stopped'), self.assertRaisesRegex(ValueError, 'credential'):
            guest.backup(settings, io.BytesIO())

    def test_restore_rejects_traversal_devices_and_corrupt_hash(self):
        settings = self.settings()
        for name, kind in (('../escape', tarfile.REGTYPE), ('device', tarfile.CHRTYPE)):
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode='w') as archive:
                info = tarfile.TarInfo(name)
                info.type = kind
                archive.addfile(info)
            with self.assertRaises(ValueError):
                guest.restore(io.BytesIO(stream.getvalue()), self.base / ('reject-' + uuid.uuid4().hex), settings)
        settings, content = self.create_backup()
        changed = content.replace(b'keep candidate recovery', b'fake candidate recovery')
        with tarfile.open(fileobj=io.BytesIO(changed)) as archive, self.assertRaisesRegex(ValueError, 'hash'):
            guest.read_archive(archive)

    def test_daily_backup_restarts_only_prior_active_services_and_preserves_workflow(self):
        settings = self.settings()
        original = Path(settings['workflow']).read_bytes()
        calls = []
        def command(argv):
            calls.append(argv)
            if '--property=LoadState,ActiveState' in argv:
                return 'LoadState=loaded\nActiveState=' + ('inactive' if argv[2] == guest.SERVICES[2] else 'active') + '\n'
            return ''
        with patch.object(guest, 'command', side_effect=command), patch.object(guest, 'require_idle'), \
             patch.object(guest, 'backup'), patch.object(guest, 'wait_healthy'), \
             patch.object(guest.shutil, 'disk_usage', return_value=Mock(free=guest.FLOOR + 1)):
            guest.daily_backup(settings, io.BytesIO())
        starts = [argv[-1] for argv in calls if 'start' in argv]
        self.assertEqual(starts, list(guest.SERVICES[:2]))
        self.assertNotIn(guest.SERVICES[2], starts)
        self.assertFalse(guest.pause_path(settings).exists())
        self.assertEqual(original, Path(settings['workflow']).read_bytes())

    def test_daily_failure_restarts_and_keeps_pause_busy_does_not_stop(self):
        settings = self.settings()
        calls = []
        def command(argv):
            calls.append(argv)
            return 'LoadState=loaded\nActiveState=active\n' if '--property=LoadState,ActiveState' in argv else ''
        with patch.object(guest, 'command', side_effect=command), patch.object(guest, 'require_idle'), \
             patch.object(guest, 'backup', side_effect=OSError('full disk')), patch.object(guest, 'wait_healthy'):
            with self.assertRaises(OSError):
                guest.daily_backup(settings, io.BytesIO())
        self.assertTrue(guest.pause_path(settings).exists())
        self.assertEqual(len([c for c in calls if 'start' in c]), 3)
        calls.clear()
        with patch.object(guest, 'command', side_effect=command), \
             patch.object(guest, 'require_idle', side_effect=guest.MaintenanceBusy('busy')), self.assertRaisesRegex(ValueError, 'busy'):
            guest.daily_backup(settings, io.BytesIO())
        self.assertFalse(any('stop' in c or 'start' in c for c in calls))

    def test_daily_rotation_only_owned_successes_never_migration_or_partial(self):
        directory = self.root / 'backups'
        directory.mkdir()
        for index in range(5):
            path = directory / f'daily-20261020T03000{index}000000Z-{uuid.uuid4().hex}.tar'
            path.write_bytes(f'archive{index}'.encode())
            path.with_name(path.name + '.success.json').write_text(json.dumps({
                'kind': 'symphony-vm-daily-backup', 'vm_uuid': self.data['vm_uuid'],
                'archive': path.name, 'sha256': vm.sha256(path)}))
        (directory / 'migration-backup.tar').write_bytes(b'preserve')
        (directory / 'failed.tar.partial').write_bytes(b'preserve')
        candidates = vm.rotation_candidates(directory, self.data['vm_uuid'])
        self.assertEqual(len(candidates), 2)
        self.assertTrue(all(a.name.startswith('daily-') for a, _ in candidates))
        before = set(directory.iterdir())
        vm.daily_backup(self.root)
        self.assertEqual(set(directory.iterdir()), before)

    def test_daily_apply_rotates_after_verified_success_and_preserves_migration(self):
        directory = self.root / 'backups'
        directory.mkdir()
        migration = directory / 'migration-backup.tar'
        migration.write_bytes(b'original')
        for index in range(4):
            path = directory / f'daily-20261019T03000{index}000000Z-{uuid.uuid4().hex}.tar'
            path.write_bytes(b'old-backup')
            path.with_name(path.name + '.success.json').write_text(json.dumps({
                'kind': 'symphony-vm-daily-backup', 'vm_uuid': self.data['vm_uuid'],
                'archive': path.name, 'sha256': vm.sha256(path)}))
        def backup(root, destination, **kwargs):
            destination.write_bytes(b'new-verified-backup')
            return {'backup': str(destination), 'sha256': vm.sha256(destination)}
        with patch.object(vm, 'backup', side_effect=backup):
            result = vm.daily_backup(self.root, apply=True)
        self.assertEqual(len(result['rotated']), 4)
        self.assertEqual(len(list(directory.glob('daily-*.tar'))), 3)
        self.assertEqual(migration.read_bytes(), b'original')

    def test_backup_transport_failure_retains_partial_and_never_publishes_success(self):
        destination = self.base / 'failed-backup.tar'
        def transport(argv, **kwargs):
            kwargs['stdout'].write(b'partial archive')
            return Mock(returncode=1)
        with patch.object(vm.shutil, 'disk_usage', return_value=Mock(free=30 * vm.GIB)), \
             patch.object(vm.subprocess, 'run', side_effect=transport):
            with self.assertRaisesRegex(RuntimeError, 'partial retained'):
                vm.backup(self.root, destination, apply=True)
        self.assertFalse(destination.exists())
        self.assertEqual(destination.with_name(destination.name + '.partial').read_bytes(), b'partial archive')

    def test_maintenance_locks_refuse_concurrent_operations(self):
        settings = self.settings()
        with guest.maintenance(settings):
            with self.assertRaises(BlockingIOError):
                with guest.maintenance(settings):
                    self.fail('second guest maintenance lock acquired')
        with vm.operation_lock(self.root):
            with self.assertRaises(BlockingIOError):
                with vm.operation_lock(self.root):
                    self.fail('second host operation lock acquired')

    def test_stop_callback_does_not_reacquire_public_cli_lock(self):
        with patch.object(vm, 'operation_lock') as lock, patch.object(vm, 'stop', return_value={'qemu': 'not_running'}), \
             patch('builtins.print'):
            vm.main(['--root', str(self.root), 'guest-poweroff', '--apply'])
        lock.assert_not_called()

    def test_daily_restart_failure_attempts_all_original_services_and_keeps_pause(self):
        settings = self.settings()
        starts = []
        def command(argv):
            if '--property=LoadState,ActiveState' in argv:
                return 'LoadState=loaded\nActiveState=active\n'
            if 'start' in argv:
                starts.append(argv[-1])
                if argv[-1] == guest.SERVICES[0]:
                    raise RuntimeError('restart refused')
            return ''
        with patch.object(guest, 'command', side_effect=command), patch.object(guest, 'require_idle'), \
             patch.object(guest, 'backup'), self.assertRaisesRegex(RuntimeError, 'restart failed'):
            guest.daily_backup(settings, io.BytesIO())
        self.assertEqual(starts, list(guest.SERVICES))
        self.assertTrue(guest.pause_path(settings).exists())

    def test_guest_native_units_paths_and_tmpfiles_exclusion(self):
        units = guest.units()
        for service in guest.SERVICES:
            self.assertIn('User=elma', units[service])
            self.assertIn('/var/lib/innovation-symphony/runtime-paths.env', units[service])
            self.assertNotIn('/opt/symphony-toolchain', units[service])
        self.assertIn('/var/lib/innovation-symphony/view-venv/bin/python', units[guest.SERVICES[2]])
        self.assertIn('PATH=/usr/local/bin:/usr/bin:/bin', units['runtime-paths.env'])
        self.assertIn('x /var/tmp/innovation-symphony-linux-runtime', units['symphony-runtime.conf'])

    def test_artifacts_pin_all_versions_and_checksum_no_latest(self):
        data = {}
        for name, version in artifacts.VERSIONS.items():
            source = self.base / (name + '.tar')
            source.write_bytes(name.encode())
            data[name] = {'version': version, 'path': str(source), 'sha256': artifacts.digest(source),
                          'provenance': 'operator verified signed upstream release'}
        data['codex']['entry'] = 'vendor/x86_64/codex/codex'
        with tarfile.open(data['codex']['path'], 'w') as archive:
            info = tarfile.TarInfo('package/' + data['codex']['entry'])
            info.size, info.mode = 6, 0o755
            archive.addfile(info, io.BytesIO(b'codex!'))
        data['codex']['sha256'] = artifacts.digest(data['codex']['path'])
        manifest = self.base / 'artifacts.json'
        manifest.write_text(json.dumps(data))
        self.assertEqual(artifacts.verified_manifest(manifest)['otp']['version'], '28.5.0.7')
        data['node']['version'] = 'latest'
        manifest.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'exact pinned'):
            artifacts.verified_manifest(manifest)



    def rewrite_manifest(self, content, change):
        output = io.BytesIO()
        with tarfile.open(fileobj=io.BytesIO(content)) as source, tarfile.open(fileobj=output, mode='w') as target:
            for info in source:
                body = source.extractfile(info).read() if info.isfile() else None
                if info.name == guest.MANIFEST:
                    data = json.loads(body)
                    change(data)
                    body = json.dumps(data).encode()
                    info.size = len(body)
                target.addfile(info, io.BytesIO(body) if body is not None else None)
        return output.getvalue()

    def test_settings_bind_actual_workflow_state_before_any_marker_or_stop(self):
        settings = self.settings()
        wrong = Path(settings['runtime_root']) / 'wrong-state'
        wrong.mkdir()
        wrong_settings = {**settings, 'state_dir': str(wrong)}
        for operation in (lambda: guest.pause(wrong_settings, 'wrong'),
                          lambda: guest.request_maintenance(wrong_settings, 'wrong'),
                          lambda: guest.daily_backup(wrong_settings, io.BytesIO()),
                          lambda: guest.shutdown(wrong_settings)):
            with patch.object(guest, 'command') as command, self.assertRaisesRegex(ValueError, 'actual WORKFLOW'):
                operation()
            command.assert_not_called()
        self.assertEqual(list(wrong.iterdir()), [])
        self.assertFalse(guest.pause_path(settings).exists())

    def test_yaml_and_json_workflow_parse_state_and_disable_reject_ambiguity(self):
        settings = self.settings()
        actual = settings['state_dir']
        for quoted in (actual, '"' + actual + '"', "'" + actual + "'"):
            content = ('---\nmvp:\n  enabled: true # comment\n  state_dir: ' + quoted + '\n---\nBody\n').encode()
            self.assertEqual(guest.workflow_config(content)['state_dir'], actual)
            changed, old = guest.workflow_edit(content, False)
            self.assertTrue(old)
            self.assertFalse(guest.workflow_config(changed)['enabled'])
        content = ('---\n' + json.dumps({'mvp': {'enabled': True, 'state_dir': actual}}) + '\n---\nBody\n').encode()
        self.assertEqual(guest.workflow_config(content)['state_dir'], actual)
        changed, _ = guest.workflow_edit(content, False)
        self.assertFalse(guest.workflow_config(changed)['enabled'])
        for header in (
            'mvp:\n  enabled: true\n  state_dir: /one\n  state_dir: /two',
            'mvp:\n  enabled: true\n  state_dir: /one\nmvp:\n  enabled: true\n  state_dir: /two',
            'mvp:\n  enabled: true\n  state_dir: *alias',
            'mvp:\n  enabled: true\n  <<: *alias\n  state_dir: /one',
            'mvp:\n  enabled: true\n  "state_dir": /one',
            '{"mvp":{"enabled":true,"state_dir":"/one","state_dir":"/two"}}',
            '{"mvp":{"enabled":true,"state_dir":"/one/../two"}}',
        ):
            with self.subTest(header=header), self.assertRaises(ValueError):
                guest.workflow_config(('---\n' + header + '\n---\nBody\n').encode())

    def test_settings_root_relationships_refuse_wrong_config_inputs(self):
        settings = self.settings()
        for changes in ({'config_root': settings['runtime_root']},
                        {'view_root': settings['runtime_root']},
                        {'workflow': str(self.base / 'outside/WORKFLOW.md')},
                        {'view_root': settings['config_root']},
                        {'state_dir': settings['runtime_root']}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                guest.validate_settings({**settings, **changes})

    def maintenance_http(self, settings, **overrides):
        ack = {'nonce': guest.read_maintenance(settings)['nonce'], 'acknowledged': True,
               'drained': True, 'pid': 901, 'boot_id': '11111111-2222-4333-8444-555555555555'}
        ack.update(overrides)
        return io.BytesIO(json.dumps({'running': [], 'retrying': [], 'maintenance': ack}).encode())

    def test_maintenance_requires_serial_ack_matching_nonce_systemd_pid_and_boot(self):
        settings = self.settings()
        guest.pause(settings, 'maintenance')
        nonce, _ = guest.request_maintenance(settings, 'maintenance')
        boot = '11111111-2222-4333-8444-555555555555'
        identity = 'LoadState=loaded\nActiveState=active\nMainPID=901\n'
        with patch.object(guest, 'command', return_value=identity) as command, \
             patch.object(guest, 'boot_identity', return_value=boot), \
             patch.object(guest.urllib.request, 'urlopen', side_effect=lambda *a, **k: self.maintenance_http(settings)):
            ack = guest.require_idle(settings, nonce)
        self.assertTrue(ack['drained'])
        self.assertEqual(command.call_count, 2)
        for mismatch in ({'nonce': 'a' * 32}, {'pid': 902}, {'pid': True},
                         {'boot_id': '99999999-2222-4333-8444-555555555555'},
                         {'acknowledged': False}):
            with self.subTest(mismatch=mismatch), patch.object(guest, 'command', return_value=identity), \
                 patch.object(guest, 'boot_identity', return_value=boot), \
                 patch.object(guest.urllib.request, 'urlopen', side_effect=lambda *a, **k: self.maintenance_http(settings, **mismatch)), \
                 patch.object(guest.time, 'monotonic', side_effect=[0, 31]), self.assertRaises(TimeoutError):
                guest.require_idle(settings, nonce)
        # An old-style zero-running snapshot is never sufficient.
        with patch.object(guest, 'command', return_value=identity), patch.object(guest, 'boot_identity', return_value=boot), \
             patch.object(guest.urllib.request, 'urlopen', return_value=io.BytesIO(b'{"running":[],"retrying":[]}')), \
             patch.object(guest.time, 'monotonic', side_effect=[0, 31]), self.assertRaises(TimeoutError):
            guest.require_idle(settings, nonce)

    def test_maintenance_pid_change_or_marker_replacement_refuses_ack(self):
        settings = self.settings()
        guest.pause(settings, 'maintenance')
        nonce, _ = guest.request_maintenance(settings, 'maintenance')
        boot = '11111111-2222-4333-8444-555555555555'
        with patch.object(guest, 'controller_identity', side_effect=[(901, boot), (902, boot)]), \
             patch.object(guest.urllib.request, 'urlopen', side_effect=lambda *a, **k: self.maintenance_http(settings)), \
             patch.object(guest.time, 'monotonic', side_effect=[0, 31]), self.assertRaises(TimeoutError):
            guest.require_idle(settings, nonce)
        def replaced(*args, **kwargs):
            response = self.maintenance_http(settings)
            guest.maintenance_path(settings).write_text(json.dumps({'nonce': 'f' * 32, 'reason': 'another operator'}))
            return response
        with patch.object(guest, 'controller_identity', return_value=(901, boot)), \
             patch.object(guest.urllib.request, 'urlopen', side_effect=replaced), self.assertRaisesRegex(ValueError, 'changed'):
            guest.require_idle(settings, nonce)

    def test_daily_busy_handshake_cleans_only_owned_markers_and_never_stops(self):
        settings = self.settings()
        original = Path(settings['workflow']).read_bytes()
        boot = '11111111-2222-4333-8444-555555555555'
        for prior_intake, prior_maintenance in ((False, False), (True, False), (False, True), (True, True)):
            with self.subTest(prior_intake=prior_intake, prior_maintenance=prior_maintenance):
                if prior_intake:
                    guest.pause(settings, 'preexisting intake reason')
                if prior_maintenance:
                    guest.request_maintenance(settings, 'preexisting maintenance reason')
                paths = (guest.pause_path(settings), guest.maintenance_path(settings))
                before = {p: p.read_bytes() if p.exists() else None for p in paths}
                calls = []
                def command(argv):
                    calls.append(argv)
                    if '--property=LoadState,ActiveState' in argv:
                        return 'LoadState=loaded\nActiveState=active\n'
                    if '--property=LoadState,ActiveState,MainPID' in argv:
                        return 'LoadState=loaded\nActiveState=active\nMainPID=901\n'
                    raise AssertionError('busy must never stop/start/poweroff')
                with patch.object(guest, 'command', side_effect=command), patch.object(guest, 'boot_identity', return_value=boot), \
                     patch.object(guest.urllib.request, 'urlopen', side_effect=lambda *a, **k: self.maintenance_http(settings, drained=False)), \
                     self.assertRaises(guest.MaintenanceBusy):
                    guest.daily_backup(settings, io.BytesIO())
                self.assertEqual(before, {p: p.read_bytes() if p.exists() else None for p in paths})
                self.assertEqual(original, Path(settings['workflow']).read_bytes())
                for p in paths:
                    if p.exists():
                        p.unlink()

    def test_shutdown_waits_for_maintenance_ack_or_leaves_vm_running(self):
        settings = self.settings()
        calls = []
        def command(argv):
            calls.append(argv)
            if '--property=ActiveState' in argv:
                return 'active\n'
            if '--property=LoadState,ActiveState,MainPID' in argv:
                return 'LoadState=loaded\nActiveState=active\nMainPID=901\n'
            self.assertEqual(argv, ['sudo', '-n', 'systemctl', 'poweroff', '--no-block'])
            self.assertTrue(guest.maintenance_path(settings).exists())
            return ''
        boot = '11111111-2222-4333-8444-555555555555'
        with patch.object(guest, 'command', side_effect=command), patch.object(guest, 'boot_identity', return_value=boot), \
             patch.object(guest.urllib.request, 'urlopen', side_effect=lambda *a, **k: self.maintenance_http(settings)):
            guest.shutdown(settings)
        self.assertIn(['sudo', '-n', 'systemctl', 'poweroff', '--no-block'], calls)
        self.assertTrue(guest.maintenance_path(settings).exists())
        calls.clear()
        with patch.object(guest, 'command', side_effect=command), patch.object(guest, 'boot_identity', return_value=boot), \
             patch.object(guest.urllib.request, 'urlopen', side_effect=lambda *a, **k: self.maintenance_http(settings, drained=False)), \
             self.assertRaises(guest.MaintenanceBusy):
            guest.shutdown(settings)
        self.assertFalse(any('poweroff' in c for c in calls))

    def test_restore_cannot_opt_out_of_workflow_disable_and_state_remap(self):
        for json_workflow in (False, True):
            # Each archive independently uses the same disposable source tree.
            if not json_workflow:
                settings, content = self.create_backup()
            else:
                workflow = Path(settings['workflow'])
                workflow.write_text('---\n' + json.dumps({'mvp': {'enabled': True, 'state_dir': settings['state_dir']}}) + '\n---\nBody\n')
                stream = io.BytesIO()
                with patch.object(guest, 'require_stopped'):
                    guest.backup(settings, stream)
                content = stream.getvalue()
            for edit in (lambda m: m.update(editable_configs=[]), lambda m: m.pop('editable_configs')):
                changed = self.rewrite_manifest(content, edit)
                target = self.base / ('forced-disabled-' + uuid.uuid4().hex)
                guest.restore(io.BytesIO(changed), target, settings)
                parsed = guest.workflow_config((target / 'config/WORKFLOW.md').read_bytes())
                self.assertFalse(parsed['enabled'])
                self.assertEqual(parsed['state_dir'], str(target / 'runtime/state'))

    def test_restore_rejects_manifest_schema_and_root_relationship_bypasses(self):
        settings, content = self.create_backup()
        mutations = (
            lambda m: m.pop('workflow_path'),
            lambda m: m.update(workflow_path='runtime/active-recovery.json'),
            lambda m: m.update(state_path='config'),
            lambda m: m.update(editable_configs=['runtime/active-recovery.json']),
            lambda m: m.update(editable_configs=[[]]),
            lambda m: m['source_roots'].update(config=m['source_roots']['runtime']),
            lambda m: m['source_roots'].update(view=m['source_roots']['config']),
            lambda m: m['source_roots'].update(runtime='/var/tmp/../live'),
        )
        for change in mutations:
            changed = self.rewrite_manifest(content, change)
            with tarfile.open(fileobj=io.BytesIO(changed)) as archive, self.assertRaises(ValueError):
                guest.read_archive(archive)
        original = Path(settings['workflow']).read_bytes()
        self.assertTrue(guest.workflow_config(original)['enabled'])

    def test_node_install_normalizes_0700_root_and_runs_unprivileged(self):
        source = self.base / 'extracted-node'
        source.mkdir(mode=0o700)
        (source / 'bin').mkdir(mode=0o755)
        executable = source / 'bin/node'
        executable.write_text('#!/usr/bin/python3\nimport os\nprint(os.geteuid())\n')
        executable.chmod(0o755)
        target = self.base / 'installed-node'
        artifacts.install_node(source, target)
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)
        if os.geteuid() != 0:
            output = subprocess.check_output([str(target / 'bin/node')], text=True)
            self.assertEqual(int(output), os.geteuid())
        with self.assertRaises(FileExistsError):
            artifacts.install_node(source, target)



    def test_daily_busy_preserves_disk_pause_adopted_by_concurrent_host_guard(self):
        settings = self.settings()
        workflow = Path(settings['workflow']).read_bytes()
        identities = []
        def guard_then_busy(*args):
            marker = guest.pause_path(settings)
            identities.append(marker.stat().st_ino)
            guest.check(settings, apply=True, host_paused=True)
            identities.append(marker.stat().st_ino)
            raise guest.MaintenanceBusy('busy')
        with patch.object(guest, 'command', return_value='LoadState=loaded\nActiveState=active\n') as command, \
             patch.object(guest, 'require_idle', side_effect=guard_then_busy), \
             patch.object(guest.shutil, 'disk_usage', return_value=Mock(free=guest.FLOOR + 1)), \
             self.assertRaises(guest.MaintenanceBusy):
            guest.daily_backup(settings, io.BytesIO())
        self.assertNotEqual(*identities)
        self.assertIn(b'Disk admission paused', guest.pause_path(settings).read_bytes())
        self.assertFalse(guest.maintenance_path(settings).exists())
        self.assertFalse(any('stop' in c.args[0] for c in command.call_args_list))
        self.assertEqual(Path(settings['workflow']).read_bytes(), workflow)

    def test_daily_success_preserves_disk_pause_adopted_during_backup(self):
        settings = self.settings()
        def guard_during_backup(*args):
            guest.check(settings, apply=True, host_paused=True)
        with patch.object(guest, 'command', return_value='LoadState=loaded\nActiveState=active\n'), \
             patch.object(guest, 'require_idle'), patch.object(guest, 'backup', side_effect=guard_during_backup), \
             patch.object(guest, 'wait_healthy'), \
             patch.object(guest.shutil, 'disk_usage', return_value=Mock(free=guest.FLOOR + 1)):
            guest.daily_backup(settings, io.BytesIO())
        self.assertIn(b'Disk admission paused', guest.pause_path(settings).read_bytes())
        self.assertFalse(guest.maintenance_path(settings).exists())

    def test_healthy_guard_keeps_daily_ownership_but_low_disk_replaces_it(self):
        settings = self.settings()
        owned = guest.pause(settings, 'daily backup')
        with patch.object(guest.shutil, 'disk_usage', return_value=Mock(free=guest.FLOOR + 1)):
            guest.check(settings, apply=True)
        guest.remove_owned_marker(owned)
        self.assertFalse(guest.pause_path(settings).exists())
        owned = guest.pause(settings, 'another daily backup')
        with patch.object(guest.shutil, 'disk_usage', return_value=Mock(free=guest.FLOOR - 1)):
            guest.check(settings, apply=True)
        guest.remove_owned_marker(owned)
        self.assertIn(b'Disk admission paused', guest.pause_path(settings).read_bytes())

    def test_guard_and_marker_cleanup_serialize_ownership_check_and_unlink(self):
        settings = self.settings()
        marker = guest.pause_path(settings)
        owned = guest.pause(settings, 'daily backup')
        attempted, completed = threading.Event(), threading.Event()
        errors = []
        original_lock = guest.intake_lock
        original_remove = guest.remove_marker_identity
        @contextmanager
        def observed_lock(path):
            if threading.current_thread().name == 'disk-guard':
                attempted.set()
            with original_lock(path):
                yield
        def guard():
            try:
                guest.check(settings, apply=True, host_paused=True)
            except Exception as error:
                errors.append(error)
            finally:
                completed.set()
        worker = threading.Thread(target=guard, name='disk-guard')
        def remove_under_lock(*args):
            worker.start()
            self.assertTrue(attempted.wait(2))
            self.assertFalse(completed.is_set())
            original_remove(*args)
        with patch.object(guest, 'intake_lock', side_effect=observed_lock), \
             patch.object(guest, 'remove_marker_identity', side_effect=remove_under_lock), \
             patch.object(guest.shutil, 'disk_usage', return_value=Mock(free=guest.FLOOR + 1)):
            guest.remove_owned_marker(owned)
            worker.join(timeout=2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(errors, [])
        self.assertTrue(completed.is_set())
        self.assertIn(b'Disk admission paused', marker.read_bytes())

    def test_disk_guard_preserves_unknown_marker_without_blocking_paused_startup(self):
        settings = self.settings()
        evidence = self.base / 'operator-pause-evidence'
        evidence.write_bytes(b'preserve operator marker')
        marker = guest.pause_path(settings)
        marker.symlink_to(evidence)
        with patch.object(guest.shutil, 'disk_usage', return_value=Mock(free=guest.FLOOR - 1)):
            result = guest.check(settings, apply=True, host_paused=True)
        self.assertTrue(result['admission_paused'])
        self.assertTrue(marker.is_symlink())
        self.assertEqual(evidence.read_bytes(), b'preserve operator marker')

    def test_codex_single_file_and_wrapped_archives_preserve_native_entry(self):
        payload = b'ELF native Codex fixture'
        for name, entry in (('codex-x86_64-unknown-linux-musl', 'codex-x86_64-unknown-linux-musl'),
                            ('package/vendor/x86_64/codex/codex', 'vendor/x86_64/codex/codex')):
            with self.subTest(name=name):
                archive_path = self.base / (uuid.uuid4().hex + '.tar.gz')
                with tarfile.open(archive_path, 'w:gz') as archive:
                    info = tarfile.TarInfo(name)
                    info.mode, info.size = 0o755, len(payload)
                    archive.addfile(info, io.BytesIO(payload))
                inputs = {}
                for component, version in artifacts.VERSIONS.items():
                    source = archive_path if component == 'codex' else self.base / ('artifact-' + component)
                    if component != 'codex':
                        source.write_bytes(component.encode())
                    inputs[component] = {'path': str(source), 'version': version,
                                         'sha256': artifacts.digest(source), 'provenance': 'verified fixture input'}
                inputs['codex']['entry'] = entry
                manifest = self.base / 'single-or-wrapped-manifest.json'
                manifest.write_text(json.dumps(inputs))
                verified = artifacts.verified_manifest(manifest)
                target = self.base / ('codex-extracted-' + uuid.uuid4().hex)
                artifacts.extract(verified, 'codex', target)
                self.assertEqual((target / entry).read_bytes(), payload)
                self.assertTrue((target / entry).stat().st_mode & 0o111)

    def test_codex_archive_entry_validation_happens_before_extraction(self):
        for invalid in ('missing', 'symlink', 'hardlink', 'empty', 'not-executable', 'parent-link'):
            path = self.base / (invalid + '.tar.gz')
            with tarfile.open(path, 'w:gz') as archive:
                info = tarfile.TarInfo('codex')
                info.mode, info.size = 0o755, 4
                if invalid == 'symlink':
                    info.type, info.linkname, info.size = tarfile.SYMTYPE, '/usr/bin/other', 0
                elif invalid == 'hardlink':
                    info.type, info.linkname, info.size = tarfile.LNKTYPE, 'other', 0
                elif invalid == 'empty':
                    info.size = 0
                elif invalid == 'not-executable':
                    info.mode = 0o644
                if invalid == 'parent-link':
                    info.name = 'package/bin'
                    info.type, info.linkname, info.size = tarfile.SYMTYPE, 'elsewhere', 0
                    archive.addfile(info)
                    info = tarfile.TarInfo('package/bin/codex')
                    info.mode, info.size = 0o755, 4
                archive.addfile(info, io.BytesIO(b'code') if info.isfile() else None)
            entry = 'absent' if invalid == 'missing' else 'bin/codex' if invalid == 'parent-link' else 'codex'
            target = self.base / ('invalid-entry-' + invalid)
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                artifacts.extract({'codex': {'path': str(path), 'entry': entry}}, 'codex', target)
            self.assertFalse(target.exists())

    def test_wrapped_source_archive_hardlink_names_follow_normalization(self):
        path = self.base / 'source-with-links.tar'
        with tarfile.open(path, 'w') as archive:
            info = tarfile.TarInfo('source/file')
            info.size, info.mode = 4, 0o644
            archive.addfile(info, io.BytesIO(b'data'))
            link = tarfile.TarInfo('source/hardlink')
            link.type, link.linkname = tarfile.LNKTYPE, 'source/file'
            archive.addfile(link)
        target = self.base / 'source-with-links'
        artifacts.extract({'otp': {'path': str(path)}}, 'otp', target)
        self.assertEqual((target / 'file').read_bytes(), (target / 'hardlink').read_bytes())

    def test_bootstrap_otp_symlinks_start_escript_with_nonroot_service_path(self):
        bootstrap = Path(guest.__file__).with_name('bootstrap-guest.sh').read_text()
        links = bootstrap[bootstrap.index('for vm_link in erl erlc escript; do'):bootstrap.index('for vm_link in elixir')]
        probe = bootstrap[bootstrap.index('# Verify native escript startup'):bootstrap.index('# End native escript probe')]
        prefix, config, user_bin = self.base / 'opt', self.base / 'config', self.base / 'user-bin'
        otp_bin = prefix / 'otp-28.5.0.7/bin'
        otp_bin.mkdir(parents=True)
        config.mkdir()
        user_bin.mkdir()
        trace = self.base / 'escript-probe-uid'
        for name in ('erl', 'erlc'):
            (otp_bin / name).write_text('#!/bin/sh\nexit 0\n')
            (otp_bin / name).chmod(0o755)
        interpreter = otp_bin / 'escript'
        interpreter.write_text('#!/usr/bin/python3\nimport os,sys\nfrom pathlib import Path\n'
                               'assert Path(sys.argv[1]).read_text().startswith("#!/usr/bin/env escript")\n'
                               'assert "main(_)" in Path(sys.argv[1]).read_text()\n'
                               + 'Path(' + repr(str(trace)) + ').write_text(str(os.geteuid()))\n'
                               + 'print("symphony-escript-ok")\n')
        interpreter.chmod(0o755)
        # Mock privilege switching only; the actual generated executable/shebang
        # is run using this test user's effective UID and the service-only PATH.
        launcher = user_bin / 'runuser'
        launcher.write_text('#!/usr/bin/python3\nimport os,sys\n'
                            'assert sys.argv[1:4] == ["-u", "elma", "--"]\n'
                            'assert sys.argv[4:6] == ["env", "-i"]\n'
                            'os.execv("/usr/bin/env", sys.argv[4:])\n')
        launcher.chmod(0o755)
        script = ('set -euo pipefail\nvm_prefix=' + shlex.quote(str(prefix))
                  + '\nvm_config=' + shlex.quote(str(config))
                  + '\nexport PATH=' + shlex.quote(str(user_bin) + ':/usr/bin:/bin') + '\n'
                  + links.replace('/usr/local/bin', str(user_bin)) + '\n'
                  + probe.replace('/usr/local/bin', str(user_bin)))
        subprocess.run(['/usr/bin/bash', '-c', script], check=True, capture_output=True, text=True)
        self.assertEqual((user_bin / 'escript').resolve(), interpreter)
        self.assertEqual(int(trace.read_text()), os.geteuid())


    def test_bootstrap_fixed_codex_link_satisfies_existing_native_client_gate(self):
        bootstrap = Path(guest.__file__).with_name('bootstrap-guest.sh').read_text()
        line = next(line for line in bootstrap.splitlines() if line.startswith('ln -s ') and line.endswith(' /opt/codex'))
        prefix = self.base / 'opt-symphony'
        binary = prefix / 'codex-0.163.0/bin/codex'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'\x7fELFnative-code-fixture')
        binary.chmod(0o755)
        fixed_client = self.base / 'fixed-opt-codex'
        script = ('vm_prefix=' + shlex.quote(str(prefix)) + '\n'
                  + line.removesuffix(' /opt/codex') + ' ' + shlex.quote(str(fixed_client)))
        subprocess.run(['/usr/bin/bash', '-c', script], check=True, capture_output=True)
        manifest = self.base / 'runtime-identity.json'
        manifest.write_text(json.dumps({'codex': {'version': '0.163.0'}, 'protocol': 'fixture'}))
        with patch.object(runtime_identity, 'MANIFEST', manifest), \
             patch.object(runtime_identity.subprocess, 'check_output', return_value='codex-cli 0.163.0\n') as version:
            identity = runtime_identity.native_client(fixed_client)
            self.assertEqual(identity['path'], str(binary))
            self.assertEqual(identity['sha256'], hashlib.sha256(binary.read_bytes()).hexdigest())
            self.assertEqual(version.call_args.args[0], [str(binary), '--version'])
            binary.write_text('#!/bin/sh\nprintf wrapper\n')
            with self.assertRaisesRegex(ValueError, 'native Linux executable'):
                runtime_identity.native_client(fixed_client)



    def test_host_cli_check_propagates_disk_pause_while_daily_backup_holds_lock(self):
        settings = self.settings()
        guard_results, guard_errors, forwarded = [], [], []
        def usage(path):
            return Mock(free=14 * vm.GIB if Path(path) == self.root else 10 * vm.GIB)
        def remote_guard(argv, **kwargs):
            forwarded.append(argv[-1])
            self.assertIn('--host-paused', argv[-1])
            return json.dumps(guest.check(settings, apply=True, host_paused=True)).encode()
        def guard():
            try:
                guard_results.append(vm.main(['--root', str(self.root), 'check', '--apply']))
            except Exception as error:
                guard_errors.append(error)
        def backup_with_guard(*args):
            worker = threading.Thread(target=guard, name='host-disk-check')
            worker.start()
            worker.join(timeout=2)
            self.assertFalse(worker.is_alive())
            self.assertEqual(guard_errors, [])
            self.assertEqual(guard_results, [0])
        with vm.operation_lock(self.root), \
             patch.object(vm.shutil, 'disk_usage', side_effect=usage), \
             patch.object(vm, 'run', side_effect=remote_guard), \
             patch.object(guest, 'command', return_value='LoadState=loaded\nActiveState=active\n'), \
             patch.object(guest, 'require_idle'), patch.object(guest, 'backup', side_effect=backup_with_guard), \
             patch.object(guest, 'wait_healthy'), patch('builtins.print'):
            guest.daily_backup(settings, io.BytesIO())
        self.assertEqual(len(forwarded), 1)
        self.assertTrue((self.root / 'admission-paused').exists())
        self.assertIn(b'Disk admission paused', guest.pause_path(settings).read_bytes())
        self.assertFalse(guest.maintenance_path(settings).exists())

    def test_parallel_host_checks_both_propagate_one_persistent_pause(self):
        barrier = threading.Barrier(2)
        results, errors = [], []
        original_write = vm.write_new
        def concurrent_write(*args, **kwargs):
            barrier.wait(timeout=2)
            return original_write(*args, **kwargs)
        def guard():
            try:
                results.append(vm.main(['--root', str(self.root), 'check', '--apply']))
            except Exception as error:
                errors.append(error)
        workers = [threading.Thread(target=guard) for _ in range(2)]
        with patch.object(vm.shutil, 'disk_usage', return_value=Mock(free=vm.GIB)), \
             patch.object(vm, 'write_new', side_effect=concurrent_write), \
             patch.object(vm, 'run', return_value=b'{"admission_paused":true}') as remote, \
             patch('builtins.print'):
            for worker in workers:
                worker.start()
            for worker in workers:
                worker.join(timeout=3)
        self.assertTrue(all(not worker.is_alive() for worker in workers))
        self.assertEqual(errors, [])
        self.assertEqual(results, [0, 0])
        self.assertEqual(remote.call_count, 2)
        self.assertTrue((self.root / 'admission-paused').exists())



    def test_real_daily_export_keeps_one_descriptor_across_disk_marker_replacement(self):
        settings = self.backup_settings()
        marker = guest.pause_path(settings)
        workflow_before = Path(settings['workflow']).read_bytes()
        states = {service: 'active' for service in guest.SERVICES}
        original_hash = hashlib.file_digest
        original_open = Path.open
        opened, captured = [], {}
        def command(argv):
            if argv[0] == 'systemctl':
                service = argv[2]
                return ('LoadState=loaded\nActiveState=' + states[service] + '\nControlGroup=\n'
                        + 'MainPID=' + ('901' if states[service] == 'active' else '0') + '\n')
            action = argv[3]
            self.assertIn(action, ('stop', 'start'))
            for service in argv[4:]:
                states[service] = 'inactive' if action == 'stop' else 'active'
            return ''
        def open_export(path, *args, **kwargs):
            mode = args[0] if args else kwargs.get('mode', 'r')
            if path == marker and mode == 'rb':
                opened.append(path)
                # Metadata read before open must not win over this inode's
                # actual mode at open/fstat time.
                path.chmod(0o640)
            return original_open(path, *args, **kwargs)
        def replace_after_digest(stream, algorithm):
            result = original_hash(stream, algorithm)
            if Path(stream.name) == marker and not captured:
                position = stream.tell()
                stream.seek(0)
                captured['bytes'] = stream.read()
                stream.seek(position)
                captured['inode'] = os.fstat(stream.fileno()).st_ino
                captured['mode'] = os.fstat(stream.fileno()).st_mode & 0o777
                guest.check(settings, apply=True, host_paused=True)
                self.assertNotEqual(marker.stat().st_ino, captured['inode'])
            return result
        output = io.BytesIO()
        with patch.object(guest, 'command', side_effect=command), \
             patch.object(guest, 'boot_identity', return_value='11111111-2222-4333-8444-555555555555'), \
             patch.object(guest.urllib.request, 'urlopen', side_effect=lambda *a, **k: self.maintenance_http(settings)), \
             patch.object(guest.socket, 'socket'), patch.object(guest, 'wait_healthy'), \
             patch.object(guest.shutil, 'disk_usage', return_value=Mock(free=guest.FLOOR + 1)), \
             patch.object(Path, 'open', new=open_export), \
             patch.object(guest.hashlib, 'file_digest', side_effect=replace_after_digest):
            # Real backup(): inventory, SQLite backup, hashing and tar export.
            guest.daily_backup(settings, output)
        self.assertEqual(len(opened), 1)
        self.assertEqual(captured['mode'], 0o640)
        current = marker.read_bytes()
        self.assertGreater(len(captured['bytes']), len(current))
        self.assertIn(b'Disk admission paused', current)
        self.assertFalse(guest.maintenance_path(settings).exists())
        self.assertTrue(all(state == 'active' for state in states.values()))
        with tarfile.open(fileobj=io.BytesIO(output.getvalue())) as archive:
            manifest = guest.read_archive(archive)
        entry = manifest['entries']['runtime/state/intake-paused']
        self.assertEqual(entry['size'], len(captured['bytes']))
        self.assertEqual(entry['mode'], captured['mode'])
        self.assertEqual(entry['sha256'], hashlib.sha256(captured['bytes']).hexdigest())
        target = self.base / 'replaced-marker-restored'
        guest.restore(io.BytesIO(output.getvalue()), target, settings)
        restored_marker = target / 'runtime/state/intake-paused'
        self.assertEqual(restored_marker.read_bytes(), captured['bytes'])
        self.assertEqual(restored_marker.stat().st_mode & 0o777, captured['mode'])
        self.assertEqual(marker.read_bytes(), current)
        self.assertEqual(Path(settings['workflow']).read_bytes(), workflow_before)
        self.assertFalse(guest.workflow_config((target / 'config/WORKFLOW.md').read_bytes())['enabled'])
        self.assertEqual((target / 'runtime/active-recovery.json').read_bytes(), b'keep candidate recovery')
        self.assertEqual((target / 'view/board.sqlite').stat().st_mode & 0o777, 0o600)
        with closing(sqlite3.connect(target / 'view/board.sqlite')) as database:
            self.assertEqual(database.execute('SELECT value FROM evidence').fetchone()[0], 'committed WAL data')

    def test_real_export_inplace_mutation_still_fails_hash_validation(self):
        settings = self.backup_settings()
        guest.pause(settings, 'manual backup')
        guest.request_maintenance(settings, 'manual backup')
        path = Path(settings['runtime_root']) / 'active-recovery.json'
        before_inode = path.stat().st_ino
        before_content = path.read_bytes()
        changed_content = b'fake candidate recovery'
        self.assertEqual(len(changed_content), len(before_content))
        original_hash = hashlib.file_digest
        mutated = []
        def mutate_after_digest(stream, algorithm):
            result = original_hash(stream, algorithm)
            if Path(stream.name) == path and not mutated:
                with path.open('r+b', buffering=0) as writer:
                    writer.write(changed_content)
                    os.fsync(writer.fileno())
                mutated.append(True)
            return result
        output = io.BytesIO()
        with patch.object(guest, 'require_stopped'), patch.object(guest.hashlib, 'file_digest', side_effect=mutate_after_digest):
            guest.backup(settings, output)
        self.assertEqual(path.stat().st_ino, before_inode)
        self.assertEqual(path.read_bytes(), changed_content)
        self.assertEqual(mutated, [True])
        with tarfile.open(fileobj=io.BytesIO(output.getvalue())) as archive, self.assertRaisesRegex(ValueError, 'hash'):
            guest.read_archive(archive)
        with self.assertRaisesRegex(ValueError, 'hash'):
            guest.restore(io.BytesIO(output.getvalue()), self.base / 'bad-inplace-restore', settings)
        self.assertTrue(guest.pause_path(settings).exists())
        self.assertTrue(guest.maintenance_path(settings).exists())

    def test_real_export_inplace_truncation_is_not_swallowed(self):
        settings = self.backup_settings()
        guest.pause(settings, 'manual backup')
        guest.request_maintenance(settings, 'manual backup')
        path = Path(settings['runtime_root']) / 'active-recovery.json'
        original_hash = hashlib.file_digest
        mutated = []
        def truncate_after_digest(stream, algorithm):
            result = original_hash(stream, algorithm)
            if Path(stream.name) == path and not mutated:
                with path.open('r+b', buffering=0) as writer:
                    writer.truncate(1)
                    os.fsync(writer.fileno())
                mutated.append(True)
            return result
        with patch.object(guest, 'require_stopped'), \
             patch.object(guest.hashlib, 'file_digest', side_effect=truncate_after_digest), \
             self.assertRaisesRegex(OSError, 'unexpected end'):
            guest.backup(settings, io.BytesIO())
        self.assertEqual(mutated, [True])
        self.assertTrue(guest.pause_path(settings).exists())
        self.assertTrue(guest.maintenance_path(settings).exists())


if __name__ == '__main__':
    unittest.main()
