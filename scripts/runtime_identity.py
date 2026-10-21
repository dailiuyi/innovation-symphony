"""Single native client contract for CI, local checks and isolated runners."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

MANIFEST = Path(__file__).with_name("runtime-identity.json")


def native_client(path=None):
    path = Path(path or os.environ.get("SYMPHONY_TEST_CODEX", "/opt/codex")).resolve(strict=True)
    with path.open("rb") as handle:
        if handle.read(4) != b"\x7fELF":
            raise ValueError("the fixed client must be a native Linux executable, not a PATH wrapper")
    if not os.access(path, os.X_OK):
        raise ValueError("native client is not executable")
    manifest = json.loads(MANIFEST.read_text())
    with tempfile.TemporaryDirectory(prefix="symphony-native-home-") as home:
        version = subprocess.check_output([str(path), "--version"], text=True, timeout=10, stderr=subprocess.PIPE,
                                          env={"PATH": "/usr/bin:/bin", "HOME": home, "CODEX_HOME": home}).strip()
    if version != "codex-cli " + manifest["codex"]["version"]:
        raise ValueError("native client version differs from the frozen runtime contract")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1048576):
            digest.update(chunk)
    return dict(path=str(path), version=version, sha256=digest.hexdigest(),
                protocol=manifest["protocol"])


def _erl(expression):
    return subprocess.check_output(["erl", "-noshell", "-eval", f'io:format("~s", [{expression}]), halt().'],
                                   text=True, timeout=60, stderr=subprocess.PIPE).strip()


def toolchain():
    """Elixir, OTP and GNU timeout on PATH must equal the frozen runtime contract."""
    manifest = json.loads(MANIFEST.read_text())
    # `elixir --version` only reports the OTP major; OTP_VERSION carries the patch level.
    otp = (Path(_erl("code:root_dir()")) / "releases" / _erl("erlang:system_info(otp_release)") / "OTP_VERSION").read_text().strip()
    elixir = subprocess.check_output(["elixir", "-e", "IO.write(System.version())"], text=True, timeout=60,
                                     stderr=subprocess.PIPE).strip()
    for name, actual in (("otp", otp), ("elixir", elixir)):
        if actual != manifest[name]:
            raise ValueError(f"{name} {actual} differs from the frozen runtime contract {manifest[name]}")
    if "GNU coreutils" not in subprocess.check_output(["timeout", "--version"], text=True, timeout=10):
        raise ValueError("GNU timeout is required by the retention and recovery checks")
    return dict(otp=otp, elixir=elixir)


if __name__ == "__main__":
    print(json.dumps(toolchain()))
