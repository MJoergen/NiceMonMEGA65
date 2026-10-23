#!/usr/bin/env python3
"""Run the automatable steps of the release checklist (release/RELEASE.md).

The stages run in the order of the checklist, and the run stops at the first
that fails:

  prepare  clean tree on main, equal to origin; build niceemu; nice_cpu's tests
  sw       lint, tests (both cores), formal, examples, niceemu on primes.bin
  docs     the spelling check, and the figures quoted in the READMEs
  ci       wait for the three CI jobs to pass on this commit
  bits     build each board and check timing, Synth 8-6849, and utilization
  hw       make hwtest for each board that has a port
  compare  run sim/*.nasm and the examples on the board and in niceemu
  tag      tag the commit and publish the bitstreams (only with --publish)

Usage: release/release.py [--from STAGE] [--only STAGE] [--version vX.Y]
                          [--port BOARD=PORT ...] [--boards r6,r3,nexys4ddr]
                          [--nice pipeline|multi] [--flow default|timing]
                          [--publish]

--port gives the serial port of each board for the hw and compare stages,
for example --port r6=/dev/ttyUSB1; a board without a port is skipped there.
--from resumes at a stage, after the problem is fixed. The script notes the
commit when it starts and stops if HEAD has moved by the end of a stage, as
the bitstreams must come from the released commit.

Nothing is tagged, pushed, or uploaded unless --publish is given; without it
the tag stage prints what it would do. The results go to
release/build/report.md, to paste into the tag message and the READMEs.
What a script cannot check is listed at the end: reset button, keyboard and
screens, the ROM power cycle, and TODO.md.

Only the Python standard library is used, and git, make, and gh.
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUILD = REPO / "release" / "build"
EMU = REPO / "nice_cpu/emulator/zig-out/bin/niceemu"
BOARDS = ["r6", "r3", "nexys4ddr"]
# Passing checks of make hwtest with the pipelined core (README.md, "Testing
# the board"); the R3 is checked against the same figure as the R6.
HW_COUNTS = {"r6": 63, "r3": 63, "nexys4ddr": 79}
STAGES = ["prepare", "sw", "docs", "ci", "bits", "hw", "compare", "tag"]
MANUAL = [
    "Press reset with a terminal open on the UART: NICE is printed again.",
    "MEGA65: type on the keyboard, and see the text on VGA and HDMI.",
    "Nexys4DDR: check the VGA screen and the PS/2 or USB keyboard.",
    "With a ROM in the bitstream: power-cycle, check the boot, then make load.",
    "Read the \"Compared with the emulator\" table in EMULATOR.md.",
    "TODO.md lists only what is still to do.",
    "Oxford comma and plain short sentences in the READMEs.",
    "The XDCs have IOB TRUE on every registered pin, and the report shows "
    "the registers in the IOBs.",
]

report = []


class Fail(Exception):
    pass


def say(text=""):
    print(text, flush=True)


def note(line):
    """Add a line to the report, and print it."""
    report.append(line)
    say(line)


def run(cmd, check=True, capture=False, cwd=REPO, log=None):
    """Run a command; with log, its output goes to that file and it is quiet."""
    say("$ " + " ".join(str(c) for c in cmd))
    out = None
    if log:
        BUILD.mkdir(parents=True, exist_ok=True)
        out = open(BUILD / log, "w")
    p = subprocess.run([str(c) for c in cmd], cwd=cwd, text=True,
                       stdout=out if out else (subprocess.PIPE if capture else None),
                       stderr=subprocess.STDOUT if (out or capture) else None)
    if out:
        out.close()
    if check and p.returncode != 0:
        where = f" (see release/build/{log})" if log else ""
        raise Fail(f"{' '.join(str(c) for c in cmd)} failed{where}")
    return p


def git(*args):
    return run(["git", *args], capture=True).stdout.strip()


def head():
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO, text=True,
                          capture_output=True).stdout.strip()


# ---------------------------------------------------------------- stages

def stage_prepare(a):
    if git("status", "--porcelain"):
        raise Fail("the working tree is not clean")
    if git("rev-parse", "--abbrev-ref", "HEAD") != "main":
        raise Fail("the branch is not main")
    run(["git", "fetch", "origin"])
    if git("rev-parse", "HEAD") != git("rev-parse", "origin/main"):
        raise Fail("HEAD differs from origin/main")
    note(f"- commit: {a.sha}")
    note("- submodule: " + git("submodule", "status").strip())
    run(["make", "-C", "nice_cpu/emulator", "build"], log="emulator.log")
    run(["make", "-C", "nice_cpu", "test"], log="nice_cpu_test.log")


def check_pass_lines(logname):
    text = (BUILD / logname).read_text(errors="replace")
    bad = [l for l in text.splitlines() if re.search(r"\bFAIL\b", l)]
    if bad:
        raise Fail(f"{logname}: " + "; ".join(bad[:5]))
    return len(re.findall(r"\bPASS\b", text))


def stage_sw(a):
    run(["make", "lint"], log="lint.log")
    for core in ("pipeline", "multi"):
        run(["make", "-j", f"NICE={core}", "test"], log=f"test_{core}.log")
        note(f"- tests, {core} core: {check_pass_lines(f'test_{core}.log')} PASS")
    p = run(["make", "-j4", "formal"], check=False, log="formal.log")
    text = (BUILD / "formal.log").read_text(errors="replace")
    if p.returncode != 0 and "database disk image is malformed" in text:
        say("known SymbiYosys database problem; running serially")
        p = run(["make", "formal"], check=False, log="formal.log")
    if p.returncode != 0:
        raise Fail("formal failed (see release/build/formal.log)")
    note(f"- formal: {check_pass_lines('formal.log')} PASS")
    run(["make", "examples"], log="examples.log")
    for f in ("primes", "bench"):
        if not (REPO / f"examples/build/{f}.bin").exists():
            raise Fail(f"examples/build/{f}.bin is missing")
    run([EMU, "examples/build/primes.bin"], log="primes_emu.log")


# Spellings that American English does not use; CLAUDE.md asks for American.
BRITISH = re.compile(
    r"\b(colour|behaviour|synchronis\w*|analys(e|ed|es|ing)|initialis\w*|"
    r"serialis\w*|optimis\w*|neighbour\w*|centre|grey|licence|favour\w*|"
    r"catalogue|recognis\w*|organis\w*|utilis\w*)\b", re.I)
# Files with third-party text that keeps its spelling.
SPELLING_SKIP = ("serialiser_10to1_selectio", "synth/mega65/hdmi/",
                 "synth/r3/max10.vhd", "nice_cpu/")


def stage_docs(a):
    files = git("ls-files").splitlines()
    hits = []
    for f in files:
        if f.startswith(SPELLING_SKIP) or not f.endswith(
                (".md", ".vhd", ".py", ".xdc", ".mk", ".c", ".nasm")):
            continue
        for n, line in enumerate((REPO / f).read_text(errors="replace")
                                 .splitlines(), 1):
            if "serialiser" in line.lower():
                continue
            m = BRITISH.search(line)
            if m:
                hits.append(f"{f}:{n}: {m.group(0)}")
    if hits:
        raise Fail("British spelling:\n  " + "\n  ".join(hits[:30]))
    note("- spelling: no British spellings found")
    # The figures quoted in the READMEs must agree with the expected counts;
    # step 2.2 of RELEASE.md updates them from the measured ones.
    readme = (REPO / "README.md").read_text()
    for board, n in (("R6", HW_COUNTS["r6"]), ("Nexys4DDR", HW_COUNTS["nexys4ddr"])):
        if not re.search(rf"\b{n}\b", readme):
            raise Fail(f"README.md does not mention {n} checks ({board})")
    say("README.md quotes the expected hwtest counts; compare the slack "
        "figures in synth/README.md with the table of the bits stage.")


def stage_ci(a):
    say("waiting for CI on " + a.sha)
    deadline = time.time() + 3600
    while time.time() < deadline:
        p = run(["gh", "run", "list", "--commit", a.sha, "--json",
                 "status,conclusion,name,databaseId", "--workflow", "CI"],
                capture=True)
        runs = json.loads(p.stdout or "[]")
        if runs:
            r = runs[0]
            if r["status"] == "completed":
                if r["conclusion"] != "success":
                    raise Fail(f"CI run {r['databaseId']}: {r['conclusion']}")
                note(f"- CI: green, run {r['databaseId']}")
                return
        else:
            say("no CI run for this commit yet; has it been pushed?")
        time.sleep(30)
    raise Fail("CI did not finish within an hour")


def parse_timing(path):
    lines = path.read_text(errors="replace").splitlines()
    for i, l in enumerate(lines):
        if "Design Timing Summary" in l:
            for row in lines[i:i + 12]:
                f = row.split()
                if len(f) >= 8 and re.fullmatch(r"-?\d+\.\d+", f[0]):
                    return float(f[0]), float(f[4]), "constraints are met" in "\n".join(lines)
    raise Fail(f"no timing summary in {path}")


def parse_util(path):
    out = {}
    for key in ("Slice LUTs", "Slice Registers", "Block RAM Tile", "DSPs"):
        m = re.search(rf"^\|\s*{re.escape(key)}\s*\|\s*([\d.]+)\s*\|.*?\|\s*[\d.]+\s*\|\s*([\d.]+)\s*\|",
                      path.read_text(errors="replace"), re.M)
        if m:
            out[key] = f"{m.group(1)} of {m.group(2)}"
    return out


def stage_bits(a):
    note("")
    note("| Board | WNS (ns) | WHS (ns) | Vivado | Utilization |")
    note("|---|---|---|---|---|")
    for b in a.boards:
        run(["make", b, f"NICE={a.nice}", f"FLOW={a.flow}"], log=f"{b}.log")
        d = REPO / "synth" / b / "build"
        wns, whs, met = parse_timing(d / "timing.rpt")
        if wns < 0 or whs < 0 or not met:
            raise Fail(f"{b}: timing not met (WNS {wns}, WHS {whs}); "
                       "try FLOW=timing")
        log = (d / "vivado.log").read_text(errors="replace")
        if "Synth 8-6849" in log:
            raise Fail(f"{b}: Synth 8-6849 in vivado.log (a dual-clock memory "
                       "became LUTRAM)")
        v = re.search(r"Vivado v([\d.]+)", log)
        util = parse_util(d / "utilization.rpt")
        note(f"| {b} | {wns:.3f} | {whs:.3f} | {v.group(1) if v else '?'} | "
             + ", ".join(f"{k} {x}" for k, x in util.items()) + " |")
        if not (d / "top.bit").exists():
            raise Fail(f"{b}: no top.bit")
    note("")


def stage_hw(a):
    for b in a.boards:
        if b not in a.ports:
            say(f"{b}: no --port, skipped")
            continue
        bit = f"synth/{b}/build/top.bit"
        run(["make", "hwtest", f"BIT={bit}", f"PORT={a.ports[b]}",
             f"NICE={a.nice}"], log=f"hwtest_{b}.log")
        text = (BUILD / f"hwtest_{b}.log").read_text(errors="replace")
        m = re.search(r"(\d+)/(\d+) passed", text)
        if not m or m.group(1) != m.group(2):
            raise Fail(f"{b}: hwtest {m.group(0) if m else 'gave no summary'}")
        if a.nice == "pipeline" and int(m.group(1)) != HW_COUNTS[b]:
            raise Fail(f"{b}: {m.group(1)} checks, expected {HW_COUNTS[b]}; "
                       "update HW_COUNTS and the README if the test grew")
        note(f"- hwtest {b}: {m.group(0)}")


def assemble(nasm):
    out = BUILD / "compare" / (nasm.stem + ".bin")
    out.parent.mkdir(parents=True, exist_ok=True)
    run(["python3", "nice_cpu/assembler/niceasm.py", "-o", out, nasm],
        log="asm.log")
    return out


def stage_compare(a):
    known = (REPO / "EMULATOR.md").read_text()
    progs = [assemble(p) for p in sorted((REPO / "sim").glob("*.nasm"))]
    progs += [REPO / "examples/build/primes.bin"]
    # sim/rom.nasm is for a ROM bitstream, and bench.bin differs in its cycles
    # (hwtest compares that one).
    progs = [p for p in progs if p.stem != "rom"]
    for b in a.boards:
        if b not in a.ports:
            say(f"{b}: no --port, skipped")
            continue
        for p in progs:
            emu = run([EMU, p], check=False, capture=True)
            brd = run(["python3", "tools/run.py", "--port", a.ports[b],
                       "-i", "/dev/null", "--timeout", "30", p],
                      check=False, capture=True)
            if emu.stdout != brd.stdout or emu.returncode != brd.returncode:
                if p.stem in known:
                    note(f"- {b} {p.stem}: differs, and EMULATOR.md names it")
                else:
                    raise Fail(f"{b}: {p.name} differs from niceemu "
                               "(a bug, or a line for EMULATOR.md)")
            else:
                note(f"- {b} {p.stem}: same as niceemu")


def stage_tag(a):
    if not a.version:
        raise Fail("give the tag with --version vX.Y")
    if git("status", "--porcelain"):
        raise Fail("the working tree is not clean (did you update the figures?)")
    message = BUILD / "tag_message.txt"
    message.write_text(
        f"NiceMonMEGA65 {a.version}\n\nnice_cpu: {git('submodule', 'status').strip()}\n"
        f"NICE={a.nice} FLOW={a.flow}\n\n" + "\n".join(report) + "\n")
    bits = []
    for b in a.boards:
        src = REPO / "synth" / b / "build" / "top.bit"
        dst = BUILD / f"nicemon-{b}-{a.version}.bit"
        dst.write_bytes(src.read_bytes())
        bits.append(dst)
    cmds = [["git", "tag", "-a", a.version, "-F", message],
            ["git", "push", "origin", a.version],
            ["gh", "release", "create", a.version, "--notes-file", message,
             "--title", a.version, *bits]]
    if not a.publish:
        say("dry run (no --publish); would run:")
        for c in cmds:
            say("  " + " ".join(str(x) for x in c))
        return
    if input(f"Tag and publish {a.version} at {a.sha[:8]}? [y/N] ") != "y":
        raise Fail("not confirmed")
    for c in cmds:
        run(c)


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--from", dest="start", choices=STAGES, default=STAGES[0])
    ap.add_argument("--only", choices=STAGES)
    ap.add_argument("--version")
    ap.add_argument("--port", action="append", default=[], metavar="BOARD=PORT")
    ap.add_argument("--boards", default=",".join(BOARDS))
    ap.add_argument("--nice", choices=["pipeline", "multi"], default="pipeline")
    ap.add_argument("--flow", choices=["default", "timing"], default="default")
    ap.add_argument("--publish", action="store_true")
    a = ap.parse_args()
    a.boards = a.boards.split(",")
    a.ports = dict(p.split("=", 1) for p in a.port)
    a.sha = head()

    stages = [a.only] if a.only else STAGES[STAGES.index(a.start):]
    BUILD.mkdir(parents=True, exist_ok=True)
    try:
        for s in stages:
            say(f"\n=== {s} ===")
            globals()["stage_" + s](a)
            if head() != a.sha:
                raise Fail("HEAD moved during the run")
            say(f"=== {s}: ok ===")
    except Fail as e:
        say(f"\nFAILED: {e}")
        sys.exit(1)
    finally:
        (BUILD / "report.md").write_text("\n".join(report) + "\n")
    say("\nAll stages passed. Still to do by hand:")
    for m in MANUAL:
        say(f"  [ ] {m}")


if __name__ == "__main__":
    main()
