# Release script

`release.py` runs the steps of [RELEASE.md](RELEASE.md) that need no
human. It runs the stages in order, and stops at the first that fails.

    release/release.py --version v1.0 --port r6=/dev/ttyUSB1

The stages are `prepare`, `sw`, `docs`, `ci`, `bits`, `hw`, `compare`, and
`tag`. `--from STAGE` resumes after a fix, `--only STAGE` runs one, and
`--boards`, `--nice`, and `--flow` choose the boards, the core, and the Vivado
flow. A board without a `--port` is skipped by `hw` and `compare`.

The `tag` stage is a dry run unless `--publish` is given. It then asks, tags
the commit, pushes the tag, and creates a GitHub release with the bitstreams.

Logs and the results are in `release/build/`: `report.md` has the timing,
utilization, and test figures to paste into the READMEs and the tag message.
The script ends with a list of the checks left to do by hand.

The script stops if `HEAD` moves, as the bitstreams must be built from the
released commit. After updating the figures in the READMEs, commit them and
run again with `--from ci`.
