# 16. The mod arm64 slices are gated by the hlsdk commit both sides record

Date: 2026-08-22
Status: accepted

## Context

ADR 0015 closed the stale-arm64 hole for the Mods app and System Report, and
recorded that the 25 mod dylib pairs were not covered. This closes those.

`fuse-mod-arm64.sh` tested only that `dist/mods-arm64/<branch>/{server,client}.dylib`
existed. Nothing cleans `dist/mods-arm64` up and no mini can rebuild it, so the
slices sitting on a build host can be weeks older than the source the fat dylibs
beside them were built from. The fuse said `arm64 fused into N dylibs` either
way.

The trigger is a moved branch tip, not a pin bump. Each mod builds from its own
branch of hlsdk-portable, and both drivers check out `FETCH_HEAD`, so a rebuild
on the mini after the branch moved produces a fat from newer source than the
arm64 slice built on the dev box weeks earlier.

## Decision

Compare the commit both sides already record. `build-mod.sh` writes
`commit=` into `dist/mods/<b>/mod.info`, `build-mod-arm64.sh` writes it into
`dist/mods-arm64/<b>/arm64.info`. Neither needed changing. `fuse-mod-arm64.sh`
now refuses any mod where the two differ, or where either is absent.

A refused mod is not fused, so it ships with four slices and runs under Rosetta 2
on Apple Silicon, which is the same downgrade as an arm64 slice that was never
built. The run then exits 1, so the refusal cannot pass unnoticed, and the
message names the branches to rebuild rather than telling the operator to redo
all 25.

## Why a commit id here and a source hash in ADR 0015

The two apps build from directories inside this repo, and `~/oldmac` on a mini is
a hand-managed tree with no git in it, so the machine that has to CHECK the stamp
cannot name a commit. That is why they need the content hash in
`scripts/arm64-stamp.sh`.

Mods are different: both machines clone hlsdk-portable and both already run
`git rev-parse HEAD` on the tree they built. The commit is available on both
sides at no cost, and it is a record of what was built rather than of what was
asked for.

The patch scripts change the compiled code too and are in neither stamp. They do
not need to be. `scripts/driver-manifest.md5` already refuses a build whose patch
scripts are not the repo's, and the arm64 box builds from that same repo.

## The one case this cannot correct

A fat dylib that already carries an arm64 slice cannot be re-fused: `lipo -create`
fails on a duplicate architecture, and Lion's lipo cannot name arm64 to remove
it. So when a stale slice was already fused in an earlier run, the fuse reports
it and fails the run, and the remedy is `build-mod.sh <branch>`, which rebuilds
the fat from scratch.

This only arises on the retro-fit path, where `fuse-mod-arm64.sh` is run on its
own. A normal `build-mod.sh` run does `rm -rf` on each mod's output directory
first, so the fat it hands to the fuse never has an arm64 slice in it.

## Proved in both directions

Against a fixture of real Mach-O dylibs, running the shipped script:

| case | expected | got |
| --- | --- | --- |
| commits equal | fuse | fused, exit 0 |
| commits differ | refuse | refused, exit 1 |
| no `arm64.info` | refuse | refused, exit 1 |
| no `commit=` in `mod.info` | refuse | refused, exit 1 |
| stale and already fused | refuse and say why | refused, exit 1, names `build-mod.sh` |
| no arm64 slice at all | Rosetta 2 note, no refusal | exit 0 |
| a good tree fused twice | second run is a no-op | exit 0, `0 fused, 2 already had it` |

The fixture found one defect in the gate itself. `set -e` with `pipefail` meant a
`sed` on a missing `arm64.info` killed the script mid-loop: the first refusal
printed, then nothing, no summary and no remedy. The lookup now returns empty for
a missing file instead.

Real state on 2026-08-22, before any of this shipped: all 25 mods on mini-intel2
had matching commits, so the gate passes the current release state rather than
refusing it.
