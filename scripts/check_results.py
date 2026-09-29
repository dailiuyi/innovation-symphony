"""Fixed-runner protocol: 0 passes, 10 is repairable, 1 stops.

Test classification requires a complete, identity-bound ExUnit event report.
Bindings prevent stale evidence reuse; the test VM is not a security sandbox.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

SUCCESS = 0
STOP = 1
REPAIRABLE = 10
FORMATTER = Path(__file__).resolve().with_name("check_formatter.exs")
TEST_STAGES = {"test", "baseline_test"}
_ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
_ENVIRONMENT_FAILURE = re.compile(
    r":(?:eperm|eacces|econnrefused|econnreset|enetunreach|ehostunreach|etimedout|enospc)\b"
    r"|permission denied|operation not permitted|connection refused|network is unreachable"
    r"|no space left on device|failed to create (?:scheduler|thread)|cannot allocate memory"
    r"|could not (?:start application|compile dependency|find (?:hex|rebar))"
    r"|unchecked dependencies|dependency .* is not available|dependencies have diverged"
    r"|failed to (?:fetch|connect)|TLS.*(?:alert|error)|certificate verify failed"
    r"|command not found|no such file or directory|ExUnit\.TimeoutError"
    r"|\btimed out\b|\bSIG(?:TERM|KILL|QUIT)\b", re.IGNORECASE,
)


def read_report(path: Path, identity: dict) -> dict:
    """Reject partial, duplicate, stale, inconsistent and unexplained events."""
    raw = path.read_bytes()
    if not raw.endswith(b"\n"):
        raise ValueError("truncated report")
    events = [json.loads(line, object_pairs_hook=_unique_fields) for line in raw.splitlines()]
    if len(events) < 2:
        raise ValueError("missing suite events")
    for sequence, event in enumerate(events):
        if not isinstance(event, dict):
            raise ValueError("invalid report event")
        if (event.get("identity") != identity or type(event.get("sequence")) is not int
                or event["sequence"] != sequence):
            raise ValueError("report identity or sequence mismatch")
    if events[0].get("event") != "suite_started" or events[-1].get("event") != "suite_finished":
        raise ValueError("missing suite boundary")
    counts = dict(total=0, passed=0, failed=0, skipped=0, excluded=0, invalid=0)
    failures, seen, tests = [], set(), []
    module_failures = []
    for event in events[1:-1]:
        if event.get("event") == "module_failed":
            if not isinstance(event.get("failures"), list) or not event["failures"]:
                raise ValueError("invalid module failure")
            module_failures.extend(event["failures"])
            continue
        if event.get("event") != "test_finished":
            raise ValueError("unknown or duplicate suite event")
        test_id, state = event["test_id"], event["state"]
        if test_id in seen or state not in counts or state == "total":
            raise ValueError("duplicate test or unknown state")
        seen.add(test_id)
        tests.append({"id": test_id, "state": state, "reason": event.get("reason")})
        counts["total"] += 1
        counts[state] += 1
        details = event["failures"]
        if not isinstance(details, list) or (state == "failed") != bool(details):
            raise ValueError("failure details contradict state")
        failures.extend(details)
    summary = events[-1].get("counts")
    if (summary != counts or not isinstance(summary, dict)
            or any(type(value) is not int for value in summary.values())):
        raise ValueError("suite counts mismatch")
    if counts["passed"] + counts["failed"] == 0:
        raise ValueError("zero executed tests")
    if counts["invalid"] or module_failures:
        raise ValueError("invalid tests or module failure")
    if any(not isinstance(failure, dict) or set(failure) != {"kind", "type"}
           or not all(isinstance(value, str) for value in failure.values()) for failure in failures):
        raise ValueError("invalid exception details")
    return {"counts": counts, "failures": failures, "tests": tests}


def _unique_fields(pairs: list[tuple]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON field")
        result[key] = value
    return result


def _before_test_execution(path: Path, identity: dict) -> bool:
    """Mix may announce the suite before compiling test files, but executes none."""
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return True
    if not raw:
        return True
    if not raw.endswith(b"\n"):
        raise ValueError("truncated report")
    events = [json.loads(line, object_pairs_hook=_unique_fields) for line in raw.splitlines()]
    expected = {"event": "suite_started", "sequence": 0, "identity": identity}
    return (len(events) == 1 and events[0] == expected
            and type(events[0]["sequence"]) is int)


def _project_compilation_error(text: str) -> bool:
    return bool(
        re.search(r"^== Compilation error in file (?:lib|test)/[^\n]+\.exs? ==$", text, re.MULTILINE)
        and re.search(r"^\*\* \((?:CompileError|SyntaxError|TokenMissingError|MismatchedDelimiterError)\)", text, re.MULTILINE)
    )


def classify_result(stage: str, returncode: int, output: str, report: dict | None = None, *,
                    test_execution_not_started: bool = False) -> tuple[int, str]:
    text = _ANSI.sub("", output)
    if stage in TEST_STAGES:
        if report is None:
            if (test_execution_not_started and returncode == 1 and not _ENVIRONMENT_FAILURE.search(text)
                    and _project_compilation_error(text)):
                return REPAIRABLE, "recognized project compilation failure before test execution"
            return STOP, "missing or invalid structured test report"
        if returncode not in {0, 2, 3}:
            return STOP, "unexpected test process exit"
        if returncode != 0 and _ENVIRONMENT_FAILURE.search(text):
            return STOP, "environment or timeout diagnostic"
        failures = report["failures"]
        if any(failure != {"kind": "error", "type": "ExUnit.AssertionError"} for failure in failures):
            return STOP, "unrecognized test exception"
        failed = report["counts"]["failed"]
        coverage = re.search(
            r"Coverage test failed, threshold not met:\s+Coverage:\s+([\d.]+)%"
            r"\s+Threshold:\s+([\d.]+)%", text,
        )
        if returncode == 0:
            counts = report["counts"]
            return ((STOP, "exit 0 contradicts failed tests or coverage") if failed or coverage
                    else (SUCCESS, "suite completed: " + ", ".join(
                        f"{name}={counts[name]}" for name in ("passed", "failed", "skipped", "excluded", "invalid"))))
        if returncode == 2:
            return (REPAIRABLE, "complete assertion failures") if failed else (STOP, "exit 2 without failed tests")
        if stage == "test" and coverage:
            try:
                actual, threshold = map(float, coverage.groups())
                if 0 <= actual < threshold == 100:
                    return REPAIRABLE, "coverage below required 100%" + (" and assertion failures" if failed else "")
            except ValueError:
                pass
        return STOP, "unexplained coverage exit or changed threshold"
    if returncode == 0:
        return SUCCESS, "process passed"
    if stage == "credo" and returncode in range(1, 32) and not _ENVIRONMENT_FAILURE.search(text):
        if re.search(r"found [1-9]\d* (?:code readability issue|refactoring opportunit|software design suggestion|warning)", text):
            return REPAIRABLE, "recognized Credo findings"
    if stage == "dialyzer" and returncode == 2 and not _ENVIRONMENT_FAILURE.search(text):
        if re.search(r"Total errors: [1-9]\d*", text) and "warnings were emitted" in text:
            return REPAIRABLE, "recognized Dialyzer findings"
    if returncode not in {1, 2, 3} or _ENVIRONMENT_FAILURE.search(text):
        return STOP, "environment diagnostic or unexpected process exit"
    if stage == "format" and returncode == 1:
        if ("mix format failed due to --check-formatted." in text
                and "The following files are not formatted:" in text):
            return REPAIRABLE, "recognized formatting failure"
    if stage == "lint" and returncode == 1:
        if (re.search(r"^lib/[^\n]+:\d+ missing @spec for .+", text, re.MULTILINE)
                and re.search(r"specs.check failed with [1-9]\d* missing @spec declaration\(s\)", text)):
            return REPAIRABLE, "recognized missing specification"
    if stage in {"lint", "build"} and returncode == 1:
        if _project_compilation_error(text):
            return REPAIRABLE, "recognized project compilation failure"
    return STOP, "unrecognized failure"


def classify(stage: str, returncode: int, output: str, report: dict | None = None) -> int:
    return classify_result(stage, returncode, output, report)[0]


def _runner_digest() -> str:
    digest = hashlib.sha256()
    for name in ("check_results.py", "check_environment.py", "check_candidate.py", "check_baseline.py", "check_isolated.py"):
        digest.update(name.encode())
        digest.update(Path(__file__).resolve().with_name(name).read_bytes())
    return digest.hexdigest()


def _save_json(path: Path, value: dict) -> None:
    with path.open("x", encoding="utf-8") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())


def run_check(stage: str, arguments: list[str], cwd: Path, environment: dict[str, str], *,
              candidate_root: Path | None = None, evidence_root: Path | None = None,
              candidate_sha: str | None = None) -> int:
    """Keep complete child output and an exclusive, persistent evidence directory."""
    run_id = uuid.uuid4().hex
    if evidence_root is not None:
        evidence_root = evidence_root.resolve()
        evidence_root.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix=f"{stage}-{run_id}-", dir=evidence_root))
    print(f"[check] stage={stage} run_id={run_id} evidence={evidence}", flush=True)
    child_exit, chunks, report = None, [], None
    result, reason, identity = STOP, "runner setup incomplete", None
    command = list(arguments)
    try:
        root = (candidate_root or cwd).resolve()
        actual_sha = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "--verify", "HEAD"], stderr=subprocess.PIPE, text=True,
        ).strip()
        if candidate_sha is not None and actual_sha != candidate_sha:
            raise ValueError("candidate SHA does not match HEAD")
        identity = dict(run_id=run_id, candidate_sha=actual_sha, stage=stage,
                        runner_digest=_runner_digest(), formatter_digest=hashlib.sha256(FORMATTER.read_bytes()).hexdigest())
        env = dict(environment)
        if stage in TEST_STAGES:
            if arguments[:2] != ["mix", "test"]:
                raise ValueError("test stage requires the fixed Mix test command")
            command = ["elixir", "-r", str(FORMATTER), "-S", "mix", *arguments[1:],
                       "--formatter", "ExUnit.CLIFormatter", "--formatter", "SymphonyChecks.Formatter"]
            env.update(SYMPHONY_CHECK_REPORT=str(evidence / "report.jsonl"),
                       SYMPHONY_CHECK_IDENTITY=json.dumps(identity, separators=(",", ":")))
        _save_json(evidence / "manifest.json", dict(identity=identity, command=command, cwd=str(cwd)))
        print(f"[check] stage={stage} command={' '.join(command)}", flush=True)
        with (evidence / "output.log").open("xb") as log:
            with subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
                while chunk := process.stdout.read1(65536):
                    log.write(chunk)
                    log.flush()
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                    chunks.append(chunk)
                child_exit = process.wait()
            log.flush()
            os.fsync(log.fileno())
        test_execution_not_started = False
        if stage in TEST_STAGES:
            report_path = evidence / "report.jsonl"
            test_execution_not_started = _before_test_execution(report_path, identity)
            if not test_execution_not_started:
                report = read_report(report_path, identity)
        result, reason = classify_result(stage, child_exit, b"".join(chunks).decode("utf-8", errors="replace"),
                                         report, test_execution_not_started=test_execution_not_started)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        reason = f"runner/report validation failed: {type(error).__name__}: {error}"
    _save_json(evidence / "result.json", dict(identity=identity, child_exit=child_exit, outcome=result, reason=reason,
                                             counts=report.get("counts") if report else None,
                                             tests=report.get("tests", []) if report else []))
    print(f"\n[check] stage={stage} child_exit={child_exit} outcome={result} reason={reason}", flush=True)
    return result
