#!/usr/bin/env python3
"""Prepare a pinned, sanitized View source artifact; never dispatch a real task.

The CLI policy is fixed. The optional Policy argument exists for isolated tests,
not as a command-line override. Git blobs, rather than checkout files, are read.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import io
import json
import ntpath
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
SOURCE_COMMIT = 'd734a087d83243530bd79f40dfbaedaabf8fe677'
SOURCE_TREE = '8a61f1a9d1aa13b7e97e0143ff3a4a33f123d73a'
SOURCE_REPOSITORY = 'https://github.com/dailiuyi/innovation-view'
EXCLUDED_PATH = 'app/config.toml'
INTERNAL_MANIFEST = 'SOURCE_MANIFEST.json'
MAX_BYTES = 16 * 1024 * 1024
HEX40 = re.compile(r'[0-9a-f]{40}\Z')
HEX64 = re.compile(r'[0-9a-f]{64}\Z')
RESERVED = {'CON', 'PRN', 'AUX', 'NUL', *(f'COM{i}' for i in range(1, 10)),
            *(f'LPT{i}' for i in range(1, 10))}


@dataclass(frozen=True)
class Policy:
    commit: str = SOURCE_COMMIT
    tree: str = SOURCE_TREE
    repository: str = SOURCE_REPOSITORY


def canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n').encode('utf-8')


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_object(kind: str, data: bytes) -> str:
    return hashlib.sha1(kind.encode('ascii') + b' ' + str(len(data)).encode('ascii') + b'\0' + data).hexdigest()


def safe_name(name: str) -> str:
    if (not isinstance(name, str) or not name or '\\' in name or ntpath.splitdrive(name)[0]
            or name.startswith('/') or any(ord(c) < 32 for c in name)):
        raise ValueError('unsafe artifact path')
    parts = name.split('/')
    for part in parts:
        if (part in ('', '.', '..') or part.rstrip(' .') != part
                or any(c in part for c in ':<>"|?*') or part.split('.')[0].upper() in RESERVED):
            raise ValueError('unsafe artifact path')
    if PurePosixPath(name).as_posix() != name:
        raise ValueError('noncanonical artifact path')
    return name


def no_links(path: Path) -> None:
    absolute = path.absolute()
    for item in [absolute, *absolute.parents]:
        if item.is_symlink() or (hasattr(item, 'is_junction') and item.is_junction()):
            raise ValueError('linked artifact path is forbidden')


def regular_file(path: Path) -> bytes:
    no_links(path)
    if not path.is_file() or path.stat().st_size > MAX_BYTES:
        raise ValueError('missing or oversized artifact file')
    return path.read_bytes()


def git(repo: Path, *args: str) -> bytes:
    result = subprocess.run(['git', '--no-optional-locks', '-C', str(repo), *args],
                            capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError(f'Git read failed ({result.returncode}): {args[0]}')
    return result.stdout


def reconstruct_tree(entries: list[dict]) -> str:
    """Authenticate the entire tracked tree, including the excluded blob ID."""
    root: dict = {}
    seen: set[str] = set()
    for entry in entries:
        name = safe_name(entry['path'])
        if name.casefold() in seen:
            raise ValueError('duplicate or case-colliding path')
        seen.add(name.casefold())
        if entry['mode'] not in ('100644', '100755') or not HEX40.fullmatch(entry['git_oid']):
            raise ValueError('links, submodules, or invalid objects are forbidden')
        cursor = root
        parts = name.split('/')
        for part in parts[:-1]:
            cursor = cursor.setdefault(part, {})
            if not isinstance(cursor, dict):
                raise ValueError('file/directory collision')
        if parts[-1] in cursor:
            raise ValueError('file/directory collision')
        cursor[parts[-1]] = (entry['mode'], entry['git_oid'])

    def encode(tree: dict) -> str:
        records = []
        for name, value in tree.items():
            directory = isinstance(value, dict)
            mode, oid = ('40000', encode(value)) if directory else value
            key = name.encode('utf-8') + (b'/' if directory else b'')
            body = mode.encode('ascii') + b' ' + name.encode('utf-8') + b'\0' + bytes.fromhex(oid)
            records.append((key, body))
        return git_object('tree', b''.join(body for _, body in sorted(records)))
    return encode(root)


def source_document(repo: Path, policy: Policy) -> tuple[dict, dict[str, bytes]]:
    no_links(repo)
    if git(repo, 'rev-parse', 'HEAD').decode().strip() != policy.commit:
        raise ValueError('source HEAD differs from frozen commit')
    if git(repo, 'rev-parse', policy.commit + '^{tree}').decode().strip() != policy.tree:
        raise ValueError('source tree differs from frozen tree')
    included, excluded, files = [], [], {}
    total = 0
    records = git(repo, 'ls-tree', '-rz', '--full-tree', policy.commit).split(b'\0')
    for raw in records:
        if not raw:
            continue
        metadata, raw_name = raw.split(b'\t', 1)
        mode, kind, oid = metadata.decode('ascii').split(' ')
        name = safe_name(raw_name.decode('utf-8'))
        if kind != 'blob' or mode not in ('100644', '100755') or name == INTERNAL_MANIFEST:
            raise ValueError('unsupported tracked object')
        record = {'path': name, 'mode': mode, 'git_oid': oid}
        if name == EXCLUDED_PATH:
            excluded.append({**record, 'reason': 'runtime configuration; explicit exclusion', 'content_read': False})
            continue
        data = git(repo, 'cat-file', 'blob', oid)
        total += len(data)
        if total > MAX_BYTES or git_object('blob', data) != oid:
            raise ValueError('oversized or inconsistent source blob')
        files[name] = data
        included.append({**record, 'bytes': len(data), 'sha256': sha256(data)})
    if len(excluded) != 1 or reconstruct_tree(included + excluded) != policy.tree:
        raise ValueError('source inventory or mandatory exclusion is inconsistent')
    if 'app/config.example.toml' not in files:
        raise ValueError('configuration example must be retained')
    if git(repo, 'rev-parse', 'HEAD').decode().strip() != policy.commit:
        raise ValueError('source HEAD changed during export')
    document = {'schema_version': 1, 'source_repository': policy.repository,
                'source_commit': policy.commit, 'source_tree': policy.tree,
                'tracked_count': len(included) + len(excluded), 'included': sorted(included, key=lambda x: x['path']),
                'excluded': excluded, 'checkout_contents_used': False,
                'packager_sha256': sha256(Path(__file__).read_bytes())}
    return document, files


def zip_entry(name: str, data: bytes, mode: str = '100644') -> tuple[zipfile.ZipInfo, bytes]:
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.compress_type = zipfile.ZIP_STORED
    info.external_attr = int(mode, 8) << 16
    return info, data


def build(repo: Path, output: Path, policy: Policy = Policy()) -> dict:
    document, files = source_document(repo, policy)
    no_links(output)
    output.mkdir(parents=True, exist_ok=False)
    package = output / 'view-source.zip'
    with package.open('xb') as handle, zipfile.ZipFile(handle, 'w', compression=zipfile.ZIP_STORED) as archive:
        archive.writestr(*zip_entry(INTERNAL_MANIFEST, canonical(document)))
        modes = {x['path']: x['mode'] for x in document['included']}
        for name in sorted(files):
            archive.writestr(*zip_entry(name, files[name], modes[name]))
    packed = regular_file(package)
    manifest = {**document, 'archive': {'name': package.name, 'bytes': len(packed), 'sha256': sha256(packed)}}
    with (output / 'source-manifest.json').open('xb') as handle:
        handle.write(canonical(manifest))
    verify_package(package, output / 'source-manifest.json', policy)
    return manifest


def verify_package(package: Path, manifest_path: Path, policy: Policy = Policy()) -> tuple[dict, dict[str, bytes]]:
    packed = regular_file(package)
    manifest = json.loads(regular_file(manifest_path))
    declaration = manifest.get('archive', {})
    if (declaration != {'name': 'view-source.zip', 'bytes': len(packed), 'sha256': sha256(packed)}
            or manifest.get('schema_version') != 1 or manifest.get('source_commit') != policy.commit
            or manifest.get('source_repository') != policy.repository
            or manifest.get('source_tree') != policy.tree or not HEX64.fullmatch(manifest.get('packager_sha256', ''))):
        raise ValueError('package identity or digest mismatch')
    files, names, total = {}, set(), 0
    with zipfile.ZipFile(io.BytesIO(packed)) as archive:
        for info in archive.infolist():
            name = safe_name(info.filename)
            if (name.casefold() in names or info.is_dir() or info.flag_bits & 1
                    or info.compress_type != zipfile.ZIP_STORED or info.create_system != 3
                    or stat.S_IFMT(info.external_attr >> 16) != stat.S_IFREG):
                raise ValueError('unsafe archive entry')
            names.add(name.casefold())
            total += info.file_size
            if info.file_size > MAX_BYTES or total > MAX_BYTES:
                raise ValueError('oversized archive')
            files[name] = archive.read(info)
    embedded = {key: value for key, value in manifest.items() if key != 'archive'}
    if files.pop(INTERNAL_MANIFEST, None) != canonical(embedded):
        raise ValueError('embedded manifest differs from declaration')
    included, excluded = manifest.get('included', []), manifest.get('excluded', [])
    if (len(excluded) != 1 or excluded[0].get('path') != EXCLUDED_PATH
            or excluded[0].get('content_read') is not False or EXCLUDED_PATH in files
            or 'app/config.example.toml' not in files or manifest.get('checkout_contents_used') is not False
            or manifest.get('tracked_count') != len(included) + len(excluded)):
        raise ValueError('invalid inventory or configuration exclusion')
    if set(files) != {entry['path'] for entry in included}:
        raise ValueError('archive inventory mismatch')
    for entry in included:
        data = files[entry['path']]
        if (len(data) != entry['bytes'] or sha256(data) != entry['sha256']
                or git_object('blob', data) != entry['git_oid']):
            raise ValueError('source file digest mismatch')
    if reconstruct_tree(included + excluded) != policy.tree:
        raise ValueError('source inventory does not authenticate frozen Git tree')
    return manifest, files


def extract_package(package: Path, manifest_path: Path, destination: Path, policy: Policy = Policy()) -> dict:
    manifest, files = verify_package(package, manifest_path, policy)
    no_links(destination)
    destination.mkdir(parents=True, exist_ok=False)
    for name, data in files.items():
        target = destination.joinpath(*safe_name(name).split('/'))
        no_links(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as handle:
            handle.write(data)
    return manifest


def pseudo_task(package: Path, manifest_path: Path, root: Path, policy: Policy = Policy()) -> dict:
    """Exercise preseed/mkdir-preservation order only, outside any live receipt root."""
    root = root.absolute()
    no_links(root)
    if any(part.casefold() == '.local' or part.casefold().startswith('innovation-symphony-v0')
           for part in root.parts):
        raise ValueError('runtime or .local paths are not preparation isolation')
    manifest, _ = verify_package(package, manifest_path, policy)
    root.mkdir(parents=True, exist_ok=False)
    (root / 'PREPARATION_ONLY.json').write_bytes(canonical({'kind': 'pseudo-task', 'production': False}))
    evidence = root / 'pseudo-receipt.json.evidence'
    source = evidence / 'view-source'
    source.mkdir(parents=True)
    for src, name in [(package, 'view-source.zip'), (manifest_path, 'source-manifest.json')]:
        (source / name).write_bytes(regular_file(src))
    verify_package(source / 'view-source.zip', source / 'source-manifest.json', policy)
    seeded = sha256(regular_file(source / 'view-source.zip'))
    events = ['source_verified', 'source_preseeded', 'pseudo_claim_recorded']
    (root / 'pseudo-receipt.json').write_bytes(canonical({'kind': 'pseudo-task', 'production_claim': False,
        'execution_started': False, 'source_package_sha256': seeded}))
    # File.mkdir_p!(receipt <> ".evidence") has the same preservation contract.
    evidence.mkdir(parents=True, exist_ok=True)
    verify_package(source / 'view-source.zip', source / 'source-manifest.json', policy)
    if sha256(regular_file(source / 'view-source.zip')) != seeded:
        raise ValueError('preseed changed at pseudo claim')
    events.append('executor_mkdir_preserved_preseed')
    report = {'kind': 'preparation_pseudo_task', 'events': events, 'source_commit': policy.commit,
              'source_repository': policy.repository,
              'source_tree': policy.tree, 'source_package_sha256': manifest['archive']['sha256'],
              'execution_started': False, 'production_claim': False, 'sandbox_mount_executed': False,
              'formal_acceptance': False}
    (root / 'sequence.json').write_bytes(canonical(report))
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    export = commands.add_parser('build')
    export.add_argument('--repository', type=Path, required=True)
    export.add_argument('--output', type=Path, required=True)
    for name in ('verify', 'extract', 'pseudo-task'):
        command = commands.add_parser(name)
        command.add_argument('--package', type=Path, required=True)
        command.add_argument('--manifest', type=Path, required=True)
        if name == 'extract':
            command.add_argument('--destination', type=Path, required=True)
        if name == 'pseudo-task':
            command.add_argument('--isolated-root', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'build':
            report = build(args.repository, args.output)
        elif args.command == 'extract':
            report = extract_package(args.package, args.manifest, args.destination)
        elif args.command == 'pseudo-task':
            report = pseudo_task(args.package, args.manifest, args.isolated_root)
        else:
            report, _ = verify_package(args.package, args.manifest)
        print(json.dumps({'kind': 'preparation', 'formal_acceptance': False,
                          'source_repository': report['source_repository'],
                          'source_commit': report['source_commit'], 'source_tree': report['source_tree'],
                          'archive': report.get('archive'), 'events': report.get('events')}, ensure_ascii=False))
        return 0
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, zipfile.BadZipFile) as error:
        print(f'View source preparation failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
