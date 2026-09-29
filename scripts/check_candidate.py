#!/usr/bin/env python3
"""Operator-owned check command; invoke the archived baseline copy."""
import sys
from pathlib import Path

# The archived baseline is fingerprinted; imports must not create __pycache__.
sys.dont_write_bytecode = True
from check_environment import isolated_environment
from check_results import run_check


def main() -> int:
    candidate = Path(sys.argv[1]).resolve() / "elixir"
    environment = isolated_environment()
    for stage, arguments in (
        ("deps", ["deps", "get"]),
        ("format", ["format", "--check-formatted"]),
        ("lint", ["lint"]),
        ("test", ["test", "--cover"]),
        ("dialyzer", ["dialyzer", "--format", "short"]),
        ("build", ["build"]),
    ):
        result = run_check(stage, ["mix", *arguments], candidate, environment)
        if result:
            return result
    return 0


if __name__ == "__main__":
    sys.exit(main())
