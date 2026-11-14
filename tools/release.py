#!/usr/bin/env python3
"""Build, test, and publish a release: tag this repository V1.0, which pins nice_cpu's tag V1.0.

A release Vmajor.minor follows make bump (tools/bump.py), which moves
nice_cpu to the tag of the same name and records the timing of the MEGA65
and the Nexys4DDR in verified.json. A release Vmajor.minor.patch keeps the
submodule at the nice_cpu tag Vmajor.minor, and follows the release
Vmajor.minor here; it leaves verified.json and the badges as the bump left
them, for they are
nice_cpu's claim, and its notes give its own timing. So the first two numbers
of a tag here always name the nice_cpu tag it pins (doc/RELEASE.md). A release
has two steps, so that what is published can be looked at first.

The first step, tools/release.py V1.0, changes nothing in git. In this order
it checks that the tree is clean, is on main, and is pushed, that the tag is
not taken here, that a point release's Vmajor.minor is, that doc/RELEASE_NOTES.md has a
dated section for the tag, that verified.json
is for the nice_cpu tag and the submodule's commit and says met, that the
submodule is at that tag, and that CI passed for the commit. It then
builds the examples, the monitor and the demo of demo/ with the tag in
the monitor's banner and the demo's title bar, and the bitstreams of the
R6, the R3, and the Nexys4DDR, with the monitor in the ROM and from nothing,
each with FLOW=timing alone, as their Makefiles have it. Each must meet
timing. It makes the core files of the R3 and the R6, with the tag as
their version, which MEGAFLASH shows. Last it runs make hwtest on the R6 bitstream, so a MEGA65 R6
must be on PORT, and with --eth IP its Ethernet port on this computer's network. It copies the bitstreams, the core files, the demo, demo.bin, the weather display, weather.bin, a zip of the examples, and
verified.json to build/release/V1.0, with notes.md, the release notes, and
release.json, the commit they were built from. The notes start with the
tag's section of doc/RELEASE_NOTES.md, whose heading must have the date,
"## V1.0 (2026-11-02)", and add each board's timing and the files.

The second step, tools/release.py V1.0 --publish, builds nothing. It checks
that HEAD is still the commit of release.json, makes the annotated tag,
pushes it, and creates the GitHub Release with gh, from the files of
build/release/V1.0.

Usage: tools/release.py Vmajor.minor[.patch] --port DEVICE [--eth IP]
       tools/release.py Vmajor.minor[.patch] --publish

Needs Vivado, coretool (mega65-tools), openFPGALoader, gh (logged in), and what make test needs.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

from bump import (TAG, VERIFIED, Failed, Record, badge, read_reports, run, check_tree,
                  tag_commit)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STAGE = os.path.join(REPO, "build", "release")
STAMP = "release.json"
NOTES = "notes.md"
RELEASE_NOTES = os.path.join("doc", "RELEASE_NOTES.md")

# The boards, in the order they are built; the R6 is the one tested
BOARDS = (
    ("r6", "MEGA65 R6"),
    ("r3", "MEGA65 R3"),
    ("nexys4ddr", "Nexys4DDR"),
)

# The boards with a core file (synth/Makefile.inc)
COR_BOARDS = ("r3", "r6")

# The flow of every board, the one its Makefile sets
FLOW = "timing"

# The ROM of every board: the monitor, which the core boots from at
# power-up. The demo is an asset of its own, DEMO (#129), and so is the
# weather display of the examples, WEATHER (#128).
ROM = os.path.join(REPO, "monitor", "build", "monitor.bin")
DEMO = os.path.join(REPO, "demo", "build", "demo.bin")
WEATHER = os.path.join(REPO, "examples", "build", "weather.bin")


def met(r: Record) -> bool:
    return bool(badge("x", r)["color"] == "brightgreen")


def check_pushed() -> str:
    run(["git", "fetch", "--quiet", "origin", "main"])
    head = run(["git", "rev-parse", "HEAD"], capture=True)
    if head != run(["git", "rev-parse", "origin/main"], capture=True):
        raise Failed("HEAD is not origin/main; push it, and let CI run")
    return head


def nice_tag(tag: str) -> str:
    """The nice_cpu tag that a tag here pins: its first two numbers."""
    m = TAG.match(tag)
    if not m:
        raise Failed("%s is not Vmajor.minor or Vmajor.minor.patch, such as V1.0 or V1.0.1" % tag)
    return m.group(1)


def tag_exists(tag: str) -> bool:
    return bool(run(["git", "tag", "--list", tag], capture=True)
                or run(["git", "ls-remote", "--tags", "origin", "refs/tags/" + tag], capture=True))


def check_base(tag: str, nice: str) -> None:
    """A point release follows the release of its nice_cpu tag here."""
    if tag != nice and not tag_exists(nice):
        raise Failed("%s keeps the submodule at %s, but there is no release %s here; "
                     "run make bump TAG=%s and release it first" % (tag, nice, nice, nice))


def check_tag_free(tag: str) -> None:
    if run(["git", "tag", "--list", tag], capture=True):
        raise Failed("the tag %s exists here" % tag)
    if run(["git", "ls-remote", "--tags", "origin", "refs/tags/" + tag], capture=True):
        raise Failed("the tag %s exists on origin" % tag)


def check_verified(tag: str, nice: str) -> Record:
    """verified.json must be for the nice_cpu tag, which the submodule must
    be at, and met; returns it."""
    with open(os.path.join(REPO, VERIFIED)) as f:
        v: Record = json.load(f)
    if v["nice_cpu_tag"] != nice:
        if tag == nice:
            raise Failed("%s is for %s, not %s; run make bump TAG=%s"
                         % (VERIFIED, v["nice_cpu_tag"], nice, nice))
        raise Failed("%s is for nice_cpu %s, but %s must keep it at %s"
                     % (VERIFIED, v["nice_cpu_tag"], tag, nice))
    sub = run(["git", "rev-parse", "HEAD:nice_cpu"], capture=True)
    if v["nice_cpu_commit"] != sub:
        raise Failed("%s is for nice_cpu %s, but the submodule is at %s"
                     % (VERIFIED, v["nice_cpu_commit"][:7], sub[:7]))
    if tag_commit(nice) != sub:
        raise Failed("the submodule is at %s, not at nice_cpu's tag %s" % (sub[:7], nice))
    if not v["met"]:
        raise Failed("%s says %s missed timing; there is no release" % (VERIFIED, nice))
    return v


def section(tag: str) -> str:
    """The body of the tag's section of RELEASE_NOTES.md, which must be dated."""
    with open(os.path.join(REPO, RELEASE_NOTES)) as f:
        text = f.read()
    m = re.search(r"^## %s \((.*?)\)\n(.*?)(?=^## |\Z)" % re.escape(tag), text, re.M | re.S)
    if not m:
        raise Failed("%s has no section ## %s (YYYY-MM-DD)" % (RELEASE_NOTES, tag))
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", m.group(1)):
        raise Failed("the heading of %s in %s says (%s), not the date of the release"
                     % (tag, RELEASE_NOTES, m.group(1)))
    body = m.group(2).strip()
    if not body:
        raise Failed("the section %s of %s is empty" % (tag, RELEASE_NOTES))
    return body


