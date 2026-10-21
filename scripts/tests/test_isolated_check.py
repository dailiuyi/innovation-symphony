"""CI and the VM gate run the same private-PID-namespace check; only the identity proof differs."""
from pathlib import Path
import subprocess
import unittest

VM = Path(__file__).resolve().parents[1] / "vm"
SHARED, NATIVE = VM / "isolated-check.sh", VM / "check-native.sh"


class IsolatedCheckContractTest(unittest.TestCase):
    def test_scripts_are_valid_bash(self):
        for script in (SHARED, NATIVE):
            subprocess.run(["bash", "-n", str(script)], check=True)

    def test_unprivileged_caller_is_refused_before_anything_is_created(self):
        before = set(Path("/var/tmp").glob("symphony-native-check.*"))
        result = subprocess.run(["bash", str(SHARED), "nobody", "/usr/bin", str(VM)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(set(Path("/var/tmp").glob("symphony-native-check.*")), before)

    def test_vm_entry_keeps_its_identity_proof_and_delegates_isolation(self):
        native = NATIVE.read_text()
        self.assertIn("/etc/symphony-vm", native)
        self.assertIn("systemd-detect-virt", native)
        self.assertIn("isolated-check.sh", native)
        self.assertNotIn("unshare", native)

    def test_shared_isolation_has_no_vm_marker_and_no_fixed_user(self):
        shared = SHARED.read_text()
        for required in ("--pid", "docker-init", "runuser -u \"$check_user\"", "ERL_INETRC", "SYMPHONY_TEST_CODEX"):
            self.assertIn(required, shared)
        for forbidden in ("/etc/symphony-vm", "systemd-detect-virt", "elma"):
            self.assertNotIn(forbidden, shared)


if __name__ == "__main__":
    unittest.main()
