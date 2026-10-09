#!/usr/bin/env python3
"""Fixed offline checks inside the task namespace; never use candidate aliases/policy."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from check_environment import check_resource_budget, isolated_environment
from check_results import run_check
from runtime_identity import native_client
from sandbox_artifacts import save_json

POLICY_FILES = ('mix.exs', 'mix.lock', '.credo.exs', '.formatter.exs', 'WORKFLOW.md')
CHECK_LOCK = Path('/tmp/symphony-heavy-check.lock')


@contextmanager
def heavy_check_slot(evidence: Path):
    """Queue whole candidate/baseline checks in this sandbox's private /tmp."""
    descriptor = os.open(CHECK_LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError('check queue lock must be a regular file')
        started = time.monotonic()
        print('[check queue] waiting for the task heavy-check slot', flush=True)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        (evidence / 'resources.json').write_text(json.dumps(dict(
            check_resource_budget(), queue_wait_ms=round((time.monotonic() - started) * 1000),
        ), indent=2) + '\n')
        print('[check queue] acquired the task heavy-check slot', flush=True)
        yield descriptor
    finally:
        # Never unlink a flock file: waiters must continue to lock the same inode.
        os.close(descriptor)


def copy_regular_tree(source: Path, target: Path) -> None:
    """Reject links before copying any candidate tree into the check harness."""
    if source.is_symlink() or not source.is_dir():
        raise ValueError(f'unsupported candidate directory: {source}')
    for path in source.rglob('*'):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError(f'unsupported candidate file: {path.relative_to(source)}')
    shutil.copytree(source, target, dirs_exist_ok=True)


# Operator-authorized fixture maintenance, 2026-10-08, GH-16. The frozen
# source stays immutable; only this exact historical fixture is repaired in
# the disposable baseline harness. No production code or assertions removed.
BASELINE_FIXTURE_SHA256 = 'a447f5010ee1c50f08e44d26e43d99b16f79c5114540dbd9ee5b7a2ef08f9191'
BASELINE_FIXTURE_PATH = 'elixir/test/symphony_elixir/mvp_execution_sandbox_test.exs'
BASELINE_FIXTURE_ANCHOR = '    File.write!(Path.join(workspace, "source.txt"), "original")\n'
BASELINE_FIXTURE_INSERT = (
    '    File.chmod!(Path.join(workspace, "source.txt"), 0o644)\n'
    '    assert Bitwise.band(File.stat!(Path.join(workspace, "source.txt")).mode, 0o777) == 0o644\n'
)


def maintain_baseline_fixture(baseline: Path, harness: Path, kind: str) -> list[dict]:
    """Normalize the known fixture input, never weaken its tamper assertions."""
    if kind != 'baseline':
        return []
    source, target = baseline / BASELINE_FIXTURE_PATH, harness / BASELINE_FIXTURE_PATH
    if not source.is_file() or source.is_symlink():
        return []
    original = source.read_bytes()
    if hashlib.sha256(original).hexdigest() != BASELINE_FIXTURE_SHA256:
        return []
    if target.is_symlink() or target.read_bytes() != original:
        raise ValueError('baseline maintenance target differs from frozen fixture')
    anchor = BASELINE_FIXTURE_ANCHOR.encode()
    if original.count(anchor) != 1:
        raise ValueError('baseline maintenance anchor is not unique')
    repaired = original.replace(anchor, anchor + BASELINE_FIXTURE_INSERT.encode(), 1)
    target.write_bytes(repaired)
    return [{'id': 'gh16-fixture-mode-20261008', 'path': BASELINE_FIXTURE_PATH,
             'scope': 'disposable_baseline_harness',
             'reason': 'initialize permission-tamper fixture to 0644 under umask 077',
             'frozen_sha256': BASELINE_FIXTURE_SHA256,
             'effective_sha256': hashlib.sha256(repaired).hexdigest(),
             'assertions_removed': False}]


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
    try:
        evidence = Path(tempfile.mkdtemp(prefix=options.kind + '-', dir=_evidence_root(candidate)))
        save_json(evidence / "native-client.json", native_client("/opt/codex"))
        with heavy_check_slot(evidence) as check_fd, \
             tempfile.TemporaryDirectory(prefix='symphony-check-') as directory, \
             tempfile.TemporaryDirectory(prefix='symphony-check-tmp-') as runtime_directory:
            harness = Path(directory)
            changes = prepare_harness(candidate, baseline, harness, options.kind)
            maintenance = maintain_baseline_fixture(baseline, harness, options.kind)
            (evidence / 'baseline-maintenance.json').write_text(json.dumps(
                {'repairs': maintenance}, indent=2) + '\n')
            if maintenance:
                print('[baseline maintenance] exact historical fixture initialized to 0644; frozen input preserved', flush=True)
            (evidence / 'policy.json').write_text(json.dumps({'policy_changes': changes}, indent=2) + '\n')
            if changes:
                print('Candidate gate configuration changed; frozen gate remains effective. Independent Review required.', flush=True)
            environment = isolated_environment()
            # VM-local counters are not unique across repeated check VMs. Keep
            # their fixtures private, and outside the entire source harness:
            # MVP state/workspace path checks must still reject source overlap.
            # A killed checker cannot make the next check reuse these fixtures.
            runtime_tmp = Path(runtime_directory)
            environment.update(MIX_ENV='test', HEX_OFFLINE='1', TMPDIR=str(runtime_tmp))
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
                                   candidate_sha=options.candidate_sha, serialization_fd=check_fd)
                if result:
                    failures.append(result)
                    # Unknown environment/report errors stop dependent checks. Ordinary code
                    # failures still allow the remaining independent diagnostics to report.
                    if result != 10:
                        break
            return 1 if 1 in failures else (10 if failures else 0)
    except (OSError, ValueError) as error:
        if "evidence" in locals():
            save_json(evidence / "result.json", dict(identity=dict(candidate_sha=options.candidate_sha), failure_category="environment", outcome=1, reason=str(error)))
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
