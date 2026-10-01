#!/usr/bin/env python3
"""Routing marker only; the controller replaces it with its trusted View gate."""
import sys


def main() -> int:
    print(
        "check_view.py is a controller routing marker and cannot run as a host check",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
