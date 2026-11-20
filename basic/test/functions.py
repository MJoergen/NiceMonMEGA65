#!/usr/bin/env python3
"""Check BASIC's functions against Python's doubles, bit for bit.

Usage: test/functions.py NICEEMU ROM.bin

The ROM runs in niceemu with a line for each case, after a line that
makes the variables X, Y, and A, in that order, after a NEW, so that
their doubles are at 0x8000, 0x8004, and 0x8008 (doc/BASIC.md, "The
memory"). A case writes the bits of X, and of Y for ^, with POKE, so
that no constant is read, computes A, and prints A's two words with
PEEK. The cases (issue #117, stage 6), from a fixed seed:

- SIN, COS, and TAN of X up to 10^5, and from -10 to 10; ATAN of X of
  any size; ASIN and ACOS from -1 to 1; LOG, LOG2, and LOG10 of X from
  1E-300 to 1E300, and next to 1; EXP from -745 to 709; X ^ Y of a
  positive X, of a negative X to a whole Y, and whole powers, which are
  exact. Each must be within 1 ulp of Python's, as nice_cpu's
  DEVICES.md 11.3 bounds each function by 1 ulp of the exact value, and
  Python's math, the C library's, is within half an ulp of it but for
  rare arguments.
- PI, which must be math.pi.
- RND: its first numbers after the cold start, those after RND of a
  negative X, which seeds the generator with X's bits, and again, which
  gives the same, all exactly as the generator of 32 bits below gives
  them: a xorshift, and its word as the double 1.R in binary, less 1.

Exits with status 1 when a case differs. Only the Python standard
library is used.
"""

import math
import random
import struct
import subprocess
import sys
import tempfile
from typing import Callable, List, Optional, Tuple

SEED = 117
STEPS = 100_000_000
M32 = 0xFFFFFFFF
RND_SEED = 0x2545F491
# A case: the line typed, and the bits A must have, or None for those
# that RND's model gives, and the ulps that A may be off by
Case = Tuple[str, int, int]


def bits(x: float) -> int:
    return int(struct.unpack("<Q", struct.pack("<d", x))[0])


def key(b: int) -> int:
    """The bits of a double as an integer in the order of the doubles."""
    return b & 0x7FFFFFFFFFFFFFFF if b >> 63 == 0 else -(b & 0x7FFFFFFFFFFFFFFF)


def poke(addr: int, x: float) -> str:
    b = bits(x)
    return f"POKE 0x{addr:X},0x{b & M32:X}:POKE 0x{addr + 1:X},0x{b >> 32:X}:"


def show() -> str:
    return '?PEEK(0x8008);" ";PEEK(0x8009)'


def fn_case(name: str, f: Callable[[float], float], x: float) -> Case:
    return (poke(0x8000, x) + f"A={name}(X):" + show(), bits(f(x)), 1)


def pow_case(x: float, y: float, ulps: int = 1) -> Case:
    return (poke(0x8000, x) + poke(0x8004, y) + "A=X^Y:" + show(), bits(x ** y), ulps)


def xorshift(w: int) -> int:
    w ^= (w << 13) & M32
    w ^= w >> 17
    w ^= (w << 5) & M32
    return w


def rnd_value(w: int) -> float:
    one_r = struct.unpack("<d", struct.pack("<Q", (0x3FF00000 | w >> 12) << 32 | (w << 20) & M32))[0]
    return float(one_r) - 1.0


def rnd_cases() -> List[Case]:
    """RND's cases, which come first, as the generator starts at the cold
    start's word."""
    out: List[Case] = []
    w = RND_SEED
    for _ in range(3):
        w = xorshift(w)
        out.append(("A=RND(1):" + show(), bits(rnd_value(w)), 0))
    for x in (1.0, 12345.678, 1e-300):
        b = bits(-x)
        for _ in range(2):          # the same seed gives the same numbers
            w = (b ^ b >> 32) & M32 or RND_SEED
            w = xorshift(w)
            out.append((poke(0x8000, x) + "A=RND(-X):" + show(), bits(rnd_value(w)), 0))
            w = xorshift(w)
            out.append(("A=RND(5):" + show(), bits(rnd_value(w)), 0))
    return out


