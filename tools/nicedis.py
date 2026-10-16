#!/usr/bin/env python3
"""Disassemble NICE machine code.

The output is in the syntax of nice_cpu/assembler/niceasm.py, so that it
assembles to the same words again. An instruction that niceasm cannot write,
such as a reserved control word or one with an unused field that is not R0,
comes out as .DAT lines. The encoding is that of nice_cpu/doc/ISA.md §2-§5.

Usage: tools/nicedis.py FILE.bin

tools/nicemon.py uses disassemble() for its d and trace commands. Only the
Python standard library is used.
"""

import sys
from typing import Callable, Optional

MASK = 0xFFFFFFFF

ALU = ["MOVE", "SUB", "MDBL", "ADD", "DBL", "DEC", "NOT", "NOR",
       "IAND", "NAND", "XOR", "IOR", "XNOR", "AND", "ONE", "OR"]
# The shifts, with niceasm's aliases where there is one
SHIFT = ["SHL", "0<1", "0<C", "C<0", "C<1", "C<C", "ROL", "BPL",
         "SHR", "1>0", "C>0", "0>C", "1>C", "C>C", "ROR", "BPR"]
FLAGS = "1XCZNVEI"

# A function that names an address, such as a symbol, or returns None
Namer = Callable[[int], Optional[str]]


def operands(name: str) -> int:
    """The operands that niceasm takes for an ALU or SHIFT mnemonic."""
    if name == "ONE":
        return 1
    if name in ("MOVE", "DBL", "DEC", "NOT"):
        return 2
    return 3


def constant(c: int, namer: Optional[Namer]) -> str:
    name = namer(c) if namer else None
    if name:
        return name
    return f"0x{c:X}" if c > 9 else str(c)


def field(f: int, dest: bool, c: int, namer: Optional[Namer]) -> str:
    """The text of an operand field, with its constant word c."""
    mode, reg = f >> 4, f & 0xF
    r = f"R{reg}"
    if mode in (3, 7):
        text = constant(c, namer)
        if reg:
            text += f"[{r}]"
        return ("@" if mode == 7 else "") + text
    if dest:
        return [r, f"{r}--", f"{r}++", "", f"@{r}", f"@--{r}", f"@{r}++"][mode]
    return [r, f"--{r}", f"{r}++", "", f"@{r}", f"@--{r}", f"@{r}++"][mode]


def disassemble(words: list[int], namer: Optional[Namer] = None) -> tuple[str, int]:
    """The text of the instruction that starts at words[0], and how many
    words it takes. Missing constant words count as 0."""
    iw = words[0] & MASK
    neg, sel = iw >> 31, (iw >> 28) & 7
    cond = ""
    if neg or sel:
        cond = "?" + ("!" if neg else "") + FLAGS[sel] + " "

    def raw(n: int) -> tuple[str, int]:
        ws = (list(words[:n]) + [0] * n)[:n]
        return ".DAT " + ", ".join(f"0x{w & MASK:08X}" for w in ws), n

    if (iw >> 26) & 3 == 3:
        command, vector = (iw >> 21) & 0x1F, iw & 0xFF
        if (iw >> 8) & 0x1FFF == 0:
            if command == 0 and vector == 0:
                return cond + "HALT", 1
            if command == 1 and vector == 0:
                return cond + "RTI", 1
            if command == 2:
                return cond + f"INT {constant(vector, None)}", 1
        return raw(1)

    fields = [(iw >> 14) & 0x7F, (iw >> 7) & 0x7F, iw & 0x7F]
    length = 1 + sum(1 for f in fields if f >> 4 in (3, 7))
    consts = (list(words[1:length]) + [0] * 3)
    if iw >> 27 & 1:
        name = SHIFT[(iw >> 21) & 0xF]
        mods = "[M]" if iw >> 25 & 1 else ""
    else:
        name = ALU[(iw >> 21) & 0xF]
        mods = {0: "", 1: "[M]", 2: "[C]", 3: "[CM]"}[(iw >> 25) & 3]
    n = operands(name)
    # niceasm writes the unused fields as R0, so others cannot be written.
    if any(f != 0 for f in fields[n:]):
        return raw(length)
    texts = []
    k = 0
    for i, f in enumerate(fields[:n]):
        c = 0
        if f >> 4 in (3, 7):
            c = consts[k] & MASK
            k += 1
        texts.append(field(f, i == 0, c, namer))
    return f"{cond}{name}{mods} " + ", ".join(texts), length


def read_bin(path: str) -> dict[int, int]:
    """The words of a .bin file (ISA.md §10.4), by address."""
    words: dict[int, int] = {}
    with open(path) as f:
        for line in f:
            if line.strip():
                a, d = line.split()
                words[int(a, 16)] = int(d, 16)
    return words


def listing(words: dict[int, int]) -> list[tuple[int, str]]:
    """The lines that disassemble an image, each with its address: an
    instruction, a .DAT, or a .ORG where the addresses jump."""
    lines: list[tuple[int, str]] = []
    nxt = None
    for addr in sorted(words):
        if nxt is not None and addr < nxt:
            continue           # a constant word of the instruction before
        if addr != nxt:
            lines.append((addr, f".ORG    0x{addr:X}"))
        text, n = disassemble([words.get(addr + i, 0) for i in range(4)])
        if any(addr + i not in words for i in range(n)):
            # The constant words are missing: a word of data.
            text, n = f".DAT 0x{words[addr]:08X}", 1
        lines.append((addr, text))
        nxt = addr + n
    return lines


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1].startswith("-"):
        sys.exit(__doc__.strip().split("\n\n")[1].strip())
    words = read_bin(sys.argv[1])
    for addr, text in listing(words):
        if text.startswith(".ORG"):
            print(f"        {text}")
        else:
            print(f"        {text:<40}; {addr:08X}")


if __name__ == "__main__":
    main()
