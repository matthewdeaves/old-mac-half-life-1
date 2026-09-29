# Build commands: the long-form notes

The command reference below covers legacy and local arm64 builds.
Scoped reminders are in `.claude/rules/build-commands.md`. This page holds the stories and
measured facts behind them: how the shared scripts changed under the pin, when
to release a build-host lock, why a `;` group hides a failed step, and how
`make-dmg.sh` can stage from `imac-2019`. Read a section, not the file.

## Sections

- Shared fleet scripts and the pin
- Staging make-dmg.sh from imac-2019
- Build-host lock timing
- Chained steps report the last status
- Changing pinned engine, menu or game code
- Fast-loop builds and output locations

## Shared fleet scripts and the pin

Build-host#105 pin, #49. This repo no longer carries full copies of
`bench-evidence.sh`, `bench-compare.sh`, `gui-precondition.sh` or
`clear-launch-quarantine.sh`; `scripts/shared.sh` runs them from the
`old-mac-build-host` revision `shared-scripts.pin` names (needs a sibling
`../old-mac-build-host` checkout, or `OLDMAC_BUILDHOST_REPO` set).
`bench-evidence.sh` needs `BENCH_ADAPTER` set explicitly because it looks for the
adapter next to itself, which is the pin's read-only cache once fetched, not this
repo. Why the shims stay at their old paths: the header of
`scripts/pick-build-host.sh`.

`bench-evidence.sh`'s bundle `meta.json` now reads `"commit": "unknown"`: it
stamps the commit by `git rev-parse HEAD` next to its own location, which is
the read-only pin cache, not this repo, once wrapped. Harmless (nothing
checks that field for validity) and not worked around; `BENCH_ARTEFACT`'s
hash check is the real provenance guarantee.

## Staging make-dmg.sh from imac-2019

`make-dmg.sh` can stage from `imac-2019` instead of this workstation, with no
script change. It fetches the built app from `SRC_HOST`, stages (icons,
ad-hoc signing, `lipo -archs` on the mod dylibs and system report bundle),
then ships the staged image to `DMG_HOST` for `hdiutil` - two legs that both
cross whatever link the invoking box has. Nothing in the script hardcodes the
workstation as that box: `REPO_ROOT` is derived from the script's own
location, `SRC_HOST`/`DMG_HOST` are just hostnames. `imac-2019` has the same
`lipo`/`codesign`/`sips`/`iconutil` this needs and sits on the same fleet LAN
as every mini and Tiger box, so invoking it there instead removes the
workstation as a relay hop for the ~115 MB image. Verified end-to-end
2026-09-04: synced `scripts/*.sh` + `configs/` there (its `~/oldmac` is a
hand-managed tree, same as a mini's - no git, so a run from there stamps the
build id `git:unknown+dirty` instead of a real commit hash; harmless, just
missing that one provenance line), ran `SRC_HOST=mini-intel DMG_HOST=mini-g4
scripts/make-dmg.sh <label>` there directly, got a byte-verified DMG back.
`issue #32`.

## Build-host lock timing

**Hold the build-host lock until the artifact has been FETCHED off it, not until
the build finishes.** `make-dmg.sh` pulls the assembled bundle from a mini and
refuses to pull from one another session holds, for a good reason: `~/oldmac`
there is one tree shared by every repo. Releasing at "build done" opens a window
for another repo to claim the machine, and then the DMG cannot be cut from it.

Measured 2026-08-28, twice in one afternoon. Released `mini-intel` on completion;
`alephone` claimed it for a PowerPC build seconds later. Rebuilt on
`mini-intel2` instead, released that; `quakespasm` claimed it for a smoke run.
Both refusals were correct. Also note `--acquire` with no host picks ANY free
mini, so acquiring after the fact can hand you the machine your build is not on:
name the host explicitly when a specific one holds your artifacts.

**Then RELEASE it, the moment the fetch is done.** The rule above says when it
is safe to let go, not that letting go is optional. Same afternoon, having
learned the first half: held `mini-intel2` correctly through the DMG fetch and
then never released it at all, leaving it locked and idle for 77 minutes with
two other repos waiting, until the manager asked whether it was still live work.
Too early and too late are the same mistake with the sign flipped. The fetch
completing is the release trigger; nothing later in the release process needs
the mini.

`sync-build-host.sh` and the two push scripts refuse a mini that another session
has claimed. They CHECK the lock through `pick-build-host.sh --status`, they do
not take it, because the flow already holds it and the lock is not reentrant.
`scripts/lock-check.sh`, issue #5.

## Chained steps report the last status

`build-all.sh` runs the steps one per line for this reason (its header has the
pipe-to-`tail` story). `;` inside a group is the same trap wearing different
clothes, and it caught a release run on 2026-08-29.
`{ echo A; deploy.sh X; echo B; echo DONE; }` reports the status of the LAST
`echo`, which cannot fail. Both deploys had refused immediately, one because the
version label wanted a `v` prefix and one because the host was locked, and the
group still exited 0 with "DONE" printed. The script was right both times; the
harness around it threw the answer away. Chain with `&&`, and when steps must
all run, check each one's status rather than the group's.

## Changing pinned engine, menu or game code

Commit it on the `oldmac` branch of that fork, push, bump the pin in
`scripts/build-pins.sh`, `scp` that file to the mini, then `build-all.sh`. If a
submodule changed, **the recorded commit must move**; editing `.gitmodules` is
not enough. `docs/adr/0012`

`build-all.sh` does NOT build arm64, which no mini can, and every fuse takes
whatever slices it finds: a slice that was never pushed is simply absent from
the release, which is why each fuse SAYS so either way. It does NOT build the 25
mod dylibs either: that is `build-mod.sh`, it takes hours, and its output is an
INPUT to `build-installer.sh`.

## Fast-loop builds and output locations

`OLDMAC_KEEP_BUILD=1` skips the clean for a fast fix-compile loop. It poisons the
`BUILD-STAMP` so the result cannot be fused. Never use it for anything shippable.

`lipo` and `strings` checks belong on **this** box, never on Lion.
**All build output lives under `~/oldmac/dist/`**, never at the repo root and never
on a Desktop; `~/Desktop/Half-Life` is a deployed game, not a build directory.

## Command reference

```sh
scripts/pick-build-host.sh --status
HOST=$(scripts/pick-build-host.sh --acquire LABEL)
scripts/sync-build-host.sh $HOST               # FIRST, the mini does not pull
ssh $HOST 'cd oldmac && scripts/build-all.sh'  # the whole build; never chain steps
scripts/pick-build-host.sh --release $HOST

# arm64 is the one slice a mini cannot build: run HERE, before build-all
scripts/build-arm64.sh                         # engine
scripts/build-mod-arm64.sh --all               # 25 mod dylib pairs
scripts/build-installer-arm64.sh
scripts/build-sysreport-arm64.sh
scripts/push-arm64-slice.sh $HOST
scripts/push-mod-arm64.sh $HOST

scripts/build-server-x86_64.sh                 # Linux server, adr/0013
scripts/build-server-linux.sh --arch aarch64
scripts/make-dmg.sh [version-label]            # hdiutil step: Tiger G4 ONLY
scripts/pick-bench-host.sh --status
scripts/deploy-dmg.sh HOST [version]
scripts/smoke-dmg.sh HOST                      # smoke/bench flow: docs/BENCHMARKING.md
scripts/fleet-bench.sh -l LABEL [host]
scripts/shared.sh <name>.sh [args]             # bench-evidence, bench-compare,
                                               # gui-precondition, clear-launch-quarantine
```
