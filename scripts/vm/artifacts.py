#!/usr/bin/env python3
"""Offline pinned guest bootstrap verifier. No downloads."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile

VERSIONS = {'otp': '28.5.0.7', 'elixir': '1.19.6', 'node': '24.21.0', 'codex': '0.163.0'}
BINARIES = {'otp': '/usr/local/bin/erl', 'elixir': '/usr/local/bin/elixir',
            'node': '/usr/local/bin/node', 'codex': '/usr/local/bin/codex'}


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verified_manifest(path):
    data = json.loads(Path(path).read_text())
    if set(data) != set(VERSIONS):
        raise ValueError('manifest must supply exactly otp/elixir/node/codex')
    for name, version in VERSIONS.items():
        artifact = data[name]
        if artifact['version'] != version or not artifact.get('provenance'):
            raise ValueError('exact pinned version and outside-verified provenance are required')
        source = Path(artifact['path'])
        if not source.is_absolute() or not source.is_file() or source.is_symlink():
            raise ValueError('artifact input must be an existing absolute regular file')
        if not re.fullmatch(r'[a-f0-9]{64}', artifact['sha256']) or digest(source) != artifact['sha256']:
            raise ValueError('artifact SHA256 mismatch')
    entry = PurePosixPath(data['codex']['entry'])
    if entry.is_absolute() or '..' in entry.parts or str(entry) in ('', '.') or str(entry) != data['codex']['entry']:
        raise ValueError('codex entry must name its native executable in the normalized archive')
    with tarfile.open(data['codex']['path'], 'r:*') as archive:
        normalized_members(archive, 'codex', str(entry))
    return data


def normalized_members(archive, component, entry=None):
    members = []
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts:
            raise ValueError('unsafe artifact path')
        if not path.parts:
            if member.isdir():
                continue
            raise ValueError('invalid artifact root member')
        members.append(member)
    if not members:
        raise ValueError('artifact archive is empty')
    top = {PurePosixPath(member.name).parts[0] for member in members}
    # A directory wrapper has descendants. A single root-level executable is
    # payload, including the upstream Codex single-file release archive.
    wrapped = len(top) == 1 and any(len(PurePosixPath(member.name).parts) > 1 for member in members)
    if not wrapped and component != 'codex':
        raise ValueError('source/Node artifact must have one top-level directory')
    normalized = {}
    for original in members:
        member = copy.copy(original)
        parts = PurePosixPath(member.name).parts
        if wrapped:
            if len(parts) == 1:
                if not member.isdir():
                    raise ValueError('artifact wrapper must be a directory')
                continue
            parts = parts[1:]
        member.name = str(PurePosixPath(*parts))
        if member.name in normalized:
            raise ValueError('duplicate normalized artifact member')
        if member.islnk():
            linked = PurePosixPath(member.linkname)
            if linked.is_absolute() or '..' in linked.parts:
                raise ValueError('unsafe artifact hardlink')
            if wrapped:
                if len(linked.parts) < 2 or linked.parts[0] not in top:
                    raise ValueError('unsafe artifact hardlink')
                linked = PurePosixPath(*linked.parts[1:])
            member.linkname = str(linked)
        normalized[member.name] = member
    if component == 'codex':
        executable = normalized.get(entry)
        if executable is None or not executable.isfile() or executable.size == 0 or not executable.mode & 0o111:
            raise ValueError('codex entry must identify a nonempty regular executable in the archive')
        if any(normalized.get(str(parent)) is not None and not normalized[str(parent)].isdir()
               for parent in PurePosixPath(entry).parents if str(parent) != '.'):
            raise ValueError('codex entry cannot traverse archive links or files')
    return list(normalized.values())


def extract(data, name, target):
    target = Path(target)
    if target.exists() or target.is_symlink():
        raise FileExistsError('artifact extraction target exists; no replacement')
    with tarfile.open(data[name]['path'], 'r:*') as archive:
        members = normalized_members(archive, name, data[name].get('entry'))
        target.mkdir(mode=0o700)
        # Hardlink lookup must use the same normalized names as extraction.
        archive.members = members
        for member in members:
            archive.extract(member, target, filter='data')
    if name == 'codex':
        executable = target / data[name]['entry']
        if executable.is_symlink() or not executable.is_file() or not executable.resolve().is_relative_to(target.resolve()):
            raise ValueError('extracted Codex entry must be a confined regular file')


def receipt(path):
    result = {name: {'version': VERSIONS[name], 'binary': str(Path(binary).resolve()),
                     'binary_sha256': digest(binary)} for name, binary in BINARIES.items()}
    with Path(path).open('x') as stream:
        os.chmod(path, 0o600)
        json.dump(result, stream, indent=2)


def install_node(source, target):
    """Install the already verified/extracted tree without inheriting mode 0700."""
    target = Path(target)
    if target.exists() or target.is_symlink():
        raise FileExistsError('Node installation target exists; no replacement')
    shutil.copytree(source, target, symlinks=True)
    target.chmod(0o755)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=('verify', 'extract', 'receipt', 'install-node'))
    p.add_argument('path', type=Path)
    p.add_argument('--component', choices=VERSIONS)
    p.add_argument('--target', type=Path)
    p.add_argument('--apply', action='store_true')
    a = p.parse_args()
    if a.action == 'install-node':
        if not a.target:
            raise ValueError('Node installation requires --target')
        if a.apply:
            install_node(a.path, a.target)
        return
    if a.action == 'receipt':
        if a.apply:
            receipt(a.path)
        return
    data = verified_manifest(a.path)
    if a.action == 'extract':
        if not a.component or not a.target:
            raise ValueError('extraction needs --component and --target')
        if a.apply:
            extract(data, a.component, a.target)


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    main()
