#!/usr/bin/env python3
"""Run frozen baseline tests against candidate lib in a disposable build tree.

Use the copy from {baseline}, not the candidate copy. Linux/WSL, trusted repos only.
The controller additionally hashes the baseline before and after execution.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from check_environment import isolated_environment


def main() -> None:
    candidate = Path(sys.argv[1]).resolve() / "elixir"
    baseline = Path(__file__).resolve().parent.parent / "elixir"
    with tempfile.TemporaryDirectory(prefix="symphony-baseline-") as temporary:
        harness = Path(temporary) / "elixir"
        shutil.copytree(baseline, harness, ignore=shutil.ignore_patterns("deps", "_build", "cover", "bin"))
        # Removal is confined to a new TemporaryDirectory, never a checkout.
        shutil.rmtree(harness / "lib")
        shutil.copytree(candidate / "lib", harness / "lib")
        shutil.rmtree(harness / "priv")
        shutil.copytree(candidate / "priv", harness / "priv")
        shutil.copytree(candidate / "deps", harness / "deps", symlinks=True)
        template = baseline.parent / ".github" / "pull_request_template.md"
        (harness.parent / ".github").mkdir()
        shutil.copy2(template, harness.parent / ".github" / template.name)
        subprocess.run(["mix", "test"], cwd=harness, env=isolated_environment(), check=True)


if __name__ == "__main__":
    main()
