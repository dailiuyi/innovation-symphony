#!/usr/bin/env python3
"""Refuse activation while a prior experimental task still owns host resources."""
import json
from pathlib import Path
import re
import subprocess


def main():
    group = Path('/sys/fs/cgroup/innovation-symphony-execution')
    pending = [str(path) for path in group.glob('symphony-*')] if group.exists() else []
    names = subprocess.check_output(['ip', 'netns', 'list'], text=True).splitlines()
    pending += [line for line in names if re.match(r'sn[0-9a-f]{8}(?: |$)', line)]
    tables = subprocess.check_output(['nft', '-j', 'list', 'tables'], text=True)
    for item in json.loads(tables).get('nftables', []):
        table = item.get('table', {})
        if re.fullmatch(r'sy[0-9a-f]{8}', table.get('name', '')):
            pending.append(table['name'])
    forwarding = subprocess.check_output(['iptables-save'], text=True)
    pending += [line for line in forwarding.splitlines() if re.search(r'-(?:i|o) sh[0-9a-f]{8}(?: |$)', line)]
    if pending:
        raise RuntimeError('Unresolved task resources retained; audit cleanup before starting: ' + ', '.join(pending))


if __name__ == '__main__':
    main()
