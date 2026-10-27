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
    `nicemon-V1.0-nexys4ddr.bit`, the bitstreams, all without a ROM.
  - `nicemon-V1.0-r3.cor` and `nicemon-V1.0-r6.cor`, the MEGA65 core
    files for MEGAFLASH, with the version `V1.0`.
  - `examples-V1.0.zip`, the C examples as `.bin` files.
  - `verified.json`, the MEGA65 R6's timing record from `make bump`.
- The release notes: the nice_cpu commit, each board's clock, flow, and
  WNS, and the Vivado version.

## What must pass

- CI is green for the commit on `main` that gets the tag.
- `verified.json` is for the nice_cpu tag, the first two numbers of the
  tag, and says met. The default flow or `FLOW=timing` is fine.
- The submodule is at that nice_cpu tag.
- A point release, such as `V1.0.1`, comes after the release `V1.0` here.
- All three bitstreams meet timing.
- `make hwtest` passes on a MEGA65 R6.

## The steps

1. Bump nice_cpu, and push:

       make bump TAG=V1.0 ARGS=--push

   If the badge is red, stop here. The red badge is pushed as a result,
   but there is no release.

2. Wait for CI to pass on the pushed commit.

3. Connect a MEGA65 R6, then build, test, and stage the release:

       make release TAG=V1.0 [PORT=/dev/ttyUSB1]

   This changes nothing in git. It checks the conditions above, builds
   the examples and the three bitstreams from nothing, makes the two core
   files with `coretool`, runs `make hwtest` on the R6, and puts the files
   in `build/release/V1.0/`. It takes as long as three Vivado builds.

4. Look at `build/release/V1.0/notes.md`, and edit it if something is
   worth saying, such as a new feature or a known problem.

5. Publish:

       make release TAG=V1.0 ARGS=--publish

   This builds nothing. It checks that `main` has not moved since step 3,
   makes the tag, pushes it, and creates the GitHub Release from the staged
   files. If `main` has moved, do step 3 again.

## A release that keeps the submodule

A change here alone, after the release `V1.0`, is released as `V1.0.1`:
steps 2 to 5 with `TAG=V1.0.1`, without a bump. It builds and checks the
three bitstreams as a bump's release does, for a change here can cost
timing, and the R6 must meet timing with the flow of `verified.json`.
`verified.json` and the badge stay as the bump left them, for they are
the claim of nice_cpu's tag; the release notes give this build's timing.
The core files have the version `V1.0.1`, which MEGAFLASH shows.

## When something goes wrong

- A failed check in step 3 changes nothing. Fix the cause, and run step 3
  again.
- If step 5 fails after the tag is pushed, create the release by hand:

      gh release create V1.0 --verify-tag --title V1.0 \
         --notes-file build/release/V1.0/notes.md build/release/V1.0/*.bit \
         build/release/V1.0/*.cor build/release/V1.0/examples-V1.0.zip \
         build/release/V1.0/verified.json

- A release with a bug is not deleted. The fix is a point release here,
  or, if it is in nice_cpu, the next nice_cpu tag, or the release notes
  say what is wrong.