def log_uniform(r: random.Random, lo: float, hi: float) -> float:
    return math.exp(r.uniform(math.log(lo), math.log(hi)))


def cases() -> List[Case]:
    r = random.Random(SEED)
    out = rnd_cases()
    out.append(("A=PI:" + show(), bits(math.pi), 0))
    for name, f in (("SIN", math.sin), ("COS", math.cos), ("TAN", math.tan)):
        for _ in range(20):
            out.append(fn_case(name, f, r.uniform(-1e5, 1e5)))
            out.append(fn_case(name, f, r.uniform(-10, 10)))
    for _ in range(30):
        x = r.choice((1.0, -1.0)) * log_uniform(r, 1e-10, 1e10)
        out.append(fn_case("ATAN", math.atan, x))
        out.append(fn_case("ASIN", math.asin, r.uniform(-1, 1)))
        out.append(fn_case("ACOS", math.acos, r.uniform(-1, 1)))
    for name, f in (("LOG", math.log), ("LOG2", math.log2), ("LOG10", math.log10)):
        for _ in range(20):
            out.append(fn_case(name, f, log_uniform(r, 1e-300, 1e300)))
            out.append(fn_case(name, f, 1 + r.uniform(-1e-3, 1e-3)))
    for _ in range(30):
        out.append(fn_case("EXP", math.exp, r.uniform(-745, 709)))
    for _ in range(40):
        x = log_uniform(r, 1e-5, 1e5)
        lim = 1000 / abs(math.log2(x))
        out.append(pow_case(x, r.uniform(-lim, lim)))
    for _ in range(10):
        out.append(pow_case(-r.uniform(0.5, 20), float(r.randint(-60, 60))))
    for x, y in ((3.0, 4.0), (10.0, 22.0), (2.0, -1074.0), (-2.0, 3.0), (7.0, 0.0)):
        out.append(pow_case(x, y, 0))
    return out


def signed_pair(text: str) -> Optional[int]:
    """The double of the two words that a case's PEEKs print, or None."""
    parts = text.split()
    if len(parts) != 2:
        return None
    try:
        lo, hi = (int(p) & M32 for p in parts)
    except ValueError:
        return None
    return hi << 32 | lo


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(str(__doc__).split("\n\n")[1])
    emu, rom = sys.argv[1:]
    todo = cases()
    lines = "NEW\rX=0:Y=0:A=0\r" + "".join(f"{text}\r" for text, _, _ in todo) + "halt\r"
    with tempfile.NamedTemporaryFile("w", suffix=".txt") as f:
        f.write(lines)
        f.flush()
        out = subprocess.run([emu, "-n", str(STEPS), "-i", f.name, rom],
                             capture_output=True, text=True).stdout.splitlines()
    shown: List[Tuple[str, str]] = []
    for i, line in enumerate(out[:-1]):
        shown.append((line, out[i + 1]))
    # The cases in order: each line typed, and the line after it
    got: List[Optional[str]] = []
    j = 0
    for text, _, _ in todo:
        while j < len(shown) and shown[j][0] != text:
            j += 1
        got.append(shown[j][1] if j < len(shown) else None)
        j += 1
    bad = 0
    for (text, want, ulps), g in zip(todo, got):
        b = signed_pair(g) if g is not None else None
        if b is None or abs(key(b) - key(want)) > ulps:
            have = f"0x{b:016X}" if b is not None else repr(g)
            print(f"FAIL functions: {text} gives {have}, not 0x{want:016X}"
                  f"{f' within {ulps} ulp' if ulps else ''}")
            bad += 1
    print(f"{'FAIL' if bad else 'PASS'} basic functions: {len(todo) - bad} of {len(todo)}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
