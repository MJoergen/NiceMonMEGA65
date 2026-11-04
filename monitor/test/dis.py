#!/usr/bin/env python3
"""Check the monitor's u, the disassembler, against nicedis.py and niceasm.

Usage: test/dis.py NICEEMU MONITOR.bin PROGRAM.bin

PROGRAM.bin is test/dis.nasm, assembled at 0x8000. The monitor runs in
niceemu with the program behind it and the commands u 8000 1, u and u
again, which go on after it with DIS_ROWS rows each, u ADDR N for the
rest, u 8000 0, which only sets the next address, and u. Each row must be the address, the
words of the instruction, blanks for the words it does not have, two
blanks, and its text. The text is nicedis.py's, but for the pairs of
words that u shows as CALL and RET, and the words that it shows as the
other pseudo-instructions of nice_cpu's ISA.md §10.1, NOP, JMP, PUSH,
POP, CLR, TST, and CMP, which nicedis.py does not: pseudo() rewrites
nicedis.py's text for those, in the order of the README. Those rows are
assembled with niceasm, which must give the words of the row. Each kind
of row, and each pseudo-instruction, must occur. Exits with status 1
when a check fails.
Only the Python standard library and nice_cpu's assembler are used.
"""

import os
import subprocess
import sys
import tempfile
from typing import Dict, List, Optional, Tuple

ASSEMBLER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                         "nice_cpu", "assembler")
sys.path.insert(0, ASSEMBLER)
import nicedis  # noqa: E402

DIS_ROWS = 20               # monitor.nasm, DIS_ROWS
START = 0x8000
STEPS = 20_000_000
ALWAYS = 0x0FFFFFFF         # the bits below the condition
RET = 0x0003F680            # MOVE R15, @R13++
PUSH = 0x0077580F           # ADD @--R13, n, R15


def call_or_ret(addr: int, words: Dict[int, int]) -> Optional[Tuple[int, str]]:
    """The words and text of the CALL or RET at addr (nice_cpu's ISA.md
    §10.1), or None if there is none."""
    w = words[addr]
    cond = condition(w)
    if w & ALWAYS == RET:
        return 1, cond + "RET"
    if w & ALWAYS != PUSH:
        return None
    m = words.get(addr + 2)
    if m is None or (m ^ w) >> 28 or m & 0x0FFFC07F != 0x0003C000:
        return None
    s0 = m >> 7 & 0x7F
    n = 2 if s0 & 0x30 == 0x30 else 1
    if words.get(addr + 1) != n or (n == 2 and addr + 3 not in words):
        return None
    op = nicedis.operand_text(nicedis.Operand(s0, words.get(addr + 3) if n == 2 else None,
                                              False, False), lambda v: None)
    return 2 + n, cond + "CALL " + op


def pseudo(text: str) -> Optional[str]:
    """nicedis.py's text of one instruction as the pseudo-instruction that
    u shows for it, the first of the README's order that matches, or None.
    The rules are those of ISA.md §10.1: no modifier but the [M] of TST
    and CMP, whose dest is R0. A .DAT, for an unused field that is not
    R0, matches none."""
    cond = text[:text.index(" ") + 1] if text.startswith("?") else ""
    insn = text[len(cond):]
    mnemonic, _, rest = insn.partition(" ")
    ops = rest.split(", ") if rest else []
    new = None
    if mnemonic == "MOVE" and len(ops) == 2:
        d, s = ops
        if d == "R0" and s == "R0":
            new = "NOP"
        elif d == "R15":
            new = "JMP " + s
        elif d == "@--R13":
            new = "PUSH " + s
        elif s == "@R13++":
            new = "POP " + d
        elif s == "R0":
            new = "CLR " + d
    elif mnemonic == "MOVE[M]" and len(ops) == 2 and ops[0] == "R0":
        new = "TST " + ops[1]
    elif mnemonic == "SUB[M]" and len(ops) == 3 and ops[0] == "R0":
        new = "CMP " + ops[1] + ", " + ops[2]
    return cond + new if new else None


def condition(word: int) -> str:
    c = nicedis.condition(word)
    return c + " " if c else ""


Row = Tuple[int, int, str, str]


def rows(words: Dict[int, int]) -> List[Row]:
    """The rows of u from START to the last word: the address, the number
    of words, the text, and the kind, 'call', 'ret', 'pseudo', or
    'dis'."""
    out = []
    addr, end = START, max(words) + 1
    while addr < end:
        special = call_or_ret(addr, words)
        if special:
            n, text = special
            kind = "ret" if text.endswith("RET") else "call"
        else:
            text, n = nicedis.disassemble(addr, words.get)
            kind = "dis"
            p = pseudo(text)
            if p:
                text, kind = p, "pseudo"
        out.append((addr, n, text, kind))
        addr += n
    return out


