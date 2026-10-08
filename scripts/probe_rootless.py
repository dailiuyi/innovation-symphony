#!/usr/bin/env python3
"""Fixed Linux acceptance probe, run inside the candidate's disposable container."""
import argparse
import errno
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import urllib.request

from sandbox_artifacts import save_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-sha", required=True)
    args = parser.parse_args()
    sha = subprocess.check_output(["git", "-C", "/workspace", "rev-parse", "HEAD"], text=True).strip()
    if sha != args.candidate_sha:
        raise ValueError("candidate identity mismatch")
    checks = {}
    checks["container_root"] = os.geteuid() == 0
    versions = subprocess.check_output(["elixir", "--version"], text=True, timeout=15)
    checks["toolchain_versions"] = "Elixir 1.19.5" in versions and "Erlang/OTP 28" in versions
    checks["native_client_version"] = subprocess.check_output(["/opt/codex", "--version"], text=True, timeout=15).strip() == "codex-cli 0.160.0"

    status = Path("/proc/self/status").read_text()
    capabilities = int(next(line.split()[1] for line in status.splitlines() if line.startswith("CapEff:")), 16)
    checks["no_network_admin_or_sys_admin"] = capabilities & ((1 << 12) | (1 << 21)) == 0
    for name, path in (("toolchain_readonly", "/opt/toolchain/.symphony-probe"),
                       ("metadata_readonly", "/workspace/.git/.symphony-probe"),
                       ("evidence_readonly", "/evidence/.symphony-probe")):
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except OSError as error:
            checks[name] = error.errno == errno.EROFS
        else:
            os.close(fd)
            os.unlink(path)
            checks[name] = False
    checks["no_host_auth"] = not Path("/root/.codex/auth.json").exists() and "SSH_AUTH_SOCK" not in os.environ
    with socket.socket() as service:
        service.bind(("127.0.0.1", 0))
        service.listen(1)
        with socket.create_connection(service.getsockname(), timeout=2):
            accepted, _ = service.accept()
            accepted.close()
        checks["internal_tcp"] = True
    for address in ("169.254.169.254", "100.127.255.1", "192.168.1.1", "10.0.0.1"):
        try:
            with socket.create_connection((address, 80), timeout=1):
                checks["blocked_" + address] = False
        except OSError:
            checks["blocked_" + address] = True
    try:
        with socket.create_connection(("2606:4700:4700::1111", 443), timeout=1):
            checks["ipv6_blocked"] = False
    except OSError:
        checks["ipv6_blocked"] = True
    with urllib.request.urlopen("https://example.com/", timeout=20) as response:
        checks["public_https"] = response.status == 200
    subprocess.run(["apt-get", "update"], check=True, timeout=90)
    subprocess.run(["apt-get", "install", "-y", "--no-install-recommends", "hello"], check=True, timeout=90)
    checks["apt_install"] = subprocess.run(["hello"], capture_output=True, check=True).returncode == 0
    directory = Path("/workspace/.check-evidence")
    directory.mkdir(exist_ok=True)
    target = Path(tempfile.mkdtemp(prefix="linux-probe-", dir=directory)) / "summary.json"
    save_json(target, dict(schema=1, candidate_sha=sha, checks=checks, passed=all(checks.values())))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
