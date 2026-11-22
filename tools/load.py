#!/usr/bin/env python3
"""The old name of "nicemon.py load", kept for one release (issue #156),
which V3.1 removes (issue #159). The module is tools/lib/load.py."""

import sys

import nicemon

if __name__ == "__main__":
    nicemon.old_name("load", sys.argv[1:])
