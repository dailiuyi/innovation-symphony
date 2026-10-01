#!/usr/bin/env python3
"""Trusted, offline View formal-code gate for the isolated controller sandbox."""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True

TRUSTED_ROOT = Path("/opt/symphony/scripts")
TRUSTED_RUNNER = TRUSTED_ROOT / "check_view_isolated.py"
VALIDATION_ROOT = TRUSTED_ROOT / "view_validation"
SOURCE_ROOT = VALIDATION_ROOT / "source"
SOURCE_PACKAGE = SOURCE_ROOT / "view-source.zip"
SOURCE_MANIFEST = SOURCE_ROOT / "source-manifest.json"
CANDIDATE_ROOT = Path("/workspace")
VIEW_ROOT = CANDIDATE_ROOT / "view"
EVIDENCE_MOUNT = Path("/evidence")
NODE = Path("/opt/toolchain/view-validation/node/bin/node")
SHA40 = re.compile(r"[0-9a-f]{40}\Z")
VIEWER_VERSION = "0.5.0"
NODE_VERSION = "v24.19.0"


class GateError(RuntimeError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _decode_mount_path(value: str) -> str:
    return re.sub(r"\\([0-7]{3})", lambda match: chr(int(match.group(1), 8)), value)


def mount_table(text: str | None = None) -> dict[str, list[set[str]]]:
    if text is None:
        text = Path("/proc/self/mountinfo").read_text(encoding="utf-8")
    mounts: dict[str, list[set[str]]] = {}
    for line in text.splitlines():
        left, separator, _right = line.partition(" - ")
        fields = left.split()
        if not separator or len(fields) < 6:
            raise GateError("malformed Linux mount information")
        mountpoint = _decode_mount_path(fields[4])
        mounts.setdefault(mountpoint, []).append(set(fields[5].split(",")))
    return mounts


def require_mount_mode(mounts: dict[str, list[set[str]]], path: str, readonly: bool) -> None:
    options = mounts.get(path, [])
    required = "ro" if readonly else "rw"
    forbidden = "rw" if readonly else "ro"
    if len(options) != 1 or required not in options[0] or forbidden in options[0]:
        mode = "read-only" if readonly else "writable"
        raise GateError(f"{path} is not one verified {mode} sandbox mount")


def network_isolation() -> dict[str, object]:
    interfaces = sorted(name for _index, name in socket.if_nameindex())
    if interfaces != ["lo"]:
        raise GateError("isolated network must expose only loopback")

    routes = Path("/proc/net/route").read_text(encoding="ascii").splitlines()[1:]
    default_v4 = []
    for row in routes:
        fields = row.split()
        if len(fields) >= 8 and fields[1] == "00000000" and fields[7] == "00000000":
            flags = int(fields[3], 16)
            if flags & 0x1 and not flags & 0x200:  # RTF_UP without RTF_REJECT.
                default_v4.append(fields[0])
    if default_v4:
        raise GateError("isolated network must not have an IPv4 default route")

    ipv6_path = Path("/proc/net/ipv6_route")
    default_v6 = []
    if ipv6_path.exists():
        for row in ipv6_path.read_text(encoding="ascii").splitlines():
            fields = row.split()
            if len(fields) >= 10 and fields[0] == "0" * 32 and fields[1] == "00":
                flags = int(fields[8], 16)
                if flags & 0x1 and not flags & 0x200:  # Ignore the kernel's unreachable reject placeholder.
                    default_v6.append(fields[0])
    if default_v6:
        raise GateError("isolated network must not have an IPv6 default route")
    return {"interfaces": interfaces, "ipv4_default_routes": default_v4,
            "ipv6_default_routes": default_v6, "network_namespace_isolated": True}


def verify_isolated_environment() -> dict[str, object]:
    if not sys.platform.startswith("linux"):
        raise GateError("trusted View gate requires the Linux execution sandbox")
    if Path.cwd().resolve() != CANDIDATE_ROOT.resolve():
        raise GateError("View gate must run with /workspace as its working directory")
    if Path(__file__).resolve() != TRUSTED_RUNNER:
        raise GateError("View gate did not start from the fixed trusted runner path")
    if not CANDIDATE_ROOT.is_dir() or not (CANDIDATE_ROOT / ".git").is_dir():
        raise GateError("/workspace and its Git metadata are required")
    if not EVIDENCE_MOUNT.is_dir() or not TRUSTED_ROOT.is_dir() or not NODE.is_file():
        raise GateError("controller evidence or fixed trusted tool paths are missing")

    mounts = mount_table()
    verify_mount_contract(mounts)

    network = network_isolation()
    return {"platform": sys.platform, "cwd": str(CANDIDATE_ROOT),
            "readonly_mounts": ["/workspace/.git", "/evidence", "/opt/symphony/scripts", "/opt/toolchain"],
            "writable_mounts": ["/workspace", "/tmp"], "network": network}


def verify_mount_contract(mounts: dict[str, list[set[str]]]) -> None:
    for path in ("/workspace/.git", "/evidence", "/opt/symphony/scripts", "/opt/toolchain"):
        require_mount_mode(mounts, path, readonly=True)
    for path in ("/workspace", "/tmp"):
        require_mount_mode(mounts, path, readonly=False)

def _load_validator():
    trusted_path = str(TRUSTED_ROOT)
    if trusted_path not in sys.path:
        sys.path.insert(0, trusted_path)
    from view_validation import validator
    return validator


def _source_identity(validator) -> dict[str, object]:
    for path in (SOURCE_ROOT, SOURCE_PACKAGE, SOURCE_MANIFEST):
        validator.no_links(path)
    if not SOURCE_ROOT.is_dir() or not SOURCE_PACKAGE.is_file() or not SOURCE_MANIFEST.is_file():
        raise GateError("fixed sanitized View source package or manifest is missing")
    return {"root": str(SOURCE_ROOT), "package": digest(validator.read_file(SOURCE_PACKAGE)),
            "manifest": digest(validator.read_file(SOURCE_MANIFEST))}


def _versions(validator) -> dict[str, object]:
    if sys.version_info < (3, 11):
        raise GateError("the isolated View gate requires Python 3.11 or newer")
    try:
        viewer = importlib.metadata.version("codex-transcript-viewer")
    except importlib.metadata.PackageNotFoundError as exc:
        raise GateError("codex-transcript-viewer dependency is missing") from exc
    if viewer != VIEWER_VERSION:
        raise GateError(f"codex-transcript-viewer must be {VIEWER_VERSION}")
    if not NODE.is_file() or not os.access(NODE, os.X_OK):
        raise GateError("fixed offline Node.js dependency is missing")

    env = {"PATH": "/usr/bin:/bin", "HOME": "/tmp", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
           "PYTHONDONTWRITEBYTECODE": "1", "PYTHONUTF8": "1", "NO_PROXY": "*"}
    result = subprocess.run([str(NODE), "--version"], cwd="/workspace", env=env,
                            capture_output=True, timeout=10, check=False)
    if result.returncode != 0:
        raise GateError("fixed offline Node.js version check failed")
    node = result.stdout.decode("ascii", "strict").strip()
    if node != NODE_VERSION:
        raise GateError(f"fixed offline Node.js must be {NODE_VERSION}")
    return {"python": sys.version, "codex-transcript-viewer": viewer, "node": node,
            "offline": True}


def _reserve_evidence_path() -> Path:
    root = Path(tempfile.mkdtemp(prefix="symphony-view-gate-", dir="/tmp"))
    if root.resolve().is_relative_to(CANDIDATE_ROOT.resolve()):
        shutil.rmtree(root)
        raise GateError("validation evidence must be outside /workspace")
    root.rmdir()
    return root


def _freeze_summary(validator, result: dict[str, object]) -> dict[str, object]:
    baseline = VALIDATION_ROOT / "frozen" / "baseline.json"
    fixture = VALIDATION_ROOT / "fixtures" / "acceptance.json"
    baseline_data = validator.read_file(baseline)
    baseline_value = json.loads(baseline_data)
    fixture_data = validator.read_file(fixture)
    validator_files = result.get("validator_files", {})
    return {
        "baseline_sha256": digest(baseline_data),
        "fixture_sha256": digest(fixture_data),
        "validator_sha256": result.get("validator_digest"),
        "validator_files": validator_files,
        "packager_sha256": result.get("packager_sha256"),
        "python_baseline_tests": 16,
        "javascript_baseline_tests": 10,
        "frozen_python_identities": baseline_value.get("python_identities", []),
    }


def verify_candidate_unchanged(validator, candidate: Path, sha: str,
                               before: dict[str, object]) -> dict[str, object]:
    after = validator.candidate_identity(candidate, sha)
    validator.stable(before, after, "candidate")
    return after


def remove_injected_elixir_dependencies(validator, candidate: Path, sha: str) -> None:
    # The shared launcher copies fixed Elixir dependencies into every disposable
    # workspace. View uses its separate toolchain and must compare only candidate
    # bytes with HEAD. Never remove a tracked candidate path or a linked parent.
    tracked = validator.head_files(candidate, sha)
    if any(name == "elixir/deps" or name.startswith("elixir/deps/") for name in tracked):
        raise GateError("candidate must not track injected Elixir dependencies")
    dependencies = candidate / "elixir" / "deps"
    validator.no_links(dependencies)
    if dependencies.exists():
        if not dependencies.is_dir():
            raise GateError("injected Elixir dependency path is not a directory")
        shutil.rmtree(dependencies)


def _javascript_report(report: object, minimum: int) -> None:
    if not isinstance(report, dict):
        raise GateError("missing Node TAP result")
    tests = report.get("tests")
    if (not isinstance(tests, int) or tests < minimum or report.get("pass") != tests
            or any(report.get(key) != 0 for key in ("fail", "cancelled", "skipped", "todo"))):
        raise GateError("Node TAP zero tests, failure, skip, or incomplete summary cannot pass")


def formal_code_result(validator, result: object, candidate_identity: dict[str, object],
                       source_identity: dict[str, object], tool_versions: dict[str, object]) -> bool:
    if not isinstance(result, dict) or result.get("passed") is not True or result.get("formal_acceptance") is not False:
        raise GateError("missing or contradictory independent View validation result")
    if result.get("real_wsl_executed") is not False or result.get("real_browser_executed") is not False:
        raise GateError("offline View gate cannot claim Windows/WSL or browser acceptance")
    baseline = json.loads(validator.read_file(VALIDATION_ROOT / "frozen" / "baseline.json"))
    validator.validate_python_report(result.get("frozen_python"), 16, baseline["python_identities"])
    validator.validate_python_report(result.get("candidate_python"), 1)
    validator.validate_render(result["frozen_python"])
    for label in ("frozen_python", "candidate_python"):
        dependencies = result[label].get("dependencies", {})
        if (dependencies.get("codex-transcript-viewer") != VIEWER_VERSION
                or dependencies.get("python") != tool_versions.get("python")):
            raise GateError(f"{label} did not report the fixed offline Python dependencies")
    _javascript_report(result.get("frozen_javascript"), 10)
    _javascript_report(result.get("candidate_javascript"), 1)
    if len(result.get("commands", [])) < 5:
        raise GateError("required frozen/candidate Python, JavaScript, and Node version reports are missing")
    if result.get("candidate_before") != result.get("candidate_after"):
        raise GateError("candidate identity changed during the independent validation")
    if result.get("candidate_before") != candidate_identity:
        raise GateError("independent validation report is bound to a different candidate")
    expected_source = {"package": source_identity["package"], "manifest": source_identity["manifest"]}
    if result.get("source_package") != expected_source:
        raise GateError("independent validation report is bound to a different source package")
    bindings = result.get("stage_source_bindings")
    if not isinstance(bindings, dict) or not {"frozen", "candidate"}.issubset(bindings):
        raise GateError("missing source bindings for frozen and candidate fixture stages")
    browser_inputs = result.get("browser_inputs")
    if not isinstance(browser_inputs, dict) or not re.fullmatch(r"[0-9a-f]{64}", browser_inputs.get("sha256", "")):
        raise GateError("missing browser fixture input digest")
    return True


def _copy_evidence(source: Path, candidate: Path, export_name: str) -> Path:
    evidence_root = candidate / ".check-evidence"
    stage = evidence_root / (".view-pending-" + os.urandom(12).hex())
    if not re.fullmatch(r"view-[0-9a-f]{12}-[0-9a-f]{16}", export_name):
        raise GateError("invalid View evidence export name")
    target = evidence_root / export_name
    evidence_root.mkdir(mode=0o700, exist_ok=True)
    if evidence_root.is_symlink() or stage.exists() or target.exists():
        raise GateError("unsafe or colliding View evidence destination")
    try:
        if source.is_symlink() or not source.is_dir():
            raise GateError("validation evidence root is missing or linked")
        for base, directories, files in os.walk(source, followlinks=False):
            for name in directories + files:
                path = Path(base) / name
                if path.is_symlink() or not (path.is_dir() or path.is_file()):
                    raise GateError("validation evidence contains a link or special file")
        shutil.copytree(source, stage, symlinks=True)
        for base, directories, files in os.walk(stage, followlinks=False):
            for name in directories + files:
                path = Path(base) / name
                if path.is_symlink() or not (path.is_dir() or path.is_file()):
                    raise GateError("copied validation evidence contains a link or special file")
        os.rename(stage, target)
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    return target


def run_gate(sha: str) -> tuple[dict[str, object], int]:
    if not SHA40.fullmatch(sha):
        raise GateError("candidate SHA must be a full lowercase commit ID")
    environment = verify_isolated_environment()
    validator = _load_validator()

    remove_injected_elixir_dependencies(validator, CANDIDATE_ROOT, sha)
    # No candidate evidence directory is made
    # until the identity has been checked before and after every trusted test.
    candidate_before = validator.candidate_identity(CANDIDATE_ROOT, sha)
    evidence_path = _reserve_evidence_path()
    started = int(time.time())
    validation: dict[str, object] | None = None
    error = None
    source = None
    versions = None
    try:
        source = _source_identity(validator)
        versions = _versions(validator)
        validation = validator.validate(CANDIDATE_ROOT, sha, VIEW_ROOT, SOURCE_PACKAGE, SOURCE_MANIFEST,
                                        evidence_path, node=str(NODE))
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"
        if not evidence_path.exists():
            evidence_path.mkdir(mode=0o700)

    gate: dict[str, object] = {
        "schema_version": 1,
        "kind": "controller_view_check",
        "controller_view_check": True,
        "passed": False,
        "formal_code_checks": False,
        "formal_acceptance": False,
        "real_windows_wsl_acceptance": False,
        "candidate_sha": sha,
        "candidate_tree": candidate_before["tree"],
        "candidate_files_sha256": digest(validator.canonical(candidate_before["files"])),
        "candidate_identity": candidate_before,
        "source": source,
        "freeze": _freeze_summary(validator, validation or {}),
        "tool_versions": versions,
        "execution": environment,
        "validation": validation,
        "error": error,
        "started_at_epoch": started,
        "finished_at_epoch": int(time.time()),
        "evidence_directory": str(evidence_path),
    }
    verify_candidate_unchanged(validator, CANDIDATE_ROOT, sha, candidate_before)
    if error is None:
        try:
            if source is None or versions is None:
                raise GateError("fixed source or offline tool versions were not verified")
            gate["formal_code_checks"] = formal_code_result(validator, validation, candidate_before, source, versions)
            gate["passed"] = gate["formal_code_checks"] is True
        except Exception as exc:
            gate["error"] = f"{type(exc).__name__}: {exc}"
    export_name = "view-" + sha[:12] + "-" + os.urandom(8).hex()
    gate["evidence_export"] = str(Path(".check-evidence") / export_name)
    gate["finished_at_epoch"] = int(time.time())
    (evidence_path / "gate-report.json").write_bytes(validator.canonical(gate))
    # The export path is created only after both identities have matched.
    _copy_evidence(evidence_path, CANDIDATE_ROOT, export_name)
    return gate, 0 if gate["passed"] is True else 1


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise GateError(message)


def main(argv: list[str] | None = None) -> int:
    parser = Parser(description=__doc__)
    parser.add_argument("--candidate-sha", required=True)
    try:
        args = parser.parse_args(argv)
        gate, status = run_gate(args.candidate_sha)
    except BaseException as exc:
        if isinstance(exc, KeyboardInterrupt):
            raise
        gate = {"schema_version": 1, "kind": "controller_view_check", "controller_view_check": True,
                "passed": False, "formal_code_checks": False, "formal_acceptance": False,
                "real_windows_wsl_acceptance": False, "candidate_sha": None,
                "error": f"{type(exc).__name__}: {exc}"}
        status = 1
    print(json.dumps(gate, ensure_ascii=False, sort_keys=True))
    return status


if __name__ == "__main__":
    raise SystemExit(main())
