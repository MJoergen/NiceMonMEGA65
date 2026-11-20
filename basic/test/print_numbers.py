#!/usr/bin/env python3
"""Check what BASIC's PRINT shows of numbers against Python's doubles.

Usage: test/print_numbers.py NICEEMU ROM.bin

The ROM runs in niceemu with a line ? X for each case, and the line that
PRINT writes must be Python's double of X, written as C's %.15G
writes it, with -0 as 0 (doc/BASIC.md, "Numbers"). The FPU's DIGITS 15
rounds once, as %.15G does (nice_cpu#200), so every digit must be the
same. The cases, five fixed
and the rest from a fixed seed:

- the five numbers of nice_cpu#200's table, whose last digit DIGITS got
  wrong when it rounded twice, kept whatever the seed and the ranges;
- constants of 1 to 15 significant digits, with a point, an exponent,
  or neither, which PRINT gives back as their digits, so that each
  conversion is checked (nice_cpu's DEVICES.md 11.3, "15 digits come
  back"), and constants of 16 to 20 digits, rounded to 16;
- +, -, *, and / of two such constants, whose exponents stay where
  SCALE10 rounds once, and the signs;
- DIV, MOD, AND, OR, XOR, NOT, <<, and >> of signed words, and the six
  comparisons, which give -1 or 0;
- ABS, SGN, INT, and SQR, the last correctly rounded.

Exits with status 1 when a line differs. Only the Python standard
library is used.
"""

import math
import random
import subprocess
import sys
import tempfile
from typing import Callable, List, Tuple

SEED = 113
STEPS = 50_000_000
Case = Tuple[str, float]

# nice_cpu#200's five numbers, as the seed gave them: 0x447797CC23985DB1,
# 0xC2236069184B6D15, 0xC28E24F057F2473E, 0xBD5B8F411CF57545, and
# 0xC3A5BA823BE42EFE.
FIXED: List[Case] = [
    ("1006972011 * 6915199480000", 1006972011 * 6915199480000.0),
    ("-2.004651e-2 + -(4.1610939429693e10)", -2.004651e-2 + -4.1610939429693e10),
    ("-4143000000000 - -(6.07109495099155e3)", -4143000000000.0 - -6.07109495099155e3),
    ("3.8537896643634E-4 / -(984000000)", 3.8537896643634E-4 / -984000000.0),
    ("823599000 * -(950527510.48)", 823599000.0 * -950527510.48),
]


def fmt(x: float) -> str:
    """x as %.15G writes it, with -0 as 0."""
    return "0" if x == 0 else "%.15G" % x


def digits(r: random.Random, n: int) -> str:
    """n random digits, the first not 0."""
    return str(r.randint(1, 9)) + "".join(str(r.randint(0, 9)) for _ in range(n - 1))


def constant(r: random.Random, lo: int, hi: int, emin: int, emax: int) -> str:
    """A constant of lo to hi significant digits, with its first digit's
    exponent from emin to emax, typed as a whole number, with a point, or
    with an exponent."""
    d = digits(r, r.randint(lo, hi))
    e = r.randint(emin, emax)
    form = r.choice(("point", "exp", "whole"))
    if form == "whole" and 0 <= e < 20 and e + 1 >= len(d):
        return d + "0" * (e + 1 - len(d))
    if form == "point" and -6 <= e < 20:
        if e < 0:
            return "0." + "0" * (-e - 1) + d
        if e + 1 >= len(d):
            return d + "0" * (e + 1 - len(d)) + "."
        return d[:e + 1] + "." + d[e + 1:]
    m = d[0] + ("." + d[1:] if len(d) > 1 else "")
    return m + r.choice("Ee") + str(e)


def round16(text: str) -> float:
    """The constant text with its significant digits after the 16th
    rounding the 16th, half up, as BASIC reads it."""
    mant, _, exp = text.upper().partition("E")
    whole, _, frac = mant.partition(".")
    digs = (whole + frac).lstrip("0")
    point = len(whole.lstrip("0")) if whole.lstrip("0") else -(len(frac) - len(frac.lstrip("0")))
    e = point - 1 + (int(exp) if exp else 0)
    if len(digs) > 16:
        up = digs[16] >= "5"
        digs = str(int(digs[:16]) + up)
        if len(digs) > 16:
            digs, e = digs[:16], e + 1
    return float(digs + "E" + str(e - len(digs) + 1))