def check_ci(commit: str) -> None:
    out = run(["gh", "run", "list", "--workflow", "ci.yml", "--commit", commit,
               "--json", "status,conclusion"], capture=True)
    runs = json.loads(out or "[]")
    if not any(r["status"] == "completed" and r["conclusion"] == "success" for r in runs):
        state = ", ".join("%s/%s" % (r["status"], r["conclusion"] or "-") for r in runs) or "no run"
        raise Failed("CI has not passed for %s (%s)" % (commit[:7], state))


def build(board: str) -> Record:
    """The board's bitstream, from nothing and with the monitor in the
    ROM; returns the reports, which must meet timing."""
    run(["make", "-C", os.path.join("synth", board), "clean"])
    run(["make", board, "NICE=pipeline", "FLOW=" + FLOW, "ROM=" + ROM])
    r = read_reports(os.path.join(REPO, "synth", board, "build"), FLOW)
    if not met(r):
        raise Failed("%s misses timing (WNS %.3f ns with FLOW=%s)" % (board, r["wns_ns"], FLOW))
    return r


def notes(tag: str, v: Record, results: dict[str, Record], body: str) -> str:
    lines = [
        body,
        "",
        "## Builds",
        "",
        "NiceMonMEGA65 %s with nice_cpu %s (%s)." % (tag, v["nice_cpu_tag"], v["nice_cpu_commit"][:7]),
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
    ]
    lines += [
        "",
        "## Files",
        "",
        "`nicemon-%s-r3.cor` and `nicemon-%s-r6.cor` are the core files," % (tag, tag),
        "for a slot of the MEGA65's flash with MEGAFLASH; each is for its",
        "board revision alone.",
        "",
        "The core files and the bitstreams have the monitor of `monitor/` in",
        "the ROM, which shows its prompt at power-up. `demo.bin` is the demo",
        "of `demo/`, a program for the monitor: copied into the folder `NICE`",
        "of an SD card, `load demo.bin` and `r` run it, which shows a welcome",
        "screen, and then what is typed on the keyboard; F12 goes back to the",
        "monitor. `weather.bin` is the weather display of `examples/`, a",
        "program for the monitor too, with the settings of",
        "`examples/README.md`: `load weather.bin` and `r` run it.",
        "The debug link still loads and starts a program",
        "(`make load FILE=prog.bin`, see README.md), and hides the ROM to",
        "do so. `examples-%s.zip` has the C examples as `.bin` files." % tag,
        "`doc/EMULATOR.md` lists the known differences from `niceemu`.",
        "",
        "The R3 bitstream contains GPL v3 code (`synth/r3/max10.vhd`), and",
        "the MEGA65 bitstreams LGPL v3 code (`synth/mega65/hdmi/`); their",
        "source is this tag.",
    ]
    return "\n".join(lines) + "\n"


