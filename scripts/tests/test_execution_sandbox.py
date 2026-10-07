"""Focused checks for the Linux execution sandbox launcher."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "execution_sandbox.sh"


class ExecutionSandboxCliTest(unittest.TestCase):
    def test_help_describes_host_only_result_and_bounded_workspace(self):
        result = subprocess.run(["bash", str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--scratch-root", result.stdout)
        self.assertIn("bounded tmpfs copy", result.stdout)
        self.assertIn("result.json", result.stdout)

    def test_unknown_mount_configuration_fails_before_environment_probe(self):
        result = subprocess.run(["bash", str(SCRIPT), "--bind-host", "/"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown option", result.stderr)

    @unittest.skipUnless(os.name == "posix" and os.environ.get("SYMPHONY_SANDBOX_INTEGRATION") == "1",
                         "set SYMPHONY_SANDBOX_INTEGRATION=1 in the provisioned Ubuntu runner")
    def test_isolated_command_exports_source_and_proves_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="symphony-sandbox-test-") as temp:
            root = Path(temp)
            workspace = root / "workspace"
            scratch = root / "scratch"
            toolchain = root / "toolchain"
            dependencies = root / "deps"
            trusted = root / "trusted"
            baseline = root / "baseline"
            evidence = root / "evidence"
            for path in (workspace / ".git", workspace / "elixir", toolchain / "data/installs/elixir/1.19.5-otp-28/bin",
                         toolchain / "data/installs/erlang/28.5/bin", dependencies, trusted / "scripts", baseline, evidence):
                path.mkdir(parents=True, exist_ok=True)
            (workspace / ".git" / "marker").write_text("protected", encoding="utf-8")
            host_secret = root / "host-secret"
            host_secret.write_text("fixture-host-secret", encoding="utf-8")
            host_secret.chmod(0o600)
            codex = root / "codex"
            codex.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            codex.chmod(0o700)
            command = ["/bin/sh", "-euc",
                       f"test \"$(readlink /proc/self/ns/net)\" != '{os.readlink('/proc/self/ns/net')}'; "
                       f"test -z \"${{CODEX_API_KEY:-}}\"; "
                       "test \"$ELIXIR_MAKE_CACHE_DIR\" = /home/coder/.cache/elixir_make; test -d \"$ELIXIR_MAKE_CACHE_DIR\"; "
                       f"test ! -r '{host_secret}'; "
                       "if printf bad 2>/dev/null > /workspace/.git/marker; then exit 41; fi; "
                       "python3 -c \"import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); "
                       "c=socket.create_connection(s.getsockname()); a,_=s.accept(); c.sendall(b'x'); "
                       "assert a.recv(1)==b'x'; c.close(); a.close(); s.close(); "
                       "s=socket.socket(); s.settimeout(.5); assert s.connect_ex(('198.51.100.1',9)) != 0; s.close()\"; "
                       "(sleep .2; printf late >> /workspace/late.txt) >/dev/null 2>&1 & "
                       "printf changed > /workspace/changed.txt; printf ready; printf diagnostic >&2"]
            env = dict(os.environ, CODEX_API_KEY="fixture-secret")
            result = subprocess.run(
                ["bash", str(SCRIPT), "--workspace", str(workspace), "--scratch-root", str(scratch),
                 "--toolchain", str(toolchain), "--codex", str(codex), "--trusted-root", str(trusted),
                 "--dependencies", str(dependencies), "--baseline", str(baseline), "--evidence", str(evidence),
                 "--timeout-seconds", "30", "--memory-mb", "1024", "--disk-mb", "512", "--pids", "32",
                 "--cpus", "1", "--", *command],
                capture_output=True, text=True, env=env, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "ready")
            self.assertEqual(result.stderr, "diagnostic")
            self.assertEqual((workspace / ".git" / "marker").read_text(encoding="utf-8"), "protected")
            self.assertEqual((scratch / "export" / "changed.txt").read_text(encoding="utf-8"), "changed")
            self.assertFalse((scratch / "export" / ".git").exists())
            time.sleep(0.3)
            self.assertFalse((scratch / "export" / "late.txt").exists(), "background child survived handoff")
            proof = json.loads((scratch / "result.json").read_text(encoding="utf-8"))
            self.assertEqual(proof["scratch_root"], str(scratch.resolve()))
            self.assertEqual(proof["exit_status"], 0)
            self.assertTrue(proof["cleanup_complete"])
            self.assertTrue(proof["export_complete"])
            self.assertEqual(proof["outcome"], "completed")

            # Review may read the candidate and use private temporary files,
            # but the kernel must deny writes even if a model asks for them.
            review_scratch = root / "review-scratch"
            review = subprocess.run(
                ["bash", str(SCRIPT), "--workspace", str(workspace), "--scratch-root", str(review_scratch),
                 "--toolchain", str(toolchain), "--codex", str(codex), "--trusted-root", str(trusted),
                 "--dependencies", str(dependencies), "--baseline", str(baseline), "--evidence", str(evidence),
                 "--timeout-seconds", "30", "--memory-mb", "1024", "--disk-mb", "512", "--pids", "32",
                 "--cpus", "1", "--read-only-workspace", "true", "--", "python3", "-c",
                 "import errno\nfrom pathlib import Path\n"
                 "Path('/tmp/review-private').write_text('ok')\n"
                 "try:\n Path('/workspace/forbidden').write_text('bad')\n"
                 "except OSError as e:\n assert e.errno == errno.EROFS\n"
                 "else:\n raise AssertionError('review workspace writable')\n"
                 "print('READ_ONLY_OK')"],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(review.returncode, 0, review.stderr)
            self.assertEqual(review.stdout.strip(), "READ_ONLY_OK")
            self.assertFalse((review_scratch / "export" / "forbidden").exists())
            review_proof = json.loads((review_scratch / "result.json").read_text())
            self.assertTrue(review_proof["cleanup_complete"])
            self.assertTrue(review_proof["export_complete"])

    @unittest.skipUnless(os.name == "posix" and os.environ.get("SYMPHONY_SANDBOX_INTEGRATION") == "1",
                         "set SYMPHONY_SANDBOX_INTEGRATION=1 in the provisioned Ubuntu runner")
    def test_timeout_output_pids_memory_and_disk_limits(self):
        with tempfile.TemporaryDirectory(prefix="symphony-sandbox-limits-") as temp:
            root = Path(temp)
            if shutil.disk_usage(root).free < 400 * 1024 * 1024:
                self.skipTest("need host scratch space for the bounded-export reserve")
            workspace = root / "workspace"
            scratch_parent = root / "runs"
            toolchain = root / "toolchain"
            dependencies, trusted, baseline, evidence = root / "deps", root / "trusted", root / "baseline", root / "evidence"
            for path in (workspace / ".git", workspace / "elixir", toolchain / "data/installs/elixir/1.19.5-otp-28/bin",
                         toolchain / "data/installs/erlang/28.5/bin", dependencies, trusted / "scripts", baseline, evidence):
                path.mkdir(parents=True, exist_ok=True)
            codex = root / "codex"
            codex.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            codex.chmod(0o700)

            def run_case(name, command, timeout="30", memory="512", disk="128", pids="64", env=None, expect_export=True):
                scratch = scratch_parent / name
                result = subprocess.run(
                    ["bash", str(SCRIPT), "--workspace", str(workspace), "--scratch-root", str(scratch),
                     "--toolchain", str(toolchain), "--codex", str(codex), "--trusted-root", str(trusted),
                     "--dependencies", str(dependencies), "--baseline", str(baseline), "--evidence", str(evidence),
                     "--timeout-seconds", timeout, "--memory-mb", memory, "--disk-mb", disk, "--pids", pids,
                     "--cpus", "1", "--", *command], capture_output=True, timeout=60, env=env)
                proof = json.loads((scratch / "result.json").read_text(encoding="utf-8"))
                self.assertEqual(proof["scratch_root"], str(scratch.resolve()))
                self.assertTrue(proof["cleanup_complete"])
                self.assertEqual(proof["export_complete"], expect_export)
                return result, proof

            # A broken toolchain must fail before this invocation creates a run cgroup.
            cgroup_parent = Path("/sys/fs/cgroup/innovation-symphony-execution")
            existing_groups = {path.name for path in cgroup_parent.glob("run-*")} if cgroup_parent.exists() else set()
            broken_toolchain = root / "broken-toolchain"
            broken_toolchain.mkdir()
            broken_run = subprocess.run(
                ["bash", str(SCRIPT), "--workspace", str(workspace), "--scratch-root", str(scratch_parent / "bad-toolchain"),
                 "--toolchain", str(broken_toolchain), "--codex", str(codex), "--trusted-root", str(trusted),
                 "--dependencies", str(dependencies), "--baseline", str(baseline), "--evidence", str(evidence),
                 "--timeout-seconds", "10", "--memory-mb", "512", "--disk-mb", "128", "--pids", "64",
                 "--cpus", "1", "--", "/bin/true"], capture_output=True, timeout=20)
            self.assertEqual(broken_run.returncode, 2, broken_run.stderr)
            remaining_groups = {path.name for path in cgroup_parent.glob("run-*")} if cgroup_parent.exists() else set()
            self.assertEqual(remaining_groups, existing_groups, "preflight failure left a run cgroup behind")

            cache = toolchain / "cache" / "elixir_make"
            cache.mkdir(parents=True)
            (cache / "fixture-cache.tar.gz").write_bytes(b"trusted-cache-fixture")
            cache_probe, _ = run_case("elixir-make-cache", ["/bin/sh", "-euc",
                "test \"$ELIXIR_MAKE_CACHE_DIR\" = /home/coder/.cache/elixir_make; "
                "test \"$(cat /home/coder/.cache/elixir_make/fixture-cache.tar.gz)\" = trusted-cache-fixture"])
            self.assertEqual(cache_probe.returncode, 0, cache_probe.stderr)

            timed, proof = run_case("timeout", ["/bin/sh", "-c", "sleep 20"], timeout="1")
            self.assertEqual(timed.returncode, 124, timed.stderr)
            self.assertEqual(proof["outcome"], "timeout")

            orphan_started = time.monotonic()
            orphan, proof = run_case("orphan-output", ["/bin/sh", "-c", "sleep 30 & exit 0"], timeout="20")
            self.assertEqual(orphan.returncode, 0, orphan.stderr)
            self.assertLess(time.monotonic() - orphan_started, 8, "inherited stdout kept the relay alive until timeout")
            self.assertTrue(proof["cleanup_complete"])
            self.assertTrue(proof["descendants_cleaned"])
            self.assertTrue(proof["background_output_closed"])
            self.assertEqual(proof["background_output_drain_grace_seconds"], 1)

            limited, proof = run_case("pids", ["/usr/bin/python3", "-c",
                "import os; kids=[]; "
                "exec('for _ in range(128):\\n try:\\n  p=os.fork()\\n except OSError:\\n  break\\n if p==0: os._exit(0)\\n kids.append(p)'); "
                "[os.waitpid(p,0) for p in kids]; assert len(kids)<128"], pids="16")
            self.assertEqual(limited.returncode, 0, limited.stderr)
            self.assertGreater(proof["resource_events"]["pids"].get("max", 0), 0)
            self.assertEqual(proof["resource_limits"]["cpu_max"], "100000 100000")

            memory, proof = run_case("memory", ["/usr/bin/python3", "-c", "bytearray(536870912)"], memory="128")
            self.assertNotEqual(memory.returncode, 0)
            self.assertGreater(proof["resource_events"]["memory"].get("oom_kill", 0), 0)

            disk, proof = run_case("disk", ["/bin/sh", "-euc",
                "python3 -c \"import os; s=os.statvfs('/workspace'); assert s.f_blocks*s.f_frsize <= 128*1024*1024\"; "
                "dd if=/dev/zero of=/workspace/full bs=1M count=256 status=none"], disk="128")
            self.assertNotEqual(disk.returncode, 0)
            self.assertIn("No space left", disk.stderr.decode(errors="replace"))

            noisy, proof = run_case("output", ["/usr/bin/python3", "-c", "import sys; sys.stdout.write('x'*67108865)"], memory="512")
            self.assertEqual(noisy.returncode, 125)
            self.assertEqual(len(noisy.stdout), 67108864)
            self.assertEqual(proof["outcome"], "output_limit_or_bootstrap_failure")

            fakebin = root / "fakebin"
            fakebin.mkdir()
            fake_tar = fakebin / "tar"
            timeout_log = root / "timeout-args"
            fake_timeout = fakebin / "timeout"
            fake_timeout.write_text("#!/bin/sh\nprintf '%s\\n' \"$4\" >> \"$TIMEOUT_LOG\"\nexec /usr/bin/timeout \"$@\"\n", encoding="utf-8")
            fake_timeout.chmod(0o700)
            fake_tar.write_text("#!/bin/sh\n/usr/bin/sleep 2\nexec /usr/bin/tar \"$@\"\n", encoding="utf-8")
            fake_tar.chmod(0o700)
            prep_timeout_started = time.monotonic()
            prep_timeout, proof = run_case("prep-operation-timeout", ["/bin/true"], timeout="1",
                                           env=dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ["PATH"],
                                                    TIMEOUT_LOG=str(timeout_log)), expect_export=False)
            self.assertEqual(prep_timeout.returncode, 125)
            self.assertEqual(proof["exit_status"], 124)
            self.assertEqual(proof["outcome"], "preparation_timeout")
            self.assertLess(time.monotonic() - prep_timeout_started, 8, "workspace preparation escaped its deadline")
            self.assertFalse(list((scratch_parent / "prep-operation-timeout").glob(".private.*")))

            fake_tar.write_text("#!/bin/sh\n/usr/bin/sleep 2\nexec /usr/bin/tar \"$@\"\n", encoding="utf-8")
            fake_tar.chmod(0o700)
            timeout_log.write_text("", encoding="utf-8")
            slow_env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ["PATH"], TIMEOUT_LOG=str(timeout_log))
            prep_started = time.monotonic()
            prep_budget, proof = run_case("prep-timeout", ["/bin/sh", "-c", "sleep 10"],
                                          timeout="4", env=slow_env)
            self.assertEqual(proof["exit_status"], 124)
            self.assertLess(time.monotonic() - prep_started, 7, "preparation reset the total timeout")
            timeout_values = [int(value) for value in timeout_log.read_text(encoding="utf-8").splitlines()]
            self.assertGreaterEqual(len(timeout_values), 2)
            self.assertLess(timeout_values[-1], timeout_values[0], "the command received a fresh timeout budget")
            self.assertEqual(proof["outcome"], "timeout")

            fake_tar.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            failed_env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ["PATH"])
            prep_failure, proof = run_case("prep-failure", ["/bin/true"], env=failed_env, expect_export=False)
            self.assertEqual(prep_failure.returncode, 125)
            self.assertEqual(proof["outcome"], "workspace_copy_failed")
            self.assertFalse(list((scratch_parent / "prep-failure").glob(".private.*")))


if __name__ == "__main__":
    unittest.main()
