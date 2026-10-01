#!/usr/bin/env python3
"""Prepare independent View evidence on synthetic copies; not a formal gate.

The caller must provide an independently frozen candidate. This script does not
activate a controller check_kind, dispatch tasks, install dependencies, or claim
Windows/WSL production acceptance. Its fixture worker is not an OS sandbox for
arbitrary hostile repositories; formal execution still needs the trusted runner.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import types

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SHA40 = re.compile(r'[0-9a-f]{40}\Z')
MAX_FILE_BYTES = 16 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return (json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')) + '\n').encode('utf-8')


def no_links(path):
    for item in [path.absolute(), *path.absolute().parents]:
        if item.is_symlink() or (hasattr(item, 'is_junction') and item.is_junction()):
            raise ValueError('linked paths are forbidden')


def read_file(path):
    no_links(path)
    if not path.is_file() or path.stat().st_size > MAX_FILE_BYTES:
        raise ValueError('missing, special, or oversized validation input')
    return path.read_bytes()


def reject_private_path(relative):
    parts = PurePosixPath(relative).parts
    if any(part.casefold() in ('.local', '.codex', '.aws') for part in parts):
        raise ValueError('private runtime/credential directories cannot enter validation inputs')
    if relative.casefold().endswith(('app/config.toml', 'app/config.json')) or parts[-1].casefold() in ('auth.json', 'credentials'):
        raise ValueError('runtime configuration cannot enter validation inputs')


def inventory(root, strict=False):
    no_links(root)
    rows = {}
    for base, dirs, files in os.walk(root, followlinks=False):
        if any(name.casefold() in ('.local', '.codex', '.aws') for name in dirs):
            raise ValueError('private runtime/credential directories cannot enter validation inputs')
        for name in dirs + files:
            no_links(Path(base) / name)
        dirs[:] = [name for name in dirs if name.casefold() != '.git' and (strict or name.casefold() != '__pycache__')]
        for name in files:
            path = Path(base) / name
            relative = path.relative_to(root).as_posix()
            if relative.casefold() == '.git' or (not strict and name.casefold().endswith('.pyc')):
                continue
            reject_private_path(relative)
            rows[relative] = digest(read_file(path))
    return rows


def git_bytes(root, *args, input_bytes=None, env=None):
    result = subprocess.run(['git', '--no-replace-objects', '--no-optional-locks', '-C', str(root), *args],
                            input=input_bytes, env=env, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Git read rejected: ' + result.stderr.decode('utf-8', 'replace'))
    return result.stdout


def git(root, *args):
    return git_bytes(root, *args).decode('utf-8', 'strict').strip()


def blob_oid(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode('ascii') + b'\0' + data).hexdigest()


def tree_path(raw):
    name = raw.decode('utf-8', 'strict')
    parts = PurePosixPath(name).parts
    if (not parts or name != '/'.join(parts) or name.startswith('/') or '\\' in name or ':' in name
            or any(part in ('.', '..') or part.casefold() == '.git' for part in parts)):
        raise ValueError('unsafe HEAD/index path')
    reject_private_path(name)
    return name


def head_files(root, sha):
    files = {}
    for row in git_bytes(root, 'ls-tree', '-r', '-z', '--full-tree', sha).split(b'\0'):
        if not row:
            continue
        metadata, raw = row.split(b'\t', 1)
        mode, kind, oid = metadata.decode('ascii').split()
        name = tree_path(raw)
        if mode not in ('100644', '100755') or kind != 'blob' or not SHA40.fullmatch(oid):
            raise ValueError('HEAD links, submodules, or special entries are forbidden')
        if name in files or name.casefold() in {item.casefold() for item in files}:
            raise ValueError('ambiguous HEAD paths')
        files[name] = {'mode': mode, 'oid': oid}
    if not files:
        raise ValueError('empty candidate HEAD')
    return files


def head_attributes(root, sha, files):
    """Evaluate only committed attributes in a new isolated synthetic Git repo.

    The candidate's worktree attributes, info/attributes, global attributes and
    clean filters are never used. check-attr parses metadata; no filter runs.
    """
    names = ('text', 'eol', 'filter', 'working-tree-encoding', 'ident')
    attributes = {name: dict.fromkeys(names, 'unspecified') for name in files}
    committed = [name for name in files if PurePosixPath(name).name == '.gitattributes']
    if not committed:
        return attributes
    with tempfile.TemporaryDirectory(prefix='validator-head-attributes-') as tmp:
        base = Path(tmp)
        isolated = base / 'attributes-only'
        isolated.mkdir()
        env = clean_environment(base)
        env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(base / 'absent-global-config'),
                   GIT_ATTR_NOSYSTEM='1', XDG_CONFIG_HOME=str(base / 'private-home'))
        git_bytes(isolated, 'init', env=env)
        for name in committed:
            data = git_bytes(root, 'cat-file', 'blob', files[name]['oid'])
            if len(data) > MAX_FILE_BYTES or blob_oid(data) != files[name]['oid']:
                raise ValueError('HEAD attribute blob is invalid')
            target = isolated / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        raw = git_bytes(isolated, 'check-attr', '-z', '--stdin', *names,
                        input_bytes=b''.join(name.encode('utf-8') + b'\0' for name in files), env=env)
        parts = raw.rstrip(b'\0').split(b'\0')
        if len(parts) != len(files) * len(names) * 3:
            raise ValueError('unknown or incomplete HEAD attributes')
        seen = set()
        for index in range(0, len(parts), 3):
            name, attr, value = (part.decode('utf-8', 'strict') for part in parts[index:index + 3])
            if name not in files or attr not in names or (name, attr) in seen:
                raise ValueError('ambiguous HEAD attributes')
            attributes[name][attr] = value
            seen.add((name, attr))
    for attrs in attributes.values():
        if (attrs['text'] not in ('unspecified', 'unset', 'set', 'auto')
                or attrs['eol'] not in ('unspecified', 'unset', 'lf', 'crlf')
                or any(attrs[key] not in ('unspecified', 'unset') for key in ('filter', 'working-tree-encoding', 'ident'))):
            raise ValueError('unsupported HEAD attributes; filters/encoding/ident are forbidden')
    return attributes


def candidate_identity(root, sha):
    if not SHA40.fullmatch(sha):
        raise ValueError('candidate SHA must be a full lowercase commit ID')
    no_links(root)
    if git(root, 'rev-parse', '--show-toplevel').replace('\\', '/').casefold() != root.resolve().as_posix().casefold():
        raise ValueError('candidate root must be the Git working tree root')
    if git(root, 'rev-parse', 'HEAD') != sha:
        raise ValueError('candidate HEAD differs from requested SHA')
    tracked = head_files(root, sha)
    attributes = head_attributes(root, sha, tracked)
    indexed = {}
    for row in git_bytes(root, 'ls-files', '--stage', '-z').split(b'\0'):
        if not row:
            continue
        metadata, raw = row.split(b'\t', 1)
        mode, oid, stage = metadata.decode('ascii').split()
        name = tree_path(raw)
        if stage != '0' or name in indexed:
            raise ValueError('candidate worktree is dirty; index has unresolved entries')
        indexed[name] = {'mode': mode, 'oid': oid}
    if indexed != tracked:
        raise ValueError('candidate worktree is dirty; index differs from HEAD')
    rows = inventory(root, strict=True)
    if rows.keys() != tracked.keys():
        raise ValueError('candidate worktree is dirty; disk file list differs from HEAD, including ignored files')
    normalization = {}
    for name, metadata in tracked.items():
        data = read_file(root / name)
        if digest(data) != rows[name]:
            raise ValueError('candidate changed while reading its identity')
        normalization[name] = 'none'
        if blob_oid(data) == metadata['oid']:
            continue
        attrs = attributes[name]
        text = attrs['text'] in ('set', 'auto') or (attrs['text'] == 'unspecified' and attrs['eol'] in ('lf', 'crlf'))
        if (text and b'\0' not in data and b'\r\n' in data and blob_oid(data.replace(b'\r\n', b'\n')) == metadata['oid']):
            normalization[name] = 'crlf-to-lf'
        else:
            raise ValueError('candidate worktree is dirty; working bytes differ from HEAD blob')
    if git(root, 'rev-parse', 'HEAD') != sha:
        raise ValueError('candidate HEAD changed while reading its identity')
    return {'sha': sha, 'tree': git(root, 'rev-parse', sha + '^{tree}'), 'files': rows,
            'head_blobs': tracked, 'head_attributes': attributes, 'normalization': normalization}


def stable(before, after, label):
    if before != after:
        raise ValueError(label + ' changed during validation; stale pass rejected')


def validate_python_report(report, minimum, expected_ids=()):
    python = report.get('python', {})
    if (report.get('passed') is not True or python.get('passed') is not True
            or not isinstance(python.get('tests'), int) or python['tests'] < minimum
            or len(python.get('identities', [])) != python['tests']
            or len(set(python.get('identities', []))) != python['tests']):
        raise ValueError('missing, zero, truncated, or contradictory Python report')
    for key in ('failures', 'errors', 'skipped', 'expected_failures', 'unexpected_successes'):
        if key not in python or python[key]:
            raise ValueError('Python failures/errors/skips cannot pass')
    if not set(expected_ids).issubset(python['identities']):
        raise ValueError('frozen Python identities were not all executed')


def validate_tap(text, minimum):
    counts = {}
    for key in ('tests', 'pass', 'fail', 'cancelled', 'skipped', 'todo'):
        values = re.findall(r'^# ' + key + r' (\d+)\s*$', text, re.MULTILINE)
        if len(values) != 1:
            raise ValueError('missing or ambiguous Node TAP summary')
        counts[key] = int(values[0])
    if (counts['tests'] < minimum or counts['pass'] != counts['tests']
            or any(counts[key] for key in ('fail', 'cancelled', 'skipped', 'todo'))):
        raise ValueError('Node zero tests/failures/skips cannot pass')
    return counts


def validate_render(report):
    rendered = report.get('render', {})
    expected = json.loads(read_file(HERE / 'fixtures' / 'acceptance.json'))
    names = sorted('context-' + item['id'] + '.html' for item in expected['sessions'])
    if (rendered.get('passed') is not True or rendered.get('self_check_rendered') is not True
            or rendered.get('tasks') != 1 or rendered.get('rounds') != 19
            or rendered.get('review_retries') != 4 or rendered.get('unassigned_sessions') != 1
            or rendered.get('html_pages') != names or rendered.get('wsl_executed') is not False
            or rendered.get('fixture_only') is not True):
        raise ValueError('render/task/round/retry/context evidence is incomplete')


def clean_environment(evidence):
    env = {key: os.environ[key] for key in ('PATH', 'SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT') if key in os.environ}
    private = evidence / 'private-home'
    private.mkdir()
    env.update(HOME=str(private), USERPROFILE=str(private), TEMP=str(private), TMP=str(private),
               APPDATA=str(private), LOCALAPPDATA=str(private), PYTHONDONTWRITEBYTECODE='1', PYTHONUTF8='1', NO_PROXY='*')
    return env


def command(args, cwd, evidence, env, label):
    entry = {'argv': [str(arg) for arg in args], 'cwd': str(cwd), 'timeout_seconds': 120}
    try:
        result = subprocess.run(entry['argv'], cwd=cwd, env=env, capture_output=True, timeout=120)
        out, err = result.stdout, result.stderr
        entry['returncode'] = result.returncode
    except subprocess.TimeoutExpired as exc:
        out, err = exc.stdout or b'', exc.stderr or b''
        entry.update(returncode=None, timed_out=True)
    (evidence / (label + '.stdout')).write_bytes(out)
    (evidence / (label + '.stderr')).write_bytes(err)
    entry.update(stdout={'bytes': len(out), 'sha256': digest(out)}, stderr={'bytes': len(err), 'sha256': digest(err)})
    (evidence / (label + '.command.json')).write_bytes(canonical(entry))
    if entry['returncode'] != 0:
        raise ValueError(label + ' command failed or timed out; raw output retained')
    return out.decode('utf-8', 'replace'), entry


def trusted_packager():
    path = HERE.parent / 'prepare_view_source.py'
    data = read_file(path)
    module = types.ModuleType('view_source_packager')
    module.__file__ = str(path)
    sys.modules[module.__name__] = module
    exec(compile(data, str(path), 'exec'), module.__dict__)
    return module, digest(data)


def check_paths(candidate, view, evidence):
    no_links(candidate)
    no_links(view)
    no_links(evidence)
    if view.resolve() != (candidate.resolve() / 'view') or not view.is_dir():
        raise ValueError('View must be the safe candidate/view directory')
    if evidence.exists() or evidence.resolve().is_relative_to(candidate.resolve()):
        raise ValueError('evidence must be a new directory outside the candidate')
    if any(part.casefold() == '.local' or part.casefold().startswith('innovation-symphony-v0')
           for part in evidence.absolute().parts):
        raise ValueError('evidence cannot target a live runtime directory')


def stage_inventory(stage):
    rows = {}
    for child in stage.iterdir():
        no_links(child)
        reject_private_path(child.name)
        if child.name.casefold() == '.git':
            raise ValueError('Git metadata cannot enter fixture source stages')
        if child.is_dir() and child.name in ('_tmp', 'build', 'fixture-runtime'):
            continue  # Only these directories are generated by the synthetic worker.
        if child.is_dir():
            rows.update({child.name + '/' + name: value for name, value in inventory(child, strict=True).items()})
        else:
            rows[child.name] = digest(read_file(child))
    return rows


def verify_stage(stage, expected):
    if stage_inventory(stage) != expected:
        raise ValueError('fixture stage source changed; executed source cannot bind to candidate SHA')


def copy_stage(view, destination, expected, frozen_tests=None):
    rows = inventory(view, strict=True)
    if rows != expected:
        raise ValueError('candidate View changed before copying its bound source')
    if any(name.split('/')[0].casefold() in ('build', 'data', 'prototypes', '.local') for name in rows):
        raise ValueError('runtime data cannot enter the source-only fixture stage')
    destination.mkdir()
    staged = dict(expected)
    for name, expected_hash in rows.items():
        data = read_file(view / name)
        if digest(data) != expected_hash:
            raise ValueError('candidate View changed while copying its bound source')
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    for name, data in (frozen_tests or {}).items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)  # Previously authenticated original package bytes.
        staged[name] = digest(data)
    verify_stage(destination, staged)
    return staged


def browser_inputs(evidence):
    """Bind all bytes the synthetic browser may consume, including extra files."""
    rows = {}
    for directory in ('frozen-stage/app/web', 'frozen-python/rendered'):
        for name in inventory(evidence / directory, strict=True):
            relative = directory + '/' + name
            data = read_file(evidence / relative)
            rows[relative] = {'bytes': len(data), 'sha256': digest(data)}
    expected = json.loads(read_file(HERE / 'fixtures' / 'acceptance.json'))
    names = {'frozen-python/rendered/context-' + item['id'] + '.html' for item in expected['sessions']}
    if {name for name in rows if name.startswith('frozen-python/rendered/')} != names:
        raise ValueError('browser rendered file list is not the complete fixed fixture')
    for relative in ('frozen-python/fixture-snapshot.json', 'frozen-python/fixture-contexts.json'):
        data = read_file(evidence / relative)
        rows[relative] = {'bytes': len(data), 'sha256': digest(data)}
    if 'frozen-stage/app/web/index.html' not in rows:
        raise ValueError('browser fixture web entrypoint is missing')
    return {'schema_version': 1, 'files': rows, 'sha256': digest(canonical(rows))}


def test_changes(original, candidate):
    names = {name for name in original.keys() | candidate.keys() if name.startswith('tests/')}
    return {name: {'source_sha256': digest(original[name]) if name in original else None,
                   'candidate_sha256': candidate.get(name)} for name in sorted(names)
            if candidate.get(name) != (digest(original[name]) if name in original else None)}


def validate(candidate, sha, view, package, source_manifest, evidence, node='node'):
    candidate, view, package, source_manifest, evidence = [Path(p).absolute() for p in (candidate, view, package, source_manifest, evidence)]
    check_paths(candidate, view, evidence)
    before = candidate_identity(candidate, sha)
    validator_before = inventory(HERE)
    packager, packager_hash = trusted_packager()
    manifest, original = packager.verify_package(package, source_manifest)
    if manifest['packager_sha256'] != packager_hash:
        raise ValueError('source package packager differs from this validation preparation')
    baseline = json.loads(read_file(HERE / 'frozen' / 'baseline.json'))
    frozen_test_bytes = {}
    for row in baseline['files']:
        data = read_file(HERE / 'frozen' / row['path'])
        if digest(data) != row['sha256'] or data != original[row['source_path']]:
            raise ValueError('frozen tests do not authenticate the pinned source package')
        frozen_test_bytes[row['source_path']] = original[row['source_path']]
    package_before = {'package': digest(read_file(package)), 'manifest': digest(read_file(source_manifest))}
    evidence.mkdir(parents=True)
    result = {'kind': 'view_validation_preparation', 'formal_acceptance': False, 'production_task': False,
              'preparation_pseudo_candidate': (candidate / 'PREPARATION_ONLY.json').is_file(),
              'passed': False, 'candidate_before': before, 'validator_files': validator_before,
              'validator_digest': digest(canonical(validator_before)), 'packager_sha256': packager_hash,
              'source_commit': manifest['source_commit'], 'source_tree': manifest['source_tree'],
              'source_package': package_before, 'commands': [], 'real_wsl_executed': False,
              'real_browser_executed': False, 'limitation': 'Fixture preparation only; trusted isolated formal runner and real Windows/WSL/UI acceptance remain required.'}
    result['candidate_test_changes'] = test_changes(original, inventory(view))
    try:
        env = clean_environment(evidence)
        expected_view = {name[len('view/'):]: value for name, value in before['files'].items() if name.startswith('view/')}
        stages = {}
        result['stage_source_bindings'] = {}
        for frozen in (True, False):
            label = 'frozen' if frozen else 'candidate'
            stage = evidence / (label + '-stage')
            stages[label] = copy_stage(view, stage, expected_view, frozen_test_bytes if frozen else None)
            result['stage_source_bindings'][label] = stages[label]
            run_dir = evidence / (label + '-python')
            run_dir.mkdir()
            argv = [sys.executable, '-I', '-B', HERE / 'worker.py', '--stage', stage,
                    '--fixture', HERE / 'fixtures' / 'acceptance.json', '--evidence', run_dir]
            if frozen:
                argv.append('--render')
            _, executed = command(argv, stage, run_dir, env, label)
            result['commands'].append(executed)
            verify_stage(stage, stages[label])
            report = json.loads(read_file(run_dir / 'worker-result.json'))
            validate_python_report(report, 16 if frozen else 1, baseline['python_identities'] if frozen else ())
            if frozen:
                validate_render(report)
            result[label + '_python'] = report
            js_files = sorted(path for path in (stage / 'tests').rglob('*')
                              if path.name.endswith(('.test.mjs', '.test.cjs', '.test.js')))
            if not js_files:
                raise ValueError('missing Node test files')
            output, executed = command([node, '--test', '--test-reporter=tap', *js_files], stage, run_dir, env, label + '-js')
            result['commands'].append(executed)
            result[label + '_javascript'] = validate_tap(output, 10 if frozen else 1)
            verify_stage(stage, stages[label])
        version, executed = command([node, '--version'], evidence, evidence, env, 'node-version')
        result['commands'].append(executed)
        result['node_version'] = version.strip()
        result['browser_inputs'] = browser_inputs(evidence)
        result['candidate_after'] = candidate_identity(candidate, sha)
        stable(before, result['candidate_after'], 'candidate')
        stable(validator_before, inventory(HERE), 'validator')
        stable(packager_hash, digest(read_file(HERE.parent / 'prepare_view_source.py')), 'packager')
        stable(package_before, {'package': digest(read_file(package)), 'manifest': digest(read_file(source_manifest))}, 'source package')
        stable(result['browser_inputs'], browser_inputs(evidence), 'browser fixture inputs')
        for label, expected in stages.items():
            verify_stage(evidence / (label + '-stage'), expected)
        result['passed'] = True
    except Exception as exc:
        result['error'] = f'{type(exc).__name__}: {exc}'
    (evidence / 'validation-result.json').write_bytes(canonical(result))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ('candidate-root', 'candidate-sha', 'view-root', 'source-package', 'source-manifest', 'evidence-root'):
        parser.add_argument('--' + flag, required=True)
    parser.add_argument('--node', default='node')
    args = parser.parse_args()
    try:
        result = validate(args.candidate_root, args.candidate_sha, args.view_root, args.source_package,
                          args.source_manifest, args.evidence_root, args.node)
        print(json.dumps({'kind': result['kind'], 'passed': result['passed'], 'formal_acceptance': False,
                          'preparation_pseudo_candidate': result['preparation_pseudo_candidate'],
                          'error': result.get('error'), 'evidence': str(Path(args.evidence_root).absolute())}, ensure_ascii=False))
        return 0 if result['passed'] else 1
    except Exception as exc:
        print(json.dumps({'kind': 'view_validation_preparation', 'passed': False, 'formal_acceptance': False,
                          'preparation_pseudo_candidate': False, 'error': str(exc)}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
