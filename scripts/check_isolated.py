#!/usr/bin/env python3
"""Fixed offline checks inside the task namespace; never use candidate aliases/policy."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile

sys.dont_write_bytecode = True
from check_environment import isolated_environment
from check_results import run_check

POLICY_FILES = ('mix.exs', 'mix.lock', '.credo.exs', '.formatter.exs', 'WORKFLOW.md')


def copy_regular_tree(source: Path, target: Path) -> None:
    """Reject links before copying any candidate tree into the check harness."""
    if source.is_symlink() or not source.is_dir():
        raise ValueError(f'unsupported candidate directory: {source}')
    for path in source.rglob('*'):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError(f'unsupported candidate file: {path.relative_to(source)}')
    shutil.copytree(source, target, dirs_exist_ok=True)


def prepare_harness(candidate: Path, baseline: Path, harness: Path, kind: str) -> list[dict]:
    """Use frozen project configuration with candidate code and selected tests."""
    project = harness / 'elixir'
    project.mkdir(parents=True)
    changes = []
    for name in POLICY_FILES:
        frozen, proposed = baseline / 'elixir' / name, candidate / 'elixir' / name
        if not frozen.exists() and not frozen.is_symlink() and name in ('.credo.exs', '.formatter.exs'):
            if proposed.exists() or proposed.is_symlink():
                changes.append({'path': f'elixir/{name}', 'effective_policy': 'frozen_default',
                                'baseline_sha256': None})
            continue
        if frozen.is_symlink() or not frozen.is_file():
            raise ValueError(f'missing frozen policy: {name}')
        shutil.copy2(frozen, project / name)
        if not proposed.is_file() or proposed.is_symlink() or proposed.read_bytes() != frozen.read_bytes():
            changes.append({'path': f'elixir/{name}', 'effective_policy': 'frozen',
                            'baseline_sha256': hashlib.sha256(frozen.read_bytes()).hexdigest()})
    for name in ('lib', 'priv'):
        copy_regular_tree(candidate / 'elixir' / name, project / name)
    test_source = baseline if kind == 'baseline' else candidate
    copy_regular_tree(test_source / 'elixir/test', project / 'test')
    # Test runtime configuration is also frozen; candidate changes remain visible to Review.
    copy_regular_tree(baseline / 'elixir/config', project / 'config')
    for directory in ('.github', 'docs'):
        if (candidate / directory).is_dir():
            copy_regular_tree(candidate / directory, harness / directory)
    for name in ('AGENTS.md', 'README.md', 'SPEC.md'):
        if (candidate / name).is_file():
            shutil.copy2(candidate / name, harness / name)
    dependencies = Path('/opt/deps')
    if not dependencies.is_dir():
        raise ValueError('trusted offline dependencies are unavailable')
    shutil.copytree(dependencies, project / 'deps', symlinks=False)
    return changes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind', choices=('candidate', 'baseline'))
    parser.add_argument('--candidate-sha')
    options = parser.parse_args()
    candidate, baseline = Path('/workspace'), Path('/baseline')
    evidence = Path(tempfile.mkdtemp(prefix=options.kind + '-', dir=_evidence_root(candidate)))
    try:
        with tempfile.TemporaryDirectory(prefix='symphony-check-') as directory:
            harness = Path(directory)
            changes = prepare_harness(candidate, baseline, harness, options.kind)
            (evidence / 'policy.json').write_text(json.dumps({'policy_changes': changes}, indent=2) + '\n')
            if changes:
                print('Candidate gate configuration changed; frozen gate remains effective. Independent Review required.', flush=True)
            environment = isolated_environment()
            environment.update(MIX_ENV='test', HEX_OFFLINE='1')
            steps = [('baseline_test', ['mix', 'test'])] if options.kind == 'baseline' else [
                ('format', ['mix', 'format', '--check-formatted']),
                ('lint', ['mix', 'specs.check']),
                ('credo', ['mix', 'credo', '--strict']),
                ('test', ['mix', 'test', '--cover']),
                ('dialyzer', ['mix', 'dialyzer', '--format', 'short']),
                ('build', ['mix', 'escript.build']),
            ]
            failures = []
            for stage, argv in steps:
                environment['MIX_ENV'] = 'dev' if stage in ('dialyzer', 'build') else 'test'
                result = run_check(stage, argv, harness / 'elixir', environment,
                                   candidate_root=candidate, evidence_root=evidence,
                                   candidate_sha=options.candidate_sha)
                if result:
                    failures.append(result)
                    # Unknown environment/report errors stop dependent checks. Ordinary code
                    # failures still allow the remaining independent diagnostics to report.
                    if result != 10:
                        break
            return 1 if 1 in failures else (10 if failures else 0)
    except (OSError, ValueError) as error:
        print(f'Isolated check setup failed: {error}', file=sys.stderr)
        return 1


def _evidence_root(candidate: Path) -> Path:
    root = candidate / '.check-evidence'
    if root.is_symlink():
        raise ValueError('evidence path must not be a link')
    root.mkdir(exist_ok=True)
    return root


if __name__ == '__main__':
    sys.exit(main())
