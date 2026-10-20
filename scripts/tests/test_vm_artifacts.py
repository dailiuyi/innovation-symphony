"""Offline bootstrap inputs and shell probes; no VM, apt, model or services."""
import io
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vm import artifacts


class VmArtifactsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.data = {}
        for name, version in artifacts.VERSIONS.items():
            source = self.base / (name + '.tar')
            with tarfile.open(source, 'w') as archive:
                info = tarfile.TarInfo('package/bin/' + name)
                payload = b'\x7fELF native ' + name.encode()
                info.size, info.mode = len(payload), 0o755
                archive.addfile(info, io.BytesIO(payload))
            self.data[name] = {'path': str(source), 'version': version,
                               'sha256': artifacts.digest(source), 'provenance': 'verified release fixture'}
        helper = self.base / 'codex-code-mode-host'
        helper.write_bytes(b'\x7fELF native code-mode-host fixture')
        self.data['codex'].update(entry='bin/codex', code_mode_host={
            'version': '0.163.0', 'path': str(helper), 'sha256': artifacts.digest(helper),
            'provenance': 'verified matching standalone release fixture'})
        self.manifest = self.base / 'manifest.json'
        self.bootstrap = Path(artifacts.__file__).with_name('bootstrap-guest.sh').read_text()

    def verify(self):
        self.manifest.write_text(json.dumps(self.data))
        return artifacts.verified_manifest(self.manifest)

    def test_receipt_binds_installed_helper_beside_resolved_cli(self):
        binary = self.base / 'codex'
        binary.write_bytes(b'installed CLI')
        link = self.base / 'codex-link'
        link.symlink_to(binary)
        receipt = self.base / 'toolchain-receipt.json'
        with patch.dict(artifacts.BINARIES, {'codex': str(link)}, clear=True):
            artifacts.receipt(receipt)
        recorded = json.loads(receipt.read_text())['codex']
        helper = binary.with_name('codex-code-mode-host')
        self.assertEqual(recorded['code_mode_host'], {
            'binary': str(helper), 'binary_sha256': artifacts.digest(helper)})
        helper.unlink()
        with patch.dict(artifacts.BINARIES, {'codex': str(link)}, clear=True):
            with self.assertRaises(FileNotFoundError):
                artifacts.receipt(self.base / 'missing-helper-receipt.json')
        self.assertFalse((self.base / 'missing-helper-receipt.json').exists())

    def test_helper_required_for_otherwise_valid_cli_archive(self):
        del self.data['codex']['code_mode_host']
        with self.assertRaisesRegex(ValueError, 'same-version code_mode_host'):
            self.verify()

    def test_helper_version_provenance_and_checksum_required(self):
        helper = self.data['codex']['code_mode_host']
        for key, bad, message in (('version', '0.162.0', 'exact pinned'),
                                  ('version', 'latest', 'exact pinned'),
                                  ('provenance', '', 'provenance'),
                                  ('sha256', '0' * 64, 'SHA256'),
                                  ('sha256', 'unchecked', 'SHA256')):
            original = helper[key]
            with self.subTest(key=key, bad=bad):
                helper[key] = bad
                with self.assertRaisesRegex(ValueError, message):
                    self.verify()
                helper[key] = original
        self.verify()

    def test_helper_must_be_an_absolute_regular_native_file(self):
        helper = self.data['codex']['code_mode_host']
        original = helper['path']
        linked = self.base / 'helper-link'
        linked.symlink_to(original)
        for bad in ('relative-helper', str(self.base / 'missing'), str(self.base), str(linked)):
            with self.subTest(path=bad):
                helper['path'] = bad
                with self.assertRaisesRegex(ValueError, 'absolute regular file'):
                    self.verify()
        helper['path'] = original
        Path(original).write_bytes(b'#!/bin/sh\nexit 0\n')
        helper['sha256'] = artifacts.digest(original)
        with self.assertRaisesRegex(ValueError, 'native Linux executable'):
            self.verify()

    def test_tampered_helper_or_main_archive_rejected(self):
        self.verify()
        for artifact in (self.data['codex'], self.data['codex']['code_mode_host']):
            with self.subTest(path=artifact['path']):
                source = Path(artifact['path'])
                original = source.read_bytes()
                source.write_bytes(original + b'tampered')
                with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
                    self.verify()
                source.write_bytes(original)

    def test_bootstrap_installs_verified_helper_adjacent_to_main(self):
        data = self.verify()
        build, prefix = self.base / 'build', self.base / 'opt'
        build.mkdir()
        artifacts.extract(data, 'codex', build / 'codex')
        (prefix / 'codex-0.163.0/bin').mkdir(parents=True)
        install = self.bootstrap[self.bootstrap.index('vm_codex_entry='):
                                 self.bootstrap.index('for vm_link in erl erlc escript; do')]
        script = '\n'.join(('set -euo pipefail',
                            'vm_manifest=' + shlex.quote(str(self.manifest)),
                            'vm_build=' + shlex.quote(str(build)),
                            'vm_prefix=' + shlex.quote(str(prefix)),
                            'vm_script_dir=' + shlex.quote(str(Path(artifacts.__file__).parent)), install))
        subprocess.run(['bash', '-c', script], check=True, capture_output=True, text=True)
        binary = prefix / 'codex-0.163.0/bin/codex'
        helper = binary.with_name('codex-code-mode-host')
        self.assertEqual(binary.read_bytes(), (build / 'codex/bin/codex').read_bytes())
        self.assertEqual(artifacts.digest(helper), data['codex']['code_mode_host']['sha256'])
        self.assertEqual(helper.stat().st_mode & 0o777, 0o755)
        self.assertEqual(binary.stat().st_mode & 0o777, 0o755)

    def test_helper_install_rechecks_source_and_never_replaces_existing_file(self):
        data = self.verify()
        helper = data['codex']['code_mode_host']
        target = self.base / 'installed-helper'
        original = Path(helper['path']).read_bytes()
        Path(helper['path']).write_bytes(original + b'changed-after-verification')
        with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
            artifacts.install_codex_helper(helper, target)
        self.assertFalse(target.exists())
        Path(helper['path']).write_bytes(original)
        target.write_bytes(b'preserve existing helper')
        with self.assertRaises(FileExistsError):
            artifacts.install_codex_helper(helper, target)
        self.assertEqual(target.read_bytes(), b'preserve existing helper')

    def test_helper_copy_corruption_is_rejected_before_executable_permissions(self):
        helper = self.verify()['codex']['code_mode_host']
        target = self.base / 'corrupt-helper'
        with patch.object(artifacts.shutil, 'copyfileobj', side_effect=lambda src, dst: dst.write(b'corruption')):
            with self.assertRaisesRegex(ValueError, 'installed Codex helper SHA256 mismatch'):
                artifacts.install_codex_helper(helper, target)
        self.assertFalse(target.stat().st_mode & 0o111)

    def test_helper_install_cli_dry_run_does_not_create_target(self):
        self.verify()
        target = self.base / 'dry-helper'
        subprocess.run([sys.executable, artifacts.__file__, 'install-codex-helper', str(self.manifest),
                        '--target', str(target)], check=True, capture_output=True, text=True)
        self.assertFalse(target.exists())

    def test_bootstrap_loads_packaged_bwrap_profile_after_all_input_verification(self):
        apt = self.bootstrap[self.bootstrap.index('apt-get install'):self.bootstrap.index('install -d -m 0755')]
        for package in ('bubblewrap', 'apparmor-profiles', 'apparmor-utils'):
            self.assertIn(package, apt)
        self.assertIn('install -m 0644 /usr/share/apparmor/extra-profiles/bwrap-userns-restrict '
                      '/etc/apparmor.d/bwrap-userns-restrict', apt)
        self.assertIn('apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict', apt)
        self.assertLess(self.bootstrap.index('artifacts.py" verify'), self.bootstrap.index('apt-get update'))
        for disabled in ('sysctl', 'aa-disable', 'unconfined', '--disable'):
            self.assertNotIn(disabled, apt)

    def test_readonly_probe_requires_startup_and_confirmed_write_denial(self):
        # Run the actual shell block with a Codex boundary double. It invokes
        # the real Python probe, varying only the sandbox's write outcome.
        probe = self.bootstrap[self.bootstrap.index('# Zero-model probe:'):
                               self.bootstrap.index('# End zero-model probe;')]
        for behavior in ('denied', 'denied-eacces', 'allowed', 'startup-failed', 'write-startup-failed', 'io-error'):
            with self.subTest(behavior=behavior):
                root = self.base / behavior
                runtime, user_bin = root / 'runtime', root / 'bin'
                runtime.mkdir(parents=True)
                user_bin.mkdir()
                runuser = user_bin / 'runuser'
                runuser.write_text('#!/usr/bin/python3\nimport os, sys\n'
                                   'assert sys.argv[1:6] == ["-u", "elma", "--", "env", "-i"]\n'
                                   'os.execv("/usr/bin/env", sys.argv[4:])\n')
                runuser.chmod(0o755)
                chown = user_bin / 'chown'
                chown.write_text('#!/bin/sh\nexit 0\n')
                chown.chmod(0o755)
                codex = user_bin / 'codex'
                codex.write_text('#!/usr/bin/python3\nimport errno, os, pathlib, sys\n'
                                 'assert "CODEX_HOME" in os.environ\n'
                                 'assert pathlib.Path(os.environ["CODEX_HOME"]).is_dir()\n'
                                 'assert os.getcwd() == os.environ["HOME"]\n'
                                 'assert set(os.environ) <= {"HOME", "CODEX_HOME", "PATH", "LC_CTYPE"}\n'
                                 'assert sys.argv[1:5] == ["sandbox", "-c", \'sandbox_mode="read-only"\', "--"]\n'
                                 f'behavior = {behavior!r}\n'
                                 'if behavior == "startup-failed": sys.exit(23)\n'
                                 'payload = sys.argv[5:]\n'
                                 'if payload == ["/usr/bin/true"]: os.execv(payload[0], payload)\n'
                                 'if behavior == "write-startup-failed": sys.exit(23)\n'
                                 'assert payload[:2] == ["/usr/bin/python3", "-c"]\n'
                                 'def denied(*args, **kwargs):\n'
                                 '    code = {"io-error": errno.EIO, "denied-eacces": errno.EACCES}.get(behavior, errno.EROFS)\n'
                                 '    raise OSError(code, "fixture")\n'
                                 'if behavior != "allowed": pathlib.Path.write_text = denied\n'
                                 'sys.argv = ["-c", *payload[3:]]\n'
                                 'exec(compile(payload[2], "<actual-bootstrap-probe>", "exec"))\n')
                codex.chmod(0o755)
                # Simulate user switching and ownership without changing host IDs.
                block = probe.replace('/usr/local/bin', str(user_bin)).replace(
                    'install -d -o elma -g elma', 'install -d')
                script = ('set -euo pipefail\nvm_runtime=' + shlex.quote(str(runtime))
                          + '\nexport PATH=' + shlex.quote(str(user_bin) + ':/usr/bin:/bin') + '\n' + block)
                result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
                if behavior in ('denied', 'denied-eacces'):
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                fixture = next(runtime.glob('sandboxes/run-bootstrap-probe-*/write-test'))
                expected = 'unexpected-write\n' if behavior == 'allowed' else 'symphony-sandbox-original\n'
                self.assertEqual(fixture.read_text(), expected)


if __name__ == '__main__':
    unittest.main()
