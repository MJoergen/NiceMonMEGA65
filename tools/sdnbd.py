#!/usr/bin/env python3
"""The old name of "nicemon.py nbd", kept for one release (issue #156),
which V3.1 removes (issue #159). The module is tools/lib/sdnbd.py."""

import sys

import nicemon

if __name__ == "__main__":
    nicemon.old_name("nbd", sys.argv[1:])
