#!/usr/bin/env python3
"""Run frozen baseline tests against candidate lib in a disposable build tree.

For retained tasks pass --baseline explicitly, independently of runner installation.
The default remains this runner's repository for ordinary same-baseline use.
"""
import argparse
import shutil
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
from check_environment import isolated_environment
from check_results import run_check


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--baseline", type=Path, default=Path(__file__).resolve().parent.parent,
                        help="Frozen repository snapshot root (explicit for retained tasks)")
    parser.add_argument("--evidence-root", type=Path)
    parser.add_argument("--candidate-sha", help="Expected candidate HEAD; mismatch stops checks")
    options = parser.parse_args()
    candidate_root = options.candidate.resolve()
    candidate = candidate_root / "elixir"
    baseline = options.baseline.resolve() / "elixir"
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
        return run_check("baseline_test", ["mix", "test"], harness, isolated_environment(),
                         candidate_root=candidate_root, evidence_root=options.evidence_root,
                         candidate_sha=options.candidate_sha)


if __name__ == "__main__":
    sys.exit(main())
