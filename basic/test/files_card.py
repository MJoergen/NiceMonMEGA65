#!/usr/bin/env python3
"""Put the programs' texts of the test files on a card (issue #60).

Usage: test/files_card.py IMG

IMG is a copy of ../monitor/build/fat/super.img, a FAT32 image with the
folder NICE. The script writes these files into NICE with mtools' mcopy,
as a PC writes them:
- PC.BAS: lines ended by CR LF, keywords in lower case, a TAB, a line of
  blanks, an empty line, a line that starts with blanks, and a last line
  with no end.
- BAD.BAS: a line, a line without a number, and a line after it, which
  LOAD does not reach.
- LONG.BAS: a line of 213 characters, whose tokens do not fit.
- WIDE.BAS: a line of 300 characters, more than a line of a file has.
- HIGH.BAS: a line with a byte from 0x80 in its string.
Only the Python standard library is used.
"""

import os
import subprocess
import sys
import tempfile

FILES = {
    "PC.BAS": b"10 rem written on a pc\r\n20\tfor i = 1 to 3 : print i; : next\r\n"
              b"   \r\n\r\n   30 print \"done\"\r\n40 end",
    "BAD.BAS": b"10 PRINT \"BEFORE\"\nPRINT \"NO NUMBER\"\n20 PRINT \"AFTER\"\n",
    "LONG.BAS": b"5 PRINT \"FIRST\"\n10 ? " + b".5," * 70 + b"\n",
    "WIDE.BAS": b"10 REM " + b"X" * 293 + b"\n",
    "HIGH.BAS": b"10 PRINT \"\xe9\"\n",
}


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(str(__doc__).split("\n\n")[1])
    img = sys.argv[1]
    with tempfile.TemporaryDirectory() as tmp:
        for name, data in FILES.items():
            path = os.path.join(tmp, name)
            with open(path, "wb") as f:
                f.write(data)
            subprocess.run(["mcopy", "-i", img, path, "::NICE/" + name], check=True)


if __name__ == "__main__":
    main()
