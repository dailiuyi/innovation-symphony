#!/usr/bin/env python3
"""Operator-owned check command; invoke the archived baseline copy."""
import subprocess
import sys
from pathlib import Path

from check_environment import isolated_environment


def main() -> None:
    candidate = Path(sys.argv[1]).resolve() / "elixir"
    environment = isolated_environment()
    for arguments in (
        ["deps", "get"],
        ["format", "--check-formatted"],
        ["lint"],
        ["test", "--cover"],
        ["dialyzer", "--format", "short"],
        ["build"],
    ):
        subprocess.run(["mix", *arguments], cwd=candidate, env=environment, check=True)


if __name__ == "__main__":
    main()
