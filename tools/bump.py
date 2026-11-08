#!/usr/bin/env python3
"""Move nice_cpu to a tag, build the R6 and Nexys4DDR bitstreams, and write
the badge files.

nice_cpu shows badges of whether its core meets 100 MHz on the MEGA65
(nice_cpu issue 19 here) and 90 MHz on the Nexys4DDR (#77). This script
makes the three files they read at the top level of the repository:

  badge-mega65.json     a shields.io endpoint: "V1.0 met" in green, or
                        "V1.0 failed (WNS -0.12 ns)" in red, for the R6
  badge-nexys4ddr.json  the same for the Nexys4DDR
  verified.json         the nice_cpu tag and commit, the Vivado version, and
                        the R6's WNS, TNS, hold and pulse width slacks, worst
                        paths into and out of the core, clock, board, and
                        flow, the date, and this repository's commit, with
                        the same for the Nexys4DDR under "nexys4ddr"

In this order it checks that the tree is clean, is on main, and that the tag
exists, checks out the tag in nice_cpu, builds niceemu, runs make test, and
builds each board's bitstream, the R6 first, with Vivado's default
directives. If the default flow misses timing it builds that board again
with FLOW=timing, the weaker claim, and its badge says so: "V1.0 met
(timing flow)". Then it makes two commits, the submodule bump and the three
files. It pushes only with --push, for a push publishes the badges.

A timing miss is a result: the red badge is written and committed, and the
other board's badge is as its own build says. A failure of a build or of
the tests is not: the submodule goes back to where it was,
and nothing is written, for the badge must never claim what was not measured.
A board that was built before the failure keeps its measurement in
synth/TARGET/build/bump.json, with the tag and the two commits, and the
next run of the same bump takes it from there instead of building the
board again; a run with another tag or commit builds, and removes it.

nice_cpu's tags are Vmajor.minor (V1.0, V1.1, ...; nice_cpu's
release/RELEASE.md, "Version names"), and the submodule pins only those,
so the tag has two numbers, never the third of a release here
(doc/RELEASE.md).

Usage: tools/bump.py Vmajor.minor [--push]
       tools/bump.py Vmajor.minor --reports synth/r6/build
                     [--nexys-reports synth/nexys4ddr/build]
           prints the files that the reports in those directories would
           give, and builds, checks out, writes, and commits nothing

Needs Vivado (VIVADO_DIR of synth/Makefile.inc), and what make test needs.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from typing import Any

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICE = os.path.join(REPO, "nice_cpu")

# The boards that get a badge: the make target, the name, the FPGA, the
# badge's label, and its file. The first is the one at the top level of
# verified.json, which release.py reads; the others are under their target.
BOARDS: list[dict[str, str]] = [
    {"target": "r6", "board": "MEGA65 R6", "part": "xc7a200tfbg484-2",
     "label": "MEGA65 100 MHz", "badge": "badge-mega65.json"},
    {"target": "nexys4ddr", "board": "Nexys4DDR", "part": "xc7a100tcsg324-1",
     "label": "Nexys4DDR 90 MHz", "badge": "badge-nexys4ddr.json"},
]
LABEL = BOARDS[0]["label"]
BADGE = BOARDS[0]["badge"]
VERIFIED = "verified.json"

# A nice_cpu tag, and a tag here: the nice_cpu tag it pins, and a third
# number for a release that keeps the submodule (doc/RELEASE.md)
NICE_TAG = re.compile(r"V\d+\.\d+$")
TAG = re.compile(r"(V\d+\.\d+)(\.\d+)?$")

# The flows in the order they are tried; the first is the one the badge
# needs no note for.
FLOWS = ("default", "timing")

# What read_reports gives, and the badge and verified.json: JSON objects
Record = dict[str, Any]


class Failed(Exception):
    """A step that gives no result, as against a design that misses timing."""


def run(cmd: list[str], cwd: str = REPO, capture: bool = False) -> str:
    print("+ " + " ".join(cmd), flush=True)
    p = subprocess.run(cmd, cwd=cwd, text=True, stdout=subprocess.PIPE if capture else None)
    if p.returncode != 0:
        raise Failed("%s failed with status %d" % (" ".join(cmd), p.returncode))
    return p.stdout.strip() if capture else ""


def read(path: str) -> str | None:
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def parse_summary(text: str) -> Record:
    """The numbers of the design timing summary of report_timing_summary."""
    m = re.search(r"Design Timing Summary.*?\n\s*WNS\(ns\).*?\n\s*-+.*?\n\s*(.+)", text, re.S)
    if not m:
        raise Failed("no design timing summary in timing.rpt")
    v = m.group(1).split()
    if len(v) < 12:
        raise Failed("design timing summary of timing.rpt has %d columns, not 12" % len(v))
    # WNS, TNS, failing, total, WHS, THS, failing, total, WPWS, TPWS, failing, total
    return {
        "wns_ns": float(v[0]), "tns_ns": float(v[1]),
        "whs_ns": float(v[4]), "ths_ns": float(v[5]),
        "wpws_ns": float(v[8]), "tpws_ns": float(v[9]),
        "met": "All user specified timing constraints are met." in text,
    }


def parse_vivado(text: str) -> str | None:
    m = re.search(r"Tool Version\s*:\s*(Vivado v\.?\S+)", text)
    return m.group(1).replace("v.", "v") if m else None


def parse_clock(text: str) -> float | None:
    """The system clock, the MMCM's output, in MHz."""
    m = re.search(r"^\s*clk_mmcm\s+\{.*?\}\s+[\d.]+\s+([\d.]+)", text, re.M)
    return float(m.group(1)) if m else None


