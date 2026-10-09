"""Real PID-namespace orphan reaping and fixed container-init protection."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import execution_readiness as readiness
import rootless_sandbox as sandbox


ORPHANS = r'''
import json, os, time
created = []
for _ in range(180):
    read_fd, write_fd = os.pipe()
    child = os.fork()
    if child == 0:
        os.close(read_fd)
        grandchild = os.fork()
        if grandchild == 0:
            os.write(write_fd, str(os.getpid()).encode())
            os._exit(0)
        os._exit(0)
    os.close(write_fd)
    created.append(int(os.read(read_fd, 64)))
    os.close(read_fd)
    os.waitpid(child, 0)
def states():
    result = []
    for pid in created:
        try:
            with open('/proc/' + str(pid) + '/stat') as handle:
                result.append(handle.read().rpartition(') ')[2].split()[0])
        except FileNotFoundError:
            pass
    return result
deadline = time.monotonic() + 5
remaining = states()
while time.monotonic() < deadline and (any(state != 'Z' for state in remaining) or (os.getpid() != 1 and remaining)):
    time.sleep(0.01)
    remaining = states()
print(json.dumps(dict(pid=os.getpid(), created=len(created), orphan_zombies=remaining.count('Z'),
                      orphan_live=sum(state != 'Z' for state in remaining))), flush=True)
'''


class RootlessReapingTest(unittest.TestCase):
    def test_untrusted_link_missing_or_wrapper_init_refused_before_task_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            wrapper = root / 'catatonit'
            wrapper.write_text('#!/bin/sh\nexit 0\n')
            wrapper.chmod(0o755)
            linked = root / 'linked'
            linked.symlink_to(wrapper)
            with patch.object(sandbox, 'INIT_PATH', linked):
                with self.assertRaisesRegex(ValueError, 'canonical'):
                    sandbox.validate_init()
            with patch.object(sandbox, 'INIT_PATH', root / 'missing'):
                with self.assertRaises(FileNotFoundError):
                    sandbox.validate_init()
            # The readiness path uses the same protected-path contract, which
            # rejects this controller-owned fixture before any native execution.
            with patch.object(readiness, 'INIT_PATH', wrapper):
                with self.assertRaisesRegex(ValueError, 'unprotected'):
                    readiness.init_inventory()
            with patch.object(readiness, 'INIT_PATH', wrapper), patch.object(readiness, 'protected', return_value=wrapper):
                with self.assertRaisesRegex(ValueError, 'native ELF'):
                    readiness.init_inventory()
            wrapper.write_bytes(b'\x7fELFfixture')
            wrapper.chmod(0o600)
            with patch.object(readiness, 'INIT_PATH', wrapper), patch.object(readiness, 'protected', return_value=wrapper):
                with self.assertRaisesRegex(ValueError, 'readable and executable'):
                    readiness.init_inventory()

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux PID namespaces are required')
    def test_real_double_fork_orphans_are_reaped_by_the_final_container_init(self):
        required = ['unshare', 'timeout', 'python3']
        if any(shutil.which(name) is None for name in required) or not sandbox.INIT_PATH.exists():
            self.skipTest('unshare/timeout/python3 or the fixed catatonit helper is unavailable')
        sandbox.validate_init()
        readiness.init_inventory()
        namespace = [shutil.which('unshare'), '-Urpf', '--mount-proc', '--kill-child=KILL', '--']
        env = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8'}
        probe = subprocess.run(namespace + ['/usr/bin/true'], capture_output=True, text=True, timeout=10, env=env)
        if probe.returncode:
            self.skipTest('PID/user namespace creation is unavailable: ' + probe.stderr.strip()[:300])
        options = sandbox.container_options('reaping-regression')
        self.assertIn('--init', options)
        helpers = [value.split('=', 1)[1] for value in options if value.startswith('--init-path=')]
        self.assertEqual(helpers, ['/usr/bin/catatonit'])
        results = []
        for prefix in ([], [helpers[0], '--']):
            result = subprocess.run([shutil.which('timeout'), '--kill-after=2s', '20s', *namespace,
                                     *prefix, sys.executable, '-I', '-B', '-c', ORPHANS],
                                    capture_output=True, text=True, timeout=25, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            results.append(json.loads(result.stdout))
        without, with_init = results
        self.assertEqual(without, dict(pid=1, created=180, orphan_zombies=180, orphan_live=0))
        self.assertEqual(with_init, dict(pid=2, created=180, orphan_zombies=0, orphan_live=0))


if __name__ == '__main__':
    unittest.main()
