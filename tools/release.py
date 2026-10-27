#!/usr/bin/env python3
"""Build, test, and publish a release: a tag RCnn after nice_cpu's tag RCnn.

A release follows make bump (tools/bump.py), which moves nice_cpu to the tag
and records the MEGA65's timing in verified.json. It has two steps, so that
what is published can be looked at first (RELEASE.md).

The first step, tools/release.py RCnn, changes nothing in git. In this order
it checks that the tree is clean, is on main, and is pushed, that the tag is
not taken here, that verified.json is for the tag and the submodule's commit
and says met, and that CI passed for the commit. It then builds the examples
and the bitstreams of the R6, the R3, and the Nexys4DDR, without a ROM and
from nothing. The R6 uses the flow of verified.json; the others try the
default directives first and then FLOW=timing, as bump.py does. Each must
meet timing. It makes the core files of the R3 and the R6, with the tag as
their version, which MEGAFLASH shows. Last it runs make hwtest on the R6 bitstream, so a MEGA65 R6
must be on PORT. It copies the bitstreams, the core files, a zip of the examples, and
verified.json to build/release/RCnn, with notes.md, the release notes, and
release.json, the commit they were built from.

The second step, tools/release.py RCnn --publish, builds nothing. It checks
that HEAD is still the commit of release.json, makes the annotated tag,
pushes it, and creates the GitHub Release with gh, from the files of
build/release/RCnn.

Usage: tools/release.py RCnn [--port /dev/ttyUSB1]
       tools/release.py RCnn --publish

Needs Vivado, coretool (mega65-tools), openFPGALoader, gh (logged in), and what make test needs.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

from bump import FLOWS, VERIFIED, Failed, badge, read_reports, run, check_tree

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STAGE = os.path.join(REPO, "build", "release")
STAMP = "release.json"
NOTES = "notes.md"

# The boards, in the order they are built; the R6 is the one tested
BOARDS = (
    ("r6", "MEGA65 R6"),
    ("r3", "MEGA65 R3"),
    ("nexys4ddr", "Nexys4DDR"),
)

# The boards with a core file (synth/Makefile.inc)
COR_BOARDS = ("r3", "r6")


def met(r):
    return badge("x", r)["color"] == "brightgreen"


def check_pushed():
    run(["git", "fetch", "--quiet", "origin", "main"])
    head = run(["git", "rev-parse", "HEAD"], capture=True)
    if head != run(["git", "rev-parse", "origin/main"], capture=True):
        raise Failed("HEAD is not origin/main; push it, and let CI run")
    return head


def check_tag_free(tag):
    if run(["git", "tag", "--list", tag], capture=True):
        raise Failed("the tag %s exists here" % tag)
    if run(["git", "ls-remote", "--tags", "origin", "refs/tags/" + tag], capture=True):
        raise Failed("the tag %s exists on origin" % tag)


def check_verified(tag):
    """verified.json must be for the tag and the submodule, and met; returns it."""
    with open(os.path.join(REPO, VERIFIED)) as f:
        v = json.load(f)
    if v["nice_cpu_tag"] != tag:
        raise Failed("%s is for %s, not %s; run make bump TAG=%s"
                     % (VERIFIED, v["nice_cpu_tag"], tag, tag))
    sub = run(["git", "rev-parse", "HEAD:nice_cpu"], capture=True)
    if v["nice_cpu_commit"] != sub:
        raise Failed("%s is for nice_cpu %s, but the submodule is at %s"
                     % (VERIFIED, v["nice_cpu_commit"][:7], sub[:7]))
    if not v["met"]:
        raise Failed("%s says %s missed timing; there is no release" % (VERIFIED, tag))
    return v


def check_ci(commit):
    out = run(["gh", "run", "list", "--workflow", "ci.yml", "--commit", commit,
               "--json", "status,conclusion"], capture=True)
    runs = json.loads(out or "[]")
    if not any(r["status"] == "completed" and r["conclusion"] == "success" for r in runs):
        state = ", ".join("%s/%s" % (r["status"], r["conclusion"] or "-") for r in runs) or "no run"
        raise Failed("CI has not passed for %s (%s)" % (commit[:7], state))


def build(board, flows):
    """The board's bitstream, from nothing and without a ROM, with the first
    flow that meets timing; returns the reports."""
    for flow in flows:
        run(["make", "-C", os.path.join("synth", board), "clean"])
        run(["make", board, "NICE=pipeline", "FLOW=" + flow, "ROM="])
        r = read_reports(os.path.join(REPO, "synth", board, "build"), flow)
        if met(r):
            return r
    raise Failed("%s misses timing (WNS %.3f ns with FLOW=%s)" % (board, r["wns_ns"], flow))


def notes(tag, v, results):
    lines = [
        "NiceMonMEGA65 with nice_cpu %s (%s)." % (tag, v["nice_cpu_commit"][:7]),
        "",
        "| Board | Clock | Flow | WNS |",
        "|---|---|---|---|",
    ]
    for board, name in BOARDS:
        r = results[board]
        lines.append("| %s | %.0f MHz | %s | %.3f ns |"
                     % (name, r["clock_mhz"], r["flow"], r["wns_ns"]))
    lines += [
        "",
        "Built with %s, tested on the MEGA65 R6 with `make hwtest`." % v["vivado"],
        "",
        "`nicemon-%s-r3.cor` and `nicemon-%s-r6.cor` are the core files," % (tag, tag),
        "for a slot of the MEGA65's flash with MEGAFLASH; each is for its",
        "board revision alone.",
        "",
        "The bitstreams have no ROM: the core waits, held, until the debug",
        "link loads and starts a program (`make load FILE=prog.bin`, see",
        "README.md). `examples-%s.zip` has the C examples as `.bin` files." % tag,
        "`EMULATOR.md` lists the known differences from `niceemu`.",
        "",
        "The R3 bitstream contains GPL v3 code (`synth/r3/max10.vhd`), and",
        "the MEGA65 bitstreams LGPL v3 code (`synth/mega65/hdmi/`); their",
        "source is this tag.",
    ]
    return "\n".join(lines) + "\n"


def stage(tag):
    v = check_verified(tag)
    check_tree()
    head = check_pushed()
    check_tag_free(tag)
    check_ci(head)

    run(["make", "-C", "nice_cpu/emulator", "build"])
    run(["make", "examples"])
    results = {}
    for board, _ in BOARDS:
        flows = (v["flow"],) if board == "r6" else FLOWS
        results[board] = build(board, flows)
    # The same options as the build, or make would build the bitstream again
    for board in COR_BOARDS:
        run(["make", "-C", os.path.join("synth", board), "cor", "NICE=pipeline",
             "FLOW=" + results[board]["flow"], "ROM=", "COR_VERSION=" + tag])
    return v, head, results


def write_stage(tag, v, head, results):
    out = os.path.join(STAGE, tag)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    files = []
    for board, _ in BOARDS:
        name = "nicemon-%s-%s.bit" % (tag, board)
        shutil.copy(os.path.join(REPO, "synth", board, "build", "top.bit"), os.path.join(out, name))
        files.append(name)
    for board in COR_BOARDS:
        name = "nicemon-%s-%s.cor" % (tag, board)
        shutil.copy(os.path.join(REPO, "synth", board, "build", "NiceMonMEGA65-%s.cor" % board),
                    os.path.join(out, name))
        files.append(name)
    zipped = shutil.make_archive(os.path.join(out, "examples-" + tag), "zip",
                                 os.path.join(REPO, "examples", "build"))
    files.append(os.path.basename(zipped))
    shutil.copy(os.path.join(REPO, VERIFIED), out)
    files.append(VERIFIED)
    with open(os.path.join(out, NOTES), "w") as f:
        f.write(notes(tag, v, results))
    with open(os.path.join(out, STAMP), "w") as f:
        json.dump({"tag": tag, "repo_commit": head, "nice_cpu_commit": v["nice_cpu_commit"],
                   "files": files}, f, indent=2)
        f.write("\n")
    return out


def publish(tag):
    out = os.path.join(STAGE, tag)
    try:
        with open(os.path.join(out, STAMP)) as f:
            s = json.load(f)
    except OSError:
        raise Failed("nothing is staged in %s; run tools/release.py %s first" % (out, tag))
    check_tree()
    head = check_pushed()
    if head != s["repo_commit"]:
        raise Failed("HEAD is %s, but %s was built from %s; stage it again"
                     % (head[:7], tag, s["repo_commit"][:7]))
    check_tag_free(tag)
    msg = "%s: NiceMonMEGA65 with nice_cpu %s (%s)" % (tag, tag, s["nice_cpu_commit"][:7])
    run(["git", "tag", "-a", tag, "-m", msg])
    run(["git", "push", "origin", "refs/tags/" + tag])
    run(["gh", "release", "create", tag, "--verify-tag", "--title", tag,
         "--notes-file", os.path.join(out, NOTES)]
        + [os.path.join(out, name) for name in s["files"]])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("tag", help="the nice_cpu tag, such as RC07")
    ap.add_argument("--port", default="/dev/ttyUSB1", help="the R6's serial port, for hwtest")
    ap.add_argument("--publish", action="store_true",
                    help="tag, push, and create the GitHub Release from what is staged")
    args = ap.parse_args()
    tag = args.tag

    try:
        if args.publish:
            publish(tag)
            print("release: %s is published" % tag)
            return
        v, head, results = stage(tag)
        run(["make", "hwtest", "BIT=synth/r6/build/top.bit", "PORT=" + args.port])
        out = write_stage(tag, v, head, results)
    except Failed as e:
        sys.exit("release: %s" % e)
    print("release: %s is staged in %s" % (tag, os.path.relpath(out, REPO)))
    print("Look at %s, then run make release TAG=%s ARGS=--publish" % (NOTES, tag))


if __name__ == "__main__":
    main()