def parse_path(text: str | None) -> Record | None:
    """Slack, start, and end of the worst path of a report_timing report."""
    if text is None:
        return None
    s = re.search(r"^Slack \(\w+\)\s*:\s*(-?[\d.]+)ns", text, re.M)
    a = re.search(r"^\s*Source:\s*(\S+)", text, re.M)
    b = re.search(r"^\s*Destination:\s*(\S+)", text, re.M)
    if not (s and a and b):
        return None
    return {"slack_ns": float(s.group(1)), "from": a.group(1), "to": b.group(1)}


def read_reports(build: str, flow: str) -> Record:
    """What a build left in its directory, as one record."""
    text = read(os.path.join(build, "timing.rpt"))
    if text is None:
        raise Failed("no timing.rpt in %s" % build)
    r = parse_summary(text)
    r["flow"] = flow
    r["vivado"] = parse_vivado(text)
    r["clock_mhz"] = parse_clock(text)
    # A missing report, for the catch in synth/Makefile.inc, is null
    r["core_in"] = parse_path(read(os.path.join(build, "core_in.rpt")))
    r["core_out"] = parse_path(read(os.path.join(build, "core_out.rpt")))
    return r


def badge(tag: str, r: Record, label: str = LABEL) -> Record:
    """The shields.io endpoint for a result."""
    note = "" if r["flow"] == FLOWS[0] else "timing flow"
    if r["met"] and r["wns_ns"] >= 0 and r["whs_ns"] >= 0 and r["wpws_ns"] >= 0:
        msg = "%s met" % tag + (" (%s)" % note if note else "")
        color = "brightgreen"
    else:
        # The first slack that is negative, setup before hold
        if r["wns_ns"] < 0:
            what = "WNS %.2f ns" % r["wns_ns"]
        elif r["whs_ns"] < 0:
            what = "WHS %.2f ns" % r["whs_ns"]
        elif r["wpws_ns"] < 0:
            what = "WPWS %.2f ns" % r["wpws_ns"]
        else:
            what = "constraints not met"
        msg = "%s failed (%s)" % (tag, ", ".join([what] + ([note] if note else [])))
        color = "red"
    return {"schemaVersion": 1, "label": label, "message": msg, "color": color}


def board_record(tag: str, board: dict[str, str], r: Record,
                 attempts: list[Record]) -> Record:
    """A board's part of verified.json."""
    return {
        "board": board["board"],
        "part": board["part"],
        "clock_mhz": r["clock_mhz"],
        "flow": r["flow"],
        "met": badge(tag, r, board["label"])["color"] == "brightgreen",
        "wns_ns": r["wns_ns"],
        "tns_ns": r["tns_ns"],
        "whs_ns": r["whs_ns"],
        "ths_ns": r["ths_ns"],
        "wpws_ns": r["wpws_ns"],
        "tpws_ns": r["tpws_ns"],
        "core_in": r["core_in"],
        "core_out": r["core_out"],
        "attempts": attempts,
    }


