#!/usr/bin/env python3
"""Compatibility entry point for the private build helper's local verifier."""
from krystian_build import main

if __name__ == '__main__':
    raise SystemExit(main(['verify']))