def row_text(row: Row, words: Dict[int, int]) -> str:
    addr, n, text, _ = row
    cols = "".join(f" {words[addr + i]:08x}" for i in range(n))
    return f"{addr:08x}{cols}{' ' * 9 * (4 - n)}  {text}"


def reassemble(niceasm: str, tmp: str, special: List[Row],
               words: Dict[int, int]) -> List[str]:
    """The rows of pseudo-instructions whose text does not assemble to
    their words, each at its own address."""
    src = os.path.join(tmp, "special.nasm")
    out = os.path.join(tmp, "special.bin")
    with open(src, "w") as f:
        for addr, _, text, _ in special:
            f.write(f"                .ORG    0x{addr:08x}\n                {text}\n")
    subprocess.run([sys.executable, niceasm, "-o", out, src], check=True)
    got = nicedis.read_bin(out)
    bad = []
    for addr, n, text, _ in special:
        if [got.get(addr + i) for i in range(n)] != [words[addr + i] for i in range(n)]:
            bad.append(f"{addr:08x} {text}")
    return bad


def main() -> None:
    emu, monitor, program = sys.argv[1:4]
    words = nicedis.read_bin(program)
    expected = rows(words)
    k = 1 + 2 * DIS_ROWS    # the rows of the first three commands
    assert len(expected) > k, "test/dis.nasm is too short"
    cmds = [("u 8000 1", expected[:1]), ("u", expected[1:1 + DIS_ROWS]),
            ("u", expected[1 + DIS_ROWS:k]),
            (f"u {expected[k][0]:x} {len(expected) - k:x}", expected[k:]),
            ("u 8000 0", []), ("u", expected[:DIS_ROWS])]
    fail = 0
    with tempfile.TemporaryDirectory() as tmp:
        full = os.path.join(tmp, "dis.full.bin")
        with open(full, "w") as f:
            f.write(open(monitor).read() + open(program).read())
        inp = os.path.join(tmp, "dis.txt")
        with open(inp, "w") as f:
            f.write("".join(c + "\r" for c, _ in cmds) + "h\r")
        run = subprocess.run([emu, "-n", str(STEPS), "-i", inp, full],
                             capture_output=True, text=True, check=False)
        lines = run.stdout.splitlines()  # text=True has made CR LF a new line
        got: List[Tuple[str, List[str]]] = []  # each command and the rows after it
        for line in lines:
            if line.startswith("> "):
                got.append((line[2:], []))
            elif got:
                got[-1][1].append(line)
        if [c for c, _ in got[:len(cmds)]] != [c for c, _ in cmds]:
            fail = 1
            print(f"FAIL monitor dis: the commands echoed are {[c for c, _ in got]}")
        for (c, want), (_, have) in zip(cmds, got):
            want_text = [row_text(r, words) for r in want]
            if have != want_text:
                fail = 1
                print(f"FAIL monitor dis: {c}")
                for i in range(max(len(want_text), len(have))):
                    w = want_text[i] if i < len(want_text) else "(none)"
                    h = have[i] if i < len(have) else "(none)"
                    if w != h:
                        print(f"  want {w}\n  got  {h}")
        special = [r for r in expected if r[3] != "dis"]
        for bad in reassemble(os.path.join(ASSEMBLER, "niceasm.py"), tmp,
                              special, words):
            fail = 1
            print(f"FAIL monitor dis: {bad} does not assemble to its words")
    kinds = {r[3] for r in expected}
    texts = " ".join(r[2] for r in expected)
    for need in ("call", "ret"):
        if need not in kinds:
            fail = 1
            print(f"FAIL monitor dis: no {need.upper()} row")
    shown = {r[2].split()[1 if r[2].startswith("?") else 0]
             for r in expected if r[3] == "pseudo"}
    for need in ("NOP", "JMP", "PUSH", "POP", "CLR", "TST", "CMP"):
        if need not in shown:
            fail = 1
            print(f"FAIL monitor dis: no {need} row")
    for need in (".DAT", "reserved control word", "(s1: ", "INT 255", "?!I", "[CM]", "BPR"):
        if need not in texts:
            fail = 1
            print(f"FAIL monitor dis: no row with {need}")
    if not fail:
        print(f"PASS monitor dis: {len(expected)} rows")
    sys.exit(fail)


if __name__ == "__main__":
    main()