def verified(tag: str, nice_commit: str, repo_commit: str,
             results: list[tuple[Record, list[Record]]]) -> Record:
    """verified.json: the first board's record at the top level, as before
    the second board, and each other board's under its target."""
    first, attempts = results[0]
    v: Record = {
        "nice_cpu_tag": tag,
        "nice_cpu_commit": nice_commit,
        "repo_commit": repo_commit,
        "vivado": first["vivado"],
    }
    v.update(board_record(tag, BOARDS[0], first, attempts))
    for board, (r, att) in zip(BOARDS[1:], results[1:]):
        v[board["target"]] = {"vivado": r["vivado"], **board_record(tag, board, r, att)}
    v["date"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    return v


def dump(obj: Record) -> str:
    return json.dumps(obj, indent=2) + "\n"


def write(name: str, obj: Record) -> None:
    with open(os.path.join(REPO, name), "w") as f:
        f.write(dump(obj))


def check_tree() -> None:
    if run(["git", "status", "--porcelain", "--untracked-files=no"], capture=True):
        raise Failed("the working tree is not clean")
    branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], capture=True)
    if branch != "main":
        raise Failed("the branch is %s, not main" % branch)


def tag_commit(tag: str) -> str:
    """The commit of a nice_cpu tag, after a fetch of its tags."""
    if not os.path.exists(os.path.join(NICE, ".git")):
        raise Failed("nice_cpu is not checked out; run git submodule update --init")
    run(["git", "fetch", "--tags", "--quiet"], cwd=NICE)
    try:
        return run(["git", "rev-parse", "--verify", "--quiet", "refs/tags/%s^{commit}" % tag],
                   cwd=NICE, capture=True)
    except Failed:
        raise Failed("nice_cpu has no tag %s" % tag)


def checkout_tag(tag: str) -> str:
    """Moves nice_cpu to the tag; returns its commit."""
    commit = tag_commit(tag)
    run(["git", "checkout", "--quiet", commit], cwd=NICE)
    return commit


def build(target: str, flow: str) -> Record:
    """The board's bitstream with the flow and without a ROM, from nothing,
    so that no old report stays."""
    run(["make", "-C", os.path.join("synth", target), "clean"])
    run(["make", target, "FLOW=" + flow, "ROM="])
    return read_reports(os.path.join(REPO, "synth", target, "build"), flow)


def summarize(r: Record) -> Record:
    return {"flow": r["flow"], "wns_ns": r["wns_ns"], "whs_ns": r["whs_ns"],
            "wpws_ns": r["wpws_ns"], "met": badge("x", r)["color"] == "brightgreen"}


def kept(target: str) -> str:
    """The file in the board's build directory that keeps its measurement
    for the next run of the same bump, with the key of the run that made it."""
    return os.path.join(REPO, "synth", target, "build", "bump.json")


def load_kept(target: str, key: Record) -> Record | None:
    """The measurement that a run with the same key kept, or None."""
    text = read(kept(target))
    if text is None:
        return None
    try:
        k: Record = json.loads(text)
    except ValueError:
        return None
    return k if isinstance(k, dict) and k.get("key") == key else None


def measured(key: Record) -> list[str]:
    """The targets whose measurement a run with the key kept."""
    return [b["target"] for b in BOARDS if load_kept(b["target"], key) is not None]