def stage(tag: str) -> tuple[Record, str, dict[str, Record], str]:
    nice = nice_tag(tag)
    check_tree()
    head = check_pushed()
    check_tag_free(tag)
    check_base(tag, nice)
    body = section(tag)
    v = check_verified(tag, nice)
    check_ci(head)

    run(["make", "-C", "nice_cpu/emulator", "build"])
    run(["make", "examples"])
    run(["make", "-C", "monitor", "VERSION=" + tag])
    run(["make", "-C", "demo", "VERSION=" + tag])
    results: dict[str, Record] = {}
    for board, _ in BOARDS:
        results[board] = build(board)
    # The same options as the build, or make would build the bitstream again
    for board in COR_BOARDS:
        run(["make", "-C", os.path.join("synth", board), "cor", "NICE=pipeline",
             "FLOW=" + results[board]["flow"], "ROM=" + ROM, "COR_VERSION=" + tag])
    return v, head, results, body


def write_stage(tag: str, v: Record, head: str, results: dict[str, Record],
                body: str) -> str:
    out = os.path.join(STAGE, tag)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    files: list[str] = []
    for board, _ in BOARDS:
        name = "nicemon-%s-%s.bit" % (tag, board)
        shutil.copy(os.path.join(REPO, "synth", board, "build", "top.bit"), os.path.join(out, name))
        files.append(name)
    for board in COR_BOARDS:
        name = "nicemon-%s-%s.cor" % (tag, board)
        shutil.copy(os.path.join(REPO, "synth", board, "build", "NiceMonMEGA65-%s.cor" % board),
                    os.path.join(out, name))
        files.append(name)
    for path in (DEMO, WEATHER):
        shutil.copy(path, out)
        files.append(os.path.basename(path))
    zipped = shutil.make_archive(os.path.join(out, "examples-" + tag), "zip",
                                 os.path.join(REPO, "examples", "build"))
    files.append(os.path.basename(zipped))
    shutil.copy(os.path.join(REPO, VERIFIED), out)
    files.append(VERIFIED)
    with open(os.path.join(out, NOTES), "w") as f:
        f.write(notes(tag, v, results, body))
    with open(os.path.join(out, STAMP), "w") as f:
        json.dump({"tag": tag, "repo_commit": head, "nice_cpu_tag": v["nice_cpu_tag"],
                   "nice_cpu_commit": v["nice_cpu_commit"], "files": files}, f, indent=2)
        f.write("\n")
    return out


def publish(tag: str) -> None:
    nice_tag(tag)
    out = os.path.join(STAGE, tag)
    try:
        with open(os.path.join(out, STAMP)) as f:
            s: Record = json.load(f)
    except OSError:
        raise Failed("nothing is staged in %s; run tools/release.py %s first" % (out, tag))
    check_tree()
    head = check_pushed()
    if head != s["repo_commit"]:
        raise Failed("HEAD is %s, but %s was built from %s; stage it again"
                     % (head[:7], tag, s["repo_commit"][:7]))
    check_tag_free(tag)
    msg = "%s: NiceMonMEGA65 with nice_cpu %s (%s)" % (tag, s["nice_cpu_tag"], s["nice_cpu_commit"][:7])
    run(["git", "tag", "-a", tag, "-m", msg])
    run(["git", "push", "origin", "refs/tags/" + tag])
    run(["gh", "release", "create", tag, "--verify-tag", "--title", tag,
         "--notes-file", os.path.join(out, NOTES)]
        + [os.path.join(out, name) for name in s["files"]])


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("tag", help="the tag, such as V1.0, or V1.0.1 to keep nice_cpu at V1.0")
    ap.add_argument("--port", metavar="DEVICE", help="the R6's serial port, such as /dev/ttyUSB1, "
                    "passed to make hwtest; needed unless --publish")
    ap.add_argument("--eth", metavar="IP", help="also test the R6's Ethernet station, "
                    "with the IP address IP on this computer's network")
    ap.add_argument("--publish", action="store_true",
                    help="tag, push, and create the GitHub Release from what is staged")
    args = ap.parse_args()
    if not args.publish and not args.port:
        ap.error("--port is needed to test the R6, unless --publish")
    tag = args.tag

    try:
        if args.publish:
            publish(tag)
            print("release: %s is published" % tag)
            return
        v, head, results, body = stage(tag)
        run(["make", "hwtest", "BIT=synth/r6/build/top.bit", "PORT=" + args.port]
            + (["ETH=" + args.eth] if args.eth else []))
        out = write_stage(tag, v, head, results, body)
    except Failed as e:
        sys.exit("release: %s" % e)
    print("release: %s is staged in %s" % (tag, os.path.relpath(out, REPO)))
    print("Look at %s, then run make release TAG=%s ARGS=--publish" % (NOTES, tag))


if __name__ == "__main__":
    main()
