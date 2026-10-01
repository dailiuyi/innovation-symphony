"""Create a marked, entirely synthetic Git candidate and retain pipeline evidence."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import validator as v


def prepare(package, manifest, output):
    v.no_links(output)
    output.mkdir(parents=True, exist_ok=False)
    packager, _ = v.trusted_packager()
    candidate = output / 'pseudo-candidate'
    candidate.mkdir()
    (candidate / 'PREPARATION_ONLY.json').write_bytes(v.canonical({'kind': 'preparation-pseudo-candidate', 'production': False}))
    packager.extract_package(package, manifest, candidate / 'view')
    setup = output / 'git-setup'
    setup.mkdir()
    env = v.clean_environment(setup)
    env['GIT_CONFIG_NOSYSTEM'] = '1'
    env['GIT_CONFIG_GLOBAL'] = str(setup / 'absent-global-git-config')
    commands = [
        ['git', 'init', '--initial-branch=fixture', str(candidate)],
        ['git', '-C', str(candidate), 'add', '--', 'PREPARATION_ONLY.json', 'view'],
        ['git', '-C', str(candidate), '-c', 'user.name=PreparationFixture', '-c', 'user.email=fixture@example.invalid',
         'commit', '-m', 'Synthetic preparation candidate; no real task or repository commit'],
    ]
    for n, args in enumerate(commands):
        v.command(args, output, setup, env, 'git-' + str(n))
    sha = v.git(candidate, 'rev-parse', 'HEAD')
    positive = v.validate(candidate, sha, candidate / 'view', package, manifest, output / 'positive-evidence')
    if not positive['passed']:
        raise AssertionError('positive preparation pipeline failed: ' + str(positive.get('error')))

    original_command = v.command
    changed = False
    def mutate_after_success(*args, **kwargs):
        nonlocal changed
        result = original_command(*args, **kwargs)
        if args[-1] == 'candidate-js' and not changed:
            target = candidate / 'view' / 'app' / 'symphony_board' / 'derive.py'
            target.write_bytes(target.read_bytes() + b'\n# SYNTHETIC_CHANGE_AFTER_TEST_SUCCESS\n')
            changed = True
        return result
    with patch.object(v, 'command', mutate_after_success):
        negative = v.validate(candidate, sha, candidate / 'view', package, manifest, output / 'changed-candidate-evidence')
    if not changed or negative['passed'] or 'candidate worktree is dirty' not in negative.get('error', ''):
        raise AssertionError('candidate mutation did not reject stale pass')
    summary = {'kind': 'view_validation_pipeline_preparation', 'formal_acceptance': False,
               'preparation_pseudo_candidate': True, 'production_task': False,
               'positive_fixture_checks': positive['passed'], 'stale_pass_rejected': not negative['passed'],
               'candidate_sha': sha, 'source_package_sha256': v.digest(v.read_file(package)),
               'positive_evidence': str(output / 'positive-evidence'),
               'changed_candidate_evidence': str(output / 'changed-candidate-evidence'),
               'real_wsl_executed': False, 'real_browser_executed': False}
    (output / 'pipeline-summary.json').write_bytes(v.canonical(summary))
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-package', type=Path, required=True)
    parser.add_argument('--source-manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args.source_package.absolute(), args.source_manifest.absolute(), args.output.absolute())))
    except Exception as exc:
        report = {'kind': 'view_validation_pipeline_preparation', 'passed': False,
                  'formal_acceptance': False, 'preparation_pseudo_candidate': True, 'error': str(exc)}
        if args.output.is_dir():
            (args.output / 'pipeline-rejected.json').write_bytes(v.canonical(report))
        print(json.dumps(report))
        raise SystemExit(1)