def measure(target: str, key: Record) -> tuple[Record, list[Record]]:
    """Builds the board with each flow until one meets timing; returns the
    last, and all. The result is kept in the build directory under key,
    the tag and the commits, and a run with the same key takes it from
    there, so that a failure of a later board does not cost this board's
    build again. A build removes the file first, and a run with another
    key builds, so the file never claims what was not measured."""
    attempts: list[Record] = []
    k = load_kept(target, key)
    if k is not None:
        print("+ %s was measured by an earlier run of this bump; its reports "
              "are in synth/%s/build" % (target, target), flush=True)
        result: Record = k["result"]
        attempts = k["attempts"]
        return result, attempts
    try:
        os.remove(kept(target))
    except OSError:
        pass
    for flow in FLOWS:
        r = build(target, flow)
        attempts.append(summarize(r))
        if attempts[-1]["met"]:
            break
    with open(kept(target), "w") as f:
        f.write(dump({"key": key, "result": r, "attempts": attempts}))
    return r, attempts


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("tag", help="the nice_cpu tag, such as V1.0")
    ap.add_argument("--push", action="store_true", help="push the two commits")
    ap.add_argument("--reports", metavar="DIR",
                    help="build and commit nothing; print the badge files and "
                    "verified.json that the R6's timing reports in DIR would give")
    ap.add_argument("--nexys-reports", metavar="DIR",
                    help="with --reports, the Nexys4DDR's timing reports in DIR too")
    args = ap.parse_args()
    tag = args.tag
    if not NICE_TAG.match(tag):
        sys.exit("bump: %s is not a nice_cpu tag Vmajor.minor, such as V1.0" % tag)

    if args.nexys_reports and not args.reports:
        ap.error("--nexys-reports needs --reports")
    if args.reports:
        dirs = [args.reports] + ([args.nexys_reports] if args.nexys_reports else [])
        try:
            reports = [read_reports(d, os.environ.get("FLOW", FLOWS[0])) for d in dirs]
        except Failed as e:
            sys.exit("bump: " + str(e))
        for board, r in zip(BOARDS, reports):
            print(board["badge"] + ":\n" + dump(badge(tag, r, board["label"])))
        print(VERIFIED + ":\n" + dump(verified(tag, "-", "-",
                                                [(r, [summarize(r)]) for r in reports])))
        return

    old = None
    key: Record | None = None
    try:
        check_tree()
        old = run(["git", "-C", "nice_cpu", "rev-parse", "HEAD"], capture=True)
        repo_commit = run(["git", "rev-parse", "HEAD"], capture=True)
        nice_commit = checkout_tag(tag)
        # CLAUDE.md: after a bump, niceemu is rebuilt, and the tests run
        run(["make", "-C", "nice_cpu/emulator", "build"])
        run(["make", "-j", "test"])
        # What a kept measurement must have been made from: the tag, and the
        # commits of the submodule and of the clean tree
        key = {"tag": tag, "nice_cpu_commit": nice_commit, "repo_commit": repo_commit}
        results = [measure(board["target"], key) for board in BOARDS]
    except Failed as e:
        if old:
            subprocess.run(["git", "checkout", "--quiet", old], cwd=NICE)
            done = measured(key) if key else []
            keeps = ("; %s keeps its measurement for the next run of this bump"
                     % " and ".join(done) if done else "")
            sys.exit("bump: %s; nice_cpu is back at %s and nothing is written%s"
                     % (e, old[:7], keeps))
        sys.exit("bump: %s; nothing is changed" % e)

    badges = [badge(tag, r, board["label"]) for board, (r, _) in zip(BOARDS, results)]
    for board, b in zip(BOARDS, badges):
        write(board["badge"], b)
    write(VERIFIED, verified(tag, nice_commit, repo_commit, results))

    if old != nice_commit:
        run(["git", "add", "nice_cpu"])
        run(["git", "commit", "-q", "-m", "Bump nice_cpu to %s" % tag,
             "-m", "nice_cpu %s is commit %s." % (tag, nice_commit[:7])])
    run(["git", "add"] + [board["badge"] for board in BOARDS] + [VERIFIED])
    body = "\n".join("%s: %s, flow %s, WNS %.3f ns, TNS %.3f ns, WHS %.3f ns."
                     % (board["board"], b["message"], r["flow"], r["wns_ns"],
                        r["tns_ns"], r["whs_ns"])
                     for board, b, (r, _) in zip(BOARDS, badges, results))
    run(["git", "commit", "-q", "-m", "Record the timing of %s" % tag, "-m", body])
    for board, b in zip(BOARDS, badges):
        print("%s: %s" % (board["badge"], b["message"]))

    if args.push:
        run(["git", "push"])
    else:
        print("Not pushed; run git push to publish the badges.")


if __name__ == "__main__":
    main()
