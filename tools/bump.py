#!/usr/bin/env python3
"""Move nice_cpu to a tag, build the R6 bitstream, and write the badge files.

nice_cpu shows a badge of whether its core meets 100 MHz on the MEGA65
(nice_cpu issue 19 here). This script makes the two files it reads,
badge-mega65.json and verified.json, at the top level of the repository:

  badge-mega65.json  a shields.io endpoint: "V1.0 met" in green, or
                     "V1.0 failed (WNS -0.12 ns)" in red
  verified.json      the nice_cpu tag and commit, the Vivado version, WNS, TNS,
                     the hold and pulse width slacks, the worst paths into and
                     out of the core, the clock, the board, the flow, the date,
                     and this repository's commit

In this order it checks that the tree is clean, is on main, and that the tag
exists, checks out the tag in nice_cpu, builds niceemu, runs make test, and
builds the bitstream with Vivado's default directives. If the default flow
misses timing it builds again with FLOW=timing, the weaker claim, and the
badge says so: "V1.0 met (timing flow)". Then it makes two commits, the
submodule bump and the two files. It pushes only with --push, for a push
publishes the badge.

A timing miss is a result: the red badge is written and committed. A failure
of a build or of the tests is not: the submodule goes back to where it was,
and nothing is written, for the badge must never claim what was not measured.

nice_cpu's tags are Vmajor.minor (V1.0, V1.1, ...; nice_cpu's
release/RELEASE.md, "Version names"), and the submodule pins only those,
so the tag has two numbers, never the third of a release here
(doc/RELEASE.md).

Usage: tools/bump.py Vmajor.minor [--push]
       tools/bump.py Vmajor.minor --reports synth/r6/build
           prints the files that the reports in that directory would give,
           and builds, checks out, writes, and commits nothing

Needs Vivado (VIVADO_DIR of synth/Makefile.inc), and what make test needs.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICE = os.path.join(REPO, "nice_cpu")
BUILD = os.path.join("synth", "r6", "build")

BOARD = "MEGA65 R6"
PART = "xc7a200tfbg484-2"
LABEL = "MEGA65 100 MHz"
BADGE = "badge-mega65.json"
VERIFIED = "verified.json"

# A nice_cpu tag, and a tag here: the nice_cpu tag it pins, and a third
# number for a release that keeps the submodule (doc/RELEASE.md)
NICE_TAG = re.compile(r"V\d+\.\d+$")
TAG = re.compile(r"(V\d+\.\d+)(\.\d+)?$")

# The flows in the order they are tried; the first is the one the badge
# needs no note for.
FLOWS = ("default", "timing")


class Failed(Exception):
    """A step that gives no result, as against a design that misses timing."""


def run(cmd, cwd=REPO, capture=False):
    print("+ " + " ".join(cmd), flush=True)
    p = subprocess.run(cmd, cwd=cwd, text=True, stdout=subprocess.PIPE if capture else None)
    if p.returncode != 0:
        raise Failed("%s failed with status %d" % (" ".join(cmd), p.returncode))
    return p.stdout.strip() if capture else ""


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def parse_summary(text):
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


def parse_vivado(text):
    m = re.search(r"Tool Version\s*:\s*(Vivado v\.?\S+)", text)
    return m.group(1).replace("v.", "v") if m else None


def parse_clock(text):
    """The system clock, the MMCM's output, in MHz."""
    m = re.search(r"^\s*clk_mmcm\s+\{.*?\}\s+[\d.]+\s+([\d.]+)", text, re.M)
    return float(m.group(1)) if m else None


def parse_path(text):
    """Slack, start, and end of the worst path of a report_timing report."""
    if text is None:
        return None
    s = re.search(r"^Slack \(\w+\)\s*:\s*(-?[\d.]+)ns", text, re.M)
    a = re.search(r"^\s*Source:\s*(\S+)", text, re.M)
    b = re.search(r"^\s*Destination:\s*(\S+)", text, re.M)
    if not (s and a and b):
        return None
    return {"slack_ns": float(s.group(1)), "from": a.group(1), "to": b.group(1)}


def read_reports(build, flow):
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


def badge(tag, r):
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
    return {"schemaVersion": 1, "label": LABEL, "message": msg, "color": color}


def verified(tag, nice_commit, repo_commit, r, attempts):
    return {
        "nice_cpu_tag": tag,
        "nice_cpu_commit": nice_commit,
        "repo_commit": repo_commit,
        "vivado": r["vivado"],
        "board": BOARD,
        "part": PART,
        "clock_mhz": r["clock_mhz"],
        "flow": r["flow"],
        "met": badge(tag, r)["color"] == "brightgreen",
        "wns_ns": r["wns_ns"],
        "tns_ns": r["tns_ns"],
        "whs_ns": r["whs_ns"],
        "ths_ns": r["ths_ns"],
        "wpws_ns": r["wpws_ns"],
        "tpws_ns": r["tpws_ns"],
        "core_in": r["core_in"],
        "core_out": r["core_out"],
        "attempts": attempts,
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
    }


