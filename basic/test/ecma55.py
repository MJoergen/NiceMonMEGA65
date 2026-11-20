#!/usr/bin/env python3
"""Run the ECMA-55 conformance suite (NBS SP 500-70) on BASIC in niceemu.

Usage: test/ecma55.py NICEEMU ROM_TEST.bin CACHE EXPECTED OUT

The suite's 208 programs, P001.BAS to P208.BAS, come from bas55 2.0's
tests/, with the output that bas55 prints for each, P001.ok, and its
errors, P001.eok. The tarball is fetched into the directory CACHE the
first time, and checked against its SHA-256; only those files are taken
from it. Each program is typed into BASIC after a NEW, as its lines are,
and run with RUN, and the program's outcome is one line of OUT:

    P001 same                  the output is bas55's, but for blanks and
                               for numbers equal to 6 digits
    P009 differs               it ran to its end, with other output
    P044 failed                it printed its own TEST FAILED
    P016 error: Undefined line in 240   it stopped with that error
    P030 refused: 160 ...: Overflow     BASIC refused that line at entry
    P084 noend                 no end, as it waits for INPUT

and "; bas55 stops" after it when bas55 reports an error of the
program. A STOP's Break is an end. OUT is compared with EXPECTED, and a
change prints the lines that differ and exits with status 1. The counts
of each outcome are printed first. Only the Python standard library is
used.
"""

import hashlib
import os
import re
import subprocess
import sys
import tarfile
import urllib.request
from concurrent.futures import ThreadPoolExecutor

URL = "https://jorgicor.niobe.org/bas55/bas55-2.0.tar.gz"
SHA256 = "640b296df2ee22c2e14e90b23e0edad646682c80b3226652772847fa0614f293"
MAX_STEPS = "400000000"
NUM = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:E[-+]?\d+)?")
ERROR = re.compile(r"[A-Z][A-Za-z' ;]+ in \d+")
Token = tuple[str, str | float]


def fetch(cache: str) -> str:
    """The directory of the suite's files in CACHE, fetched and unpacked
    the first time."""
    tests = os.path.join(cache, "tests")
    if os.path.exists(os.path.join(tests, "P208.BAS")):
        return tests
    os.makedirs(tests, exist_ok=True)
    tgz = os.path.join(cache, os.path.basename(URL))
    if not os.path.exists(tgz):
        print(f"ecma55: fetching {URL}")
        req = urllib.request.Request(URL, headers={"User-Agent": "ecma55-test"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = resp.read()
        with open(tgz + ".part", "wb") as f:
            f.write(data)
        os.replace(tgz + ".part", tgz)
    with open(tgz, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    if digest != SHA256:
        os.remove(tgz)
        sys.exit(f"ecma55: {tgz} has SHA-256 {digest}, not {SHA256}")
    with tarfile.open(tgz, "r:gz") as tar:
        for m in tar.getmembers():
            name = os.path.basename(m.name)
            if not m.isfile() or not re.fullmatch(r"P\d{3}\.(BAS|ok|eok)", name):
                continue
            src = tar.extractfile(m)
            assert src is not None
            with open(os.path.join(tests, name), "wb") as f:
                f.write(src.read())
    return tests


def norm(text: str) -> list[Token]:
    """The text without blanks, as text and numbers."""
    toks: list[Token] = []
    for line in text.split("\n"):
        line = line.replace(" ", "")
        pos = 0
        for m in NUM.finditer(line):
            if m.start() > pos:
                toks.append(("t", line[pos:m.start()]))
            toks.append(("n", float(m.group())))
            pos = m.end()
        toks.append(("t", line[pos:] + "\n"))
    out: list[Token] = []
    for k, v in toks:
        if out and k == "t" and out[-1][0] == "t":
            out[-1] = ("t", str(out[-1][1]) + str(v))
        else:
            out.append((k, v))
    return out


def same(a: list[Token], b: list[Token]) -> bool:
    """Whether the texts are equal, with numbers equal to 6 digits."""
    if len(a) != len(b):
        return False
    for (ka, va), (kb, vb) in zip(a, b):
        if ka != kb:
            return False
        if isinstance(va, float) and isinstance(vb, float):
            if abs(va - vb) > 5e-6 * max(abs(va), abs(vb)):
                return False
        elif va != vb:
            return False
    return True


def outcome(emu: str, rom: str, tests: str, name: str) -> str:
    """The line of OUT of the program NAME."""
    with open(os.path.join(tests, name + ".BAS"), encoding="latin-1") as f:
        lines = [x.rstrip("\r\n") for x in f if x.strip()]
    keys = "\r".join(["NEW"] + lines + ["RUN", "HALT"]) + "\r"
    p = subprocess.run([emu, "-n", MAX_STEPS, "-i", "-", rom],
                       input=keys.encode("latin-1"), capture_output=True, check=False)
    rows = p.stdout.decode("latin-1").replace("\r", "").split("\n")
    start = rows.index("NEW") + 2
    run = max(k for k, r in enumerate(rows) if r == "RUN")
    typed = set(lines)
    result = ""
    for k in range(start, run):
        if rows[k] not in typed and rows[k] != "READY.":
            result = f"refused: {rows[k - 1][:40]}: {rows[k].split(';')[0][:40]}"
            break
    body = rows[run + 1:]
    end = body.index("READY.") if "READY." in body else None
    if not result and end is None:
        result = "noend"
    if not result:
        body = body[:end]
        err = next((r for r in body if ERROR.fullmatch(r) and not r.startswith("Break in")), None)
        if err:
            result = "error: " + err
        elif any("TEST FAILED" in r or "FAILED ***" in r for r in body):
            result = "failed"
        else:
            text = "\n".join(r for r in body if not r.startswith("Break in"))
            ok_path = os.path.join(tests, name + ".ok")
            with open(ok_path, encoding="latin-1") as f:
                ok = f.read().replace("\r", "")
            result = "same" if same(norm(text.rstrip("\n")), norm(ok.rstrip("\n"))) else "differs"
    eok_path = os.path.join(tests, name + ".eok")
    if os.path.exists(eok_path):
        with open(eok_path, encoding="latin-1") as f:
            if "error" in f.read():
                result += "; bas55 stops"
    return f"{name} {result}"


def main() -> None:
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    emu, rom, cache, expected, out = sys.argv[1:]
    tests = fetch(cache)
    names = sorted(f[:-4] for f in os.listdir(tests) if re.fullmatch(r"P\d{3}\.BAS", f))
    with ThreadPoolExecutor(os.cpu_count() or 4) as ex:
        results = list(ex.map(lambda n: outcome(emu, rom, tests, n), names))
    with open(out, "w") as f:
        f.write("\n".join(results) + "\n")
    counts: dict[str, int] = {}
    for r in results:
        kind = r.split(" ", 1)[1].split(":")[0].split(";")[0]
        kind += " (bas55 stops)" if r.endswith("bas55 stops") else ""
        counts[kind] = counts.get(kind, 0) + 1
    for kind, n in sorted(counts.items(), key=lambda x: -x[1]):
        print(f"  {n:4} {kind}")
    with open(expected) as f:
        want = f.read().split("\n")[:-1]
    if want == results:
        print(f"PASS basic ecma55, {len(results)} programs as {expected} has them")
        return
    print(f"FAIL basic ecma55, the programs that changed from {expected}:")
    old = {w.split(" ", 1)[0]: w for w in want}
    for r in results:
        if old.pop(r.split(" ", 1)[0], None) != r:
            print("  now " + r)
    for w in old.values():
        print("  gone " + w)
    sys.exit(1)


if __name__ == "__main__":
    main()