def cases() -> List[Case]:
    r = random.Random(SEED)
    out: List[Case] = list(FIXED)
    for _ in range(150):
        c = constant(r, 1, 15, -300, 300)
        out.append((c, float(c)))
    for _ in range(30):
        c = constant(r, 16, 20, -20, 20)
        out.append((c, round16(c)))
    ops: List[Tuple[str, Callable[[float, float], float]]] = [
        ("+", lambda a, b: a + b), ("-", lambda a, b: a - b),
        ("*", lambda a, b: a * b), ("/", lambda a, b: a / b)]
    for _ in range(150):
        a = constant(r, 1, 15, -6, 15)
        b = constant(r, 1, 15, -6, 15)
        name, f = r.choice(ops)
        sa, sb = r.choice(("", "-")), r.choice(("", "-"))
        x = float(sa + a)
        y = float(sb + b)
        out.append((f"{sa}{a} {name} {sb}({b})" if sb else f"{sa}{a} {name} {b}", f(x, y)))
    for _ in range(80):
        wa = r.randint(-2**31, 2**31 - 1)
        wb = r.choice((r.randint(-2**31, 2**31 - 1), r.randint(-100, 100) or 7))
        s = r.randint(0, 40)
        name = r.choice(("DIV", "MOD", "AND", "OR", "XOR", "NOT", "<<", ">>"))
        q = abs(wa) // abs(wb) * (1 if (wa < 0) == (wb < 0) else -1)
        val = {"DIV": q, "MOD": wa - q * wb, "AND": wa & wb, "OR": wa | wb, "XOR": wa ^ wb,
               "NOT": ~wa, "<<": signed((wa << s) & 0xFFFFFFFF) if s < 32 else 0,
               ">>": signed((wa & 0xFFFFFFFF) >> s) if s < 32 else 0}[name]
        text = {"NOT": f"NOT ({wa})", "<<": f"({wa}) << {s}", ">>": f"({wa}) >> {s}"}.get(
            name, f"({wa}) {name} ({wb})")
        out.append((text, float(val)))
    cmps: List[Tuple[str, Callable[[float, float], bool]]] = [
        ("=", lambda x, y: x == y), ("<>", lambda x, y: x != y),
        ("<", lambda x, y: x < y), (">", lambda x, y: x > y),
        ("<=", lambda x, y: x <= y), (">=", lambda x, y: x >= y)]
    for _ in range(40):
        a = constant(r, 1, 6, -2, 4)
        b = r.choice((constant(r, 1, 6, -2, 4), a))
        name, f2 = r.choice(cmps)
        out.append((f"{a} {name} {b}", -1.0 if f2(float(a), float(b)) else 0.0))
    for _ in range(60):
        a = r.choice(("", "-")) + constant(r, 1, 15, -10, 10)
        name = r.choice(("ABS", "SGN", "INT", "SQR"))
        x = float(a)
        if name == "SQR":
            a, x = a.lstrip("-"), abs(x)
            fval = math.sqrt(x)
        else:
            fval = {"ABS": abs(x), "SGN": float((x > 0) - (x < 0)),
                    "INT": float(math.floor(x))}[name]
        out.append((f"{name}({a})", fval))
    return out


def signed(w: int) -> int:
    return w - 2**32 if w & 0x80000000 else w


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(str(__doc__).split("\n\n")[1])
    emu, rom = sys.argv[1:]
    todo = cases()
    lines = "".join(f"?{text}\r" for text, _ in todo) + "halt\r"
    with tempfile.NamedTemporaryFile("w", suffix=".txt") as f:
        f.write(lines)
        f.flush()
        out = subprocess.run([emu, "-n", str(STEPS), "-i", f.name, rom],
                             capture_output=True, text=True).stdout.splitlines()
    shown = {}
    for i, line in enumerate(out[:-1]):
        if line.startswith("?"):
            shown[line[1:]] = out[i + 1]
    bad = 0
    for text, val in todo:
        want = fmt(val)
        got = shown.get(text)
        if got != want:
            print(f"FAIL numbers: ?{text} shows {got!r}, not {want!r}")
            bad += 1
    print(f"{'FAIL' if bad else 'PASS'} basic numbers: {len(todo) - bad} of {len(todo)}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