def dump(obj):
    return json.dumps(obj, indent=2) + "\n"


def write(name, obj):
    with open(os.path.join(REPO, name), "w") as f:
        f.write(dump(obj))


def check_tree():
    if run(["git", "status", "--porcelain", "--untracked-files=no"], capture=True):
        raise Failed("the working tree is not clean")
    branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], capture=True)
    if branch != "main":
        raise Failed("the branch is %s, not main" % branch)


def tag_commit(tag):
    """The commit of a nice_cpu tag, after a fetch of its tags."""
    if not os.path.exists(os.path.join(NICE, ".git")):
        raise Failed("nice_cpu is not checked out; run git submodule update --init")
    run(["git", "fetch", "--tags", "--quiet"], cwd=NICE)
    try:
        return run(["git", "rev-parse", "--verify", "--quiet", "refs/tags/%s^{commit}" % tag],
                   cwd=NICE, capture=True)
    except Failed:
        raise Failed("nice_cpu has no tag %s" % tag)


def checkout_tag(tag):
    """Moves nice_cpu to the tag; returns its commit."""
    commit = tag_commit(tag)
    run(["git", "checkout", "--quiet", commit], cwd=NICE)
    return commit


def build(flow):
    """A bitstream with the flow, from nothing, so that no old report stays."""
    run(["make", "-C", os.path.join("synth", "r6"), "clean"])
    run(["make", "r6", "FLOW=" + flow])
    return read_reports(os.path.join(REPO, BUILD), flow)


def summarize(r):
    return {"flow": r["flow"], "wns_ns": r["wns_ns"], "whs_ns": r["whs_ns"],
            "wpws_ns": r["wpws_ns"], "met": badge("x", r)["color"] == "brightgreen"}


def measure(tag):
    """Builds with each flow until one meets timing; returns the last, and all."""
    attempts = []
    for flow in FLOWS:
        r = build(flow)
        attempts.append(summarize(r))
        if attempts[-1]["met"]:
            break
    return r, attempts


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("tag", help="the nice_cpu tag, such as V1.0")
    ap.add_argument("--push", action="store_true", help="push the two commits")
    ap.add_argument("--reports", metavar="DIR",
                    help="build and commit nothing; print the badge-mega65.json and "
                    "verified.json that the timing reports in DIR would give")
    args = ap.parse_args()
    tag = args.tag
    if not NICE_TAG.match(tag):
        sys.exit("bump: %s is not a nice_cpu tag Vmajor.minor, such as V1.0" % tag)

    if args.reports:
        try:
            r = read_reports(args.reports, os.environ.get("FLOW", FLOWS[0]))
        except Failed as e:
            sys.exit("bump: " + str(e))
        print(BADGE + ":\n" + dump(badge(tag, r)))
        print(VERIFIED + ":\n" + dump(verified(tag, "-", "-", r, [summarize(r)])))
        return

    old = None
    try:
        check_tree()
        old = run(["git", "-C", "nice_cpu", "rev-parse", "HEAD"], capture=True)
        repo_commit = run(["git", "rev-parse", "HEAD"], capture=True)
        nice_commit = checkout_tag(tag)
        # CLAUDE.md: after a bump, niceemu is rebuilt, and the tests run
        run(["make", "-C", "nice_cpu/emulator", "build"])
        run(["make", "-j", "test"])
        r, attempts = measure(tag)
    except Failed as e:
        if old:
            subprocess.run(["git", "checkout", "--quiet", old], cwd=NICE)
            sys.exit("bump: %s; nice_cpu is back at %s and nothing is written" % (e, old[:7]))
        sys.exit("bump: %s; nothing is changed" % e)

    b = badge(tag, r)
    v = verified(tag, nice_commit, repo_commit, r, attempts)
    write(BADGE, b)
    write(VERIFIED, v)

    if old != nice_commit:
        run(["git", "add", "nice_cpu"])
        run(["git", "commit", "-q", "-m", "Bump nice_cpu to %s" % tag,
             "-m", "nice_cpu %s is commit %s." % (tag, nice_commit[:7])])
    run(["git", "add", BADGE, VERIFIED])
    run(["git", "commit", "-q", "-m", "Record the MEGA65 timing of %s" % tag,
         "-m", "Badge: %s.\nFlow %s, WNS %.3f ns, TNS %.3f ns, WHS %.3f ns."
         % (b["message"], r["flow"], r["wns_ns"], r["tns_ns"], r["whs_ns"])])
    print("%s: %s" % (BADGE, b["message"]))

    if args.push:
        run(["git", "push"])
    else:
        print("Not pushed; run git push to publish the badge.")


if __name__ == "__main__":
    main()
