#!/usr/bin/env python3
"""Operator-owned candidate checks; invoke the trusted installed copy."""
import argparse
import sys
from pathlib import Path

sys.dont_write_bytecode = True
from check_environment import isolated_environment
from check_results import run_check


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--evidence-root", type=Path)
    parser.add_argument("--candidate-sha", help="Expected HEAD; mismatch stops checks")
    options = parser.parse_args()
    candidate = options.candidate.resolve()
    environment = isolated_environment()
    for stage, arguments in (
        ("deps", ["deps", "get"]),
        ("format", ["format", "--check-formatted"]),
        ("lint", ["lint"]),
        ("test", ["test", "--cover"]),
        ("dialyzer", ["dialyzer", "--format", "short"]),
        ("build", ["build"]),
    ):
        result = run_check(stage, ["mix", *arguments], candidate / "elixir", environment,
                           candidate_root=candidate, evidence_root=options.evidence_root,
                           candidate_sha=options.candidate_sha)
        if result:
            return result
    return 0


if __name__ == "__main__":
    sys.exit(main())
