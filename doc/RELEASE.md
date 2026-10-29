# Releasing NiceMonMEGA65

A release of this repository follows a release of nice_cpu. When nice_cpu
has a new tag, such as `V1.0`, this repository gets a tag `V1.0` too, and
a GitHub Release with the bitstreams. A nice_cpu tag that misses timing
on the MEGA65 gets no release here.

## Version names

nice_cpu's releases are named `Vmajor.minor`: `V1.0`, `V1.1`, and so on
(nice_cpu's `release/RELEASE.md`, "Version names"). The tags here follow:

- Every nice_cpu release gets a release here with the same name, which
  moves the `nice_cpu` submodule to the tag.
- A release here that leaves the submodule alone adds a third number:
  `V1.0.1`, `V1.0.2`, and so on.
- So the first two numbers of a tag here always name the nice_cpu tag it
  pins.
- The submodule pins only nice_cpu tags, never a commit between them. If
  a fix is needed from nice_cpu, nice_cpu releases first.

| NiceMonMEGA65 | `nice_cpu` | What it is |
|---|---|---|
| `V1.0` | `V1.0` | the submodule moved to `V1.0` |
| `V1.0.1` | `V1.0` | a change here only |
| `V1.0.2` | `V1.0` | another one |
| `V1.1` | `V1.1` | the submodule moved to `V1.1` |

The release candidates `RC02` and `RC04` to `RC06` came before `V1.0`,
and keep their names.

## What a release has

- An annotated tag `V1.0`: `V1.0: NiceMonMEGA65 with nice_cpu V1.0 (abc1234)`.
- A GitHub Release `V1.0` with these files:
  - `nicemon-V1.0-r6.bit`, `nicemon-V1.0-r3.bit`, and
    `nicemon-V1.0-nexys4ddr.bit`, the bitstreams, all with the demo of
    `demo/` in the ROM, which shows the tag in its title bar.
  - `nicemon-V1.0-r3.cor` and `nicemon-V1.0-r6.cor`, the MEGA65 core
    files for MEGAFLASH, with the version `V1.0`, and the same ROM.
  - `examples-V1.0.zip`, the C examples as `.bin` files.
  - `verified.json`, the MEGA65 R6's timing record from `make bump`.
- The release notes: the tag's section of
  [RELEASE_NOTES.md](RELEASE_NOTES.md), then the nice_cpu commit, each
  board's clock, flow, and WNS, the Vivado version, and the files.

## What you need

- Vivado 2025.1 (see [synth/](../synth/README.md)), for the three
  bitstreams.
- `coretool` of [mega65-tools](https://github.com/MEGA65/mega65-tools)
  on the PATH, for the core files.
- [openFPGALoader](https://github.com/trabucayre/openFPGALoader), and a
  MEGA65 R6 on its USB cable, for `make hwtest`.
- `gh`, GitHub's command line tool, logged in to an account that may
  push to this repository and create its releases.
- What `make test` and `make examples` need (see
  [CONTRIBUTING.md](../CONTRIBUTING.md)).
- For the test of the Ethernet station, the R6's Ethernet port on this
  computer's network, and a free IP address there.

## What must pass

- The working tree is clean, on `main`, and pushed: `HEAD` is
  `origin/main`.
- The tag is free, here and on `origin`.

- CI is green for the commit on `main` that gets the tag.
- `verified.json` is for the nice_cpu tag, the first two numbers of the
  tag, and says met. The default flow or `FLOW=timing` is fine.
- The submodule is at that nice_cpu tag.
- A point release, such as `V1.0.1`, needs the release `V1.0` here to
  exist first.
- `RELEASE_NOTES.md` has a section for the tag, whose heading has the
  date: `## V1.0 (2026-10-28)`.
- All three bitstreams meet timing.
- `make hwtest` passes on a MEGA65 R6, with its Ethernet station when
  `--eth` is given.

## The steps

1. Bump nice_cpu, and push:

       make bump TAG=V1.0 ARGS=--push

   If the badge is red (timing missed), stop. The red badge is still
   pushed, as the honest result, but no release is made.

2. Write the tag's section of `RELEASE_NOTES.md`: what a user of the
   bitstreams, the boards, or the tools can see changed since the release
   before, with upgrade notes first. Replace "(not yet released)" in its
   heading with the date, such as `## V1.0 (2026-10-28)`. Draw the
   README's pictures, `doc/images/demo.png` and `ethernet.png`, again
   with the tag, as the docstring of `tools/screenshot.py` says. Commit
   and push.

3. Wait for CI to pass on the pushed commit.

4. Connect a MEGA65 R6, with its Ethernet port on the network, then
   build, test, and stage the release:

       make release TAG=V1.0 [PORT=/dev/ttyUSB1] ARGS="--eth 192.168.1.65"

   This changes nothing in git. It checks the conditions above, builds
   the examples and the three bitstreams from nothing, makes the two core
   files with `coretool`, runs `make hwtest` on the R6, with `ETH=` when
   `--eth` is given, and puts the files in `build/release/V1.0/`, with
   `release.json`, which records the tag, the commit, and the files that
   step 6 publishes. It takes as long as three Vivado builds. `make clean`
   deletes `build/release/`, so do not run it between steps 4 and 6.

5. Look at `build/release/V1.0/notes.md`. A change to the section goes
   into `RELEASE_NOTES.md`, which means a new commit, so steps 3 and 4 again.
   Only a note for this release alone, such as a known problem of the
   build, goes into `notes.md` itself.

6. Publish:

       make release TAG=V1.0 ARGS=--publish

   This builds nothing. It reads `release.json`, checks that `main` has
   not moved since step 4,
   makes the tag, pushes it, and creates the GitHub Release from the staged
   files. If `main` has moved, do step 4 again.

## A release that keeps the submodule

A change here alone, after the release `V1.0`, is released as `V1.0.1`:
steps 2 to 6 with `TAG=V1.0.1`, without a bump. It builds and checks the
three bitstreams as a bump's release does, for a change here can cost
timing. The R6 tries the flow of `verified.json` first, and then the
other one.
`verified.json` and the badge stay as the bump left them, for they are
the claim of nice_cpu's tag; the release notes give this build's timing.
The core files have the version `V1.0.1`, which MEGAFLASH shows.

## When something goes wrong

- A failed check in step 4 changes nothing. Fix the cause, and run step 4
  again.
- The ROM can cost the R6 the margin of the bump's build, which has none.
  So step 4 builds the R6 with the flow of `verified.json` first, and
  then with the other one, and the notes say so when it took the other.
  If both miss, there is no release: the fix belongs in nice_cpu, and a
  new nice_cpu tag and bump follow.
- If step 6 fails after the tag is pushed, create the release by hand:

      gh release create V1.0 --verify-tag --title V1.0 \
         --notes-file build/release/V1.0/notes.md build/release/V1.0/*.bit \
         build/release/V1.0/*.cor build/release/V1.0/examples-V1.0.zip \
         build/release/V1.0/verified.json

- A release with a bug is not deleted. The fix is a point release here,
  or, if it is in nice_cpu, the next nice_cpu tag, or the release notes
  say what is wrong.
