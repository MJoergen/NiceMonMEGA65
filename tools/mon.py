#!/usr/bin/env python3
"""The old name of "nicemon.py mon", kept for one release (issue #156),
which V3.1 removes (issue #159). The module is tools/lib/mon.py."""

import sys

import nicemon

if __name__ == "__main__":
    nicemon.old_name("mon", sys.argv[1:])
