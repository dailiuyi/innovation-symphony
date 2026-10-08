#!/usr/bin/env python3
"""Execute a check with an explicit native client and a disposable config HOME."""
import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import shutil
import tempfile

from check_environment import isolated_environment
from runtime_identity import native_client
from sandbox_artifacts import save_json


@contextmanager
def check_home(environment):
    with tempfile.TemporaryDirectory(prefix="symphony-check-home-") as directory:
        env = dict(environment)
        # Seed only dependency tooling/cache, never account or personal config files.
        mix = Path(directory) / '.mix'
        hexadecimal = Path(directory) / '.hex'
        for root, destination, names in (
                (Path(environment.get('MIX_HOME', str(Path.home() / '.mix'))), mix, ('archives', 'elixir')),
                (Path(environment.get('HEX_HOME', str(Path.home() / '.hex'))), hexadecimal, ('cache.ets', 'packages'))):
            destination.mkdir()
            for name in names:
                source = root / name
                if source.is_dir() and not source.is_symlink():
                    shutil.copytree(source, destination / name, symlinks=False)
                elif source.is_file() and not source.is_symlink():
                    shutil.copy2(source, destination / name)
        archives = Path(environment['MIX_ARCHIVES']) if environment.get('MIX_ARCHIVES') else None
        if archives and archives.is_dir():
            shutil.copytree(archives, mix / 'archives', dirs_exist_ok=True, symlinks=False)
        rebar = Path(environment['MIX_REBAR3']) if environment.get('MIX_REBAR3') else None
        env.pop('MIX_REBAR3', None)
        if rebar and rebar.is_file():
            shutil.copy2(rebar, mix / 'rebar3')
            env['MIX_REBAR3'] = str(mix / 'rebar3')
        env.pop('MIX_CONFIG', None)
        runtime_tmp = Path(directory) / 'tmp'
        runtime_tmp.mkdir()
        env.update(TMPDIR=str(runtime_tmp), XDG_CACHE_HOME=str(Path(directory) / '.cache'), MIX_HOME=str(mix), MIX_ARCHIVES=str(mix / 'archives'), HEX_HOME=str(hexadecimal), HOME=directory, CODEX_HOME=str(Path(directory) / ".codex"),
                   XDG_CONFIG_HOME=str(Path(directory) / ".config"))
        yield env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex")
    parser.add_argument("--identity", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    client = native_client(args.codex)
    if not args.command or args.command[0] != "--" or len(args.command) < 2:
        parser.error("check command must follow --")
    if args.identity:
        save_json(args.identity, client)
    with check_home(isolated_environment()) as environment:
        environment["SYMPHONY_TEST_CODEX"] = client["path"]
        return subprocess.call(args.command[1:], env=environment)


if __name__ == "__main__":
    raise SystemExit(main())
