"""Fixed-runner outcome protocol: 0 passes, 10 is repairable, 1 stops.

Diagnostics are an allowlist for the pinned Elixir 1.19 toolchain, not a
general-purpose interpretation of arbitrary command output. Unknown failures
remain stopped. The controller owns the deadline and kills the process group.
"""

import re
import subprocess
import sys
from pathlib import Path

SUCCESS = 0
STOP = 1
REPAIRABLE = 10

_ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
_ENVIRONMENT_FAILURE = re.compile(
    r":(?:eperm|eacces|econnrefused|econnreset|enetunreach|ehostunreach|etimedout|enospc)\b"
    r"|permission denied|operation not permitted|connection refused|network is unreachable"
    r"|no space left on device|failed to create (?:scheduler|thread)|cannot allocate memory"
    r"|could not (?:start application|compile dependency|find (?:hex|rebar))"
    r"|unchecked dependencies|dependency .* is not available|dependencies have diverged"
    r"|failed to (?:fetch|connect)|TLS.*(?:alert|error)|certificate verify failed"
    r"|command not found|no such file or directory|ExUnit\.TimeoutError"
    r"|\btimed out\b|\bSIG(?:TERM|KILL|QUIT)\b",
    re.IGNORECASE,
)
_TEST_SUMMARY = re.compile(r"^.*\b\d+ tests?, ([1-9]\d*) failures?\b", re.MULTILINE)
_ASSERTION = re.compile(
    r"^\s+(?:Assertion with \S+ failed|match \(=\) failed|Expected (?:truthy|false or nil), got"
    r"|Assertion failed|\*\* \(ExUnit\.AssertionError\))", re.MULTILINE
)


def _assertion_failures_only(text: str) -> bool:
    summary = _TEST_SUMMARY.search(text)
    failures = re.split(r"^\s{2}\d+\) [^\n]+\n", text, flags=re.MULTILINE)[1:]
    # One recognizable assertion is not enough to explain a mixed failed suite.
    return bool(summary and len(failures) == int(summary.group(1)) and all(
        _ASSERTION.search(failure)
        and not re.search(r"\*\* \((?!ExUnit\.AssertionError\))[^)]+\)", failure)
        for failure in failures
    ))


def classify(stage: str, returncode: int, output: str) -> int:
    """Require a known stage, normal exit code, and concrete failure evidence."""
    if returncode == 0:
        return SUCCESS
    text = _ANSI.sub("", output)
    if returncode not in {1, 2, 3} or _ENVIRONMENT_FAILURE.search(text):
        return STOP
    if stage == "format" and returncode == 1:
        if ("mix format failed due to --check-formatted." in text
                and "The following files are not formatted:" in text):
            return REPAIRABLE
    if stage in {"test", "baseline_test"}:
        if returncode == 2 and _assertion_failures_only(text):
            return REPAIRABLE
        # Mix.Tasks.Test.Coverage schedules exit 3 for this exact diagnostic.
        coverage = re.search(
            r"Coverage test failed, threshold not met:\s+Coverage:\s+([\d.]+)%"
            r"\s+Threshold:\s+([\d.]+)%", text
        )
        clean_suite = re.search(r"^.*\b\d+ tests?, 0 failures?\b", text, re.MULTILINE)
        invalid_suite = re.search(r"\b[1-9]\d* invalid\b", text)
        if (stage == "test" and returncode == 3 and coverage and not invalid_suite
                and (clean_suite or _assertion_failures_only(text))):
            try:
                actual, threshold = map(float, coverage.groups())
                if 0 <= actual < threshold <= 100:
                    return REPAIRABLE
            except ValueError:
                pass
    if stage == "lint" and returncode == 1:
        if (re.search(r"^lib/[^\n]+:\d+ missing @spec for .+", text, re.MULTILINE)
                and re.search(r"specs.check failed with [1-9]\d* missing @spec declaration\(s\)", text)):
            return REPAIRABLE
    if stage in {"lint", "test", "baseline_test", "build"} and returncode == 1:
        # Restrict compiler diagnostics to project source, never dependencies.
        if (re.search(r"^== Compilation error in file (?:lib|test)/[^\n]+\.exs? ==$", text, re.MULTILINE)
                and re.search(r"^\*\* \((?:CompileError|SyntaxError|TokenMissingError|MismatchedDelimiterError)\)",
                              text, re.MULTILINE)):
            return REPAIRABLE
    return STOP


def run_check(stage: str, arguments: list[str], cwd: Path, environment: dict[str, str]) -> int:
    """Forward all stdout/stderr bytes as they arrive; never keep only a tail."""
    print(f"[check] stage={stage} command={' '.join(arguments)}", flush=True)
    chunks = []
    try:
        with subprocess.Popen(arguments, cwd=cwd, env=environment,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
            while chunk := process.stdout.read1(65536):
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                chunks.append(chunk)
            returncode = process.wait()
    except OSError as error:
        print(f"[check] stage={stage} stopped: {error}", flush=True)
        return STOP
    result = classify(stage, returncode, b"".join(chunks).decode("utf-8", errors="replace"))
    print(f"\n[check] stage={stage} child_exit={returncode} outcome={result}", flush=True)
    return result
