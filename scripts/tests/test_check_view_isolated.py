"""Fail-closed tests for the trusted View gate boundary."""
from __future__ import annotations

from contextlib import contextmanager, redirect_stdout
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import check_view_isolated as gate
from view_validation import validator


@contextmanager
def synthetic_repo(files):
    with tempfile.TemporaryDirectory(prefix="check-view-gate-repo-") as tmp:
        root = Path(tmp) / "candidate"
        root.mkdir()
        home = Path(tmp) / "home"
        home.mkdir()
        env = {key: value for key, value in os.environ.items()
               if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "TEMP", "TMP", "COMSPEC", "PATHEXT"}}
        env.update(HOME=str(home), USERPROFILE=str(home), GIT_CONFIG_NOSYSTEM="1",
                   GIT_CONFIG_GLOBAL=str(home / "missing-global-config"))

        def run(*args):
            result = subprocess.run(["git", "-C", str(root), *args], env=env,
                                    capture_output=True, timeout=30)
            if result.returncode:
                raise AssertionError(result.stderr.decode("utf-8", "replace"))
            return result.stdout.decode("utf-8", "strict").strip()

        run("init", "--quiet")
        for name, data in files.items():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        run("add", ".")
        run("-c", "user.name=Gate Fixture", "-c", "user.email=fixture@example.invalid",
            "commit", "--quiet", "-m", "Synthetic View gate candidate")
        yield root, run("rev-parse", "HEAD")


class ViewGateTests(unittest.TestCase):
    def test_exact_candidate_sha_is_forwarded_and_extra_routing_args_fail_closed(self):
        sha = "a" * 40
        stdout = io.StringIO()
        with patch.object(gate, "run_gate", return_value=({"passed": True}, 0)) as run, redirect_stdout(stdout):
            self.assertEqual(gate.main(["--candidate-sha", sha]), 0)
        run.assert_called_once_with(sha)

        stdout = io.StringIO()
        with patch.object(gate, "run_gate") as run, redirect_stdout(stdout):
            self.assertEqual(gate.main(["--candidate-sha", sha, "--node", "/tmp/attacker-node"]), 1)
        run.assert_not_called()
        report = __import__("json").loads(stdout.getvalue())
        self.assertFalse(report["passed"])
        self.assertFalse(report["formal_code_checks"])
        self.assertFalse(report["real_windows_wsl_acceptance"])

    def test_host_mount_table_cannot_claim_private_controller_namespaces(self):
        host_mounts = gate.mount_table(
            "31 20 0:25 / / rw,relatime - ext4 /dev/root rw,errors=remount-ro\n"
        )
        with self.assertRaisesRegex(gate.GateError, "/workspace/\\.git"):
            gate.verify_mount_contract(host_mounts)

    def test_missing_source_package_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="check-view-missing-source-") as tmp:
            root = Path(tmp) / "source"
            with patch.object(gate, "SOURCE_ROOT", root), \
                    patch.object(gate, "SOURCE_PACKAGE", root / "view-source.zip"), \
                    patch.object(gate, "SOURCE_MANIFEST", root / "source-manifest.json"):
                with self.assertRaisesRegex(gate.GateError, "source package or manifest is missing"):
                    gate._source_identity(validator)

    def test_missing_viewer_dependency_is_rejected(self):
        with patch.object(gate.importlib.metadata, "version", side_effect=gate.importlib.metadata.PackageNotFoundError("missing")):
            with self.assertRaisesRegex(gate.GateError, "dependency is missing"):
                gate._versions(validator)

    def test_missing_formal_reports_cannot_be_promoted_to_a_pass(self):
        with self.assertRaises((gate.GateError, ValueError)):
            gate.formal_code_result(validator, {"passed": True, "formal_acceptance": False,
                                                "real_wsl_executed": False, "real_browser_executed": False},
                                    {}, {}, {})

    def test_candidate_changes_after_freeze_are_rejected(self):
        with synthetic_repo({"view/app/fixture.py": b"SYNTHETIC_BEFORE\n"}) as (candidate, sha):
            before = validator.candidate_identity(candidate, sha)
            (candidate / "view/app/fixture.py").write_bytes(b"SYNTHETIC_CHANGED\n")
            with self.assertRaisesRegex(ValueError, "worktree is dirty"):
                gate.verify_candidate_unchanged(validator, candidate, sha, before)

    def test_marker_refuses_direct_host_execution(self):
        result = subprocess.run([sys.executable, str(SCRIPTS / "check_view.py")],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"routing marker", result.stderr)

    def test_only_untracked_injected_dependencies_are_removed(self):
        with synthetic_repo({"view/app/fixture.py": b"SYNTHETIC\n"}) as (candidate, sha):
            dependencies = candidate / "elixir/deps/example"
            dependencies.mkdir(parents=True)
            (dependencies / "fixture.ex").write_text("preinstalled fixture\n")
            gate.remove_injected_elixir_dependencies(validator, candidate, sha)
            self.assertFalse((candidate / "elixir/deps").exists())
            self.assertEqual(validator.candidate_identity(candidate, sha)["sha"], sha)
        with synthetic_repo({"elixir/deps/fixture.ex": b"TRACKED_CANDIDATE\n"}) as (candidate, sha):
            with self.assertRaisesRegex(gate.GateError, "must not track"):
                gate.remove_injected_elixir_dependencies(validator, candidate, sha)
            self.assertEqual((candidate / "elixir/deps/fixture.ex").read_bytes(), b"TRACKED_CANDIDATE\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
