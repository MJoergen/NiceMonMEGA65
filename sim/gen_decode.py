#!/usr/bin/env python3
"""The cases of tb_dbg_decode: instruction words, their constant words, and
the text that src/dbg/dbg_decode.vhd must write for them, which nicedis
writes (nice_cpu/assembler/nicedis.py).

Usage: gen_decode.py [--seed N] [--count N] > decode.txt

A line is the instruction word and three constant words in hex, then the
text, padded with spaces to LEN characters. A text longer than LEN ends in
> at the last place. A reserved control word is "reserved"."""

import argparse
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "nice_cpu", "assembler"))

import nicedis  # noqa: E402

LEN = 34


def text(word: int, consts: list) -> str:
    mem = {0: word, 1: consts[0], 2: consts[1], 3: consts[2]}
    insn = nicedis.decode(0, mem.get)
    if insn.reserved:
        s = "reserved"
    else:
        s = nicedis.statement(insn, lambda v: None)
    if len(s) > LEN:
        s = s[:LEN - 1] + ">"
    return s.ljust(LEN)


def const() -> int:
    """A constant word: small, an address, or any."""
    k = random.randrange(4)
    if k == 0:
        return random.randrange(16)
    if k == 1:
        return random.randrange(0x10000)
    if k == 2:
        return 0
    return random.randrange(1 << 32)


def field() -> int:
    """An operand field, with the modes and R0, R10, and R15 often."""
    reg = random.choice([0, 0, 1, 9, 10, 14, 15, random.randrange(16)])
    return random.randrange(8) << 4 | reg


def word() -> int:
    k = random.randrange(5)
    cond = random.randrange(16) << 28 if random.randrange(2) else 0
    if k == 0:
        return random.randrange(1 << 32)
    if k == 1:  # a valid control word
        cmd = random.randrange(3)
        vec = random.randrange(256) if cmd == 2 else 0
        return cond | 3 << 26 | cmd << 21 | vec
    # ALU or SHIFT, with fields of every mode
    cls = random.choice([0, 0, 2])
    mods = random.randrange(4)
    if cls == 2:
        mods &= 1
    return (cond | cls << 26 | mods << 25 | random.randrange(16) << 21 |
            field() << 14 | field() << 7 | field())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=3000)
    args = ap.parse_args()
    random.seed(args.seed)
    fixed = [0x00000000, 0x0C000000, 0x0C200000, 0x0C4000FF, 0x0C400000,
             0x8C000000, 0x0C000001, 0x0FE00000]
    # The longest: three constants of 8 digits with R10 to R15
    fixed.append(0x01 << 25 | 0x3 << 21 | 0x7F << 14 | 0x7E << 7 | 0x7D)
    for i in range(len(fixed) + args.count):
        w = fixed[i] if i < len(fixed) else word()
        c = [const() for _ in range(3)]
        print(f"{w:08X} {c[0]:08X} {c[1]:08X} {c[2]:08X} {text(w, c)}")


if __name__ == "__main__":
    main()
