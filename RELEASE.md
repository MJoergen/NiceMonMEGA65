# Releasing NiceMonMEGA65

A release of this repository follows a release of nice_cpu. When nice_cpu
has a new tag `RCnn`, this repository gets a tag `RCnn` too, and a GitHub
Release with the bitstreams. A nice_cpu tag that misses timing on the
MEGA65 gets no release here.

## What a release has

- An annotated tag `RCnn`: `RCnn: NiceMonMEGA65 with nice_cpu RCnn (abc1234)`.
- A GitHub Release `RCnn` with these files:
  - `nicemon-RCnn-r6.bit`, `nicemon-RCnn-r3.bit`, and
    `nicemon-RCnn-nexys4ddr.bit`, the bitstreams, all without a ROM.
  - `nicemon-RCnn-r3.cor` and `nicemon-RCnn-r6.cor`, the MEGA65 core
    files for MEGAFLASH, with the version `RCnn`.
  - `examples-RCnn.zip`, the C examples as `.bin` files.
  - `verified.json`, the MEGA65 R6's timing record from `make bump`.
- The release notes: the nice_cpu commit, each board's clock, flow, and
  WNS, and the Vivado version.

## What must pass

- CI is green for the commit on `main` that gets the tag.
- `verified.json` is for the tag and says met. The default flow or
  `FLOW=timing` is fine.
- All three bitstreams meet timing.
- `make hwtest` passes on a MEGA65 R6.

## The steps

1. Bump nice_cpu, and push:

       make bump TAG=RCnn ARGS=--push

   If the badge is red, stop here. The red badge is pushed as a result,
   but there is no release.

2. Wait for CI to pass on the pushed commit.

3. Connect a MEGA65 R6, then build, test, and stage the release:

       make release TAG=RCnn [PORT=/dev/ttyUSB1]

   This changes nothing in git. It checks the conditions above, builds
   the examples and the three bitstreams from nothing, makes the two core
   files with `coretool`, runs `make hwtest` on the R6, and puts the files
   in `build/release/RCnn/`. It takes as long as three Vivado builds.

4. Look at `build/release/RCnn/notes.md`, and edit it if something is
   worth saying, such as a new feature or a known problem.

5. Publish:

       make release TAG=RCnn ARGS=--publish

   This builds nothing. It checks that `main` has not moved since step 3,
   makes the tag, pushes it, and creates the GitHub Release from the staged
   files. If `main` has moved, do step 3 again.

## When something goes wrong

- A failed check in step 3 changes nothing. Fix the cause, and run step 3
  again.
- If step 5 fails after the tag is pushed, create the release by hand:

      gh release create RCnn --verify-tag --title RCnn \
         --notes-file build/release/RCnn/notes.md build/release/RCnn/*.bit \
         build/release/RCnn/examples-RCnn.zip build/release/RCnn/verified.json

- A release with a bug is not deleted. The fix goes into the next nice_cpu
  tag, or the release notes say what is wrong.
