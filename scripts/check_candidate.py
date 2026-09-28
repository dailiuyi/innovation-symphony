#!/usr/bin/env python3
"""Operator-owned check command; invoke the archived baseline copy."""
import subprocess
import sys
from pathlib import Path

candidate = Path(sys.argv[1]).resolve() / "elixir"
for arguments in (
    ["deps", "get"],
    ["format", "--check-formatted"],
    ["lint"],
    ["test", "--cover"],
    ["dialyzer", "--format", "short"],
    ["build"],
):
    subprocess.run(["mix", *arguments], cwd=candidate, check=True)
