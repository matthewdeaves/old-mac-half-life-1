# Build Commands and Orchestration

The build drivers run **locally on a build mini** and do no ssh of their own, so
claim a host first, then run them there. The repo is at `~/oldmac` on both minis.

```sh
scripts/pick-build-host.sh --status            # who is free
HOST=$(scripts/pick-build-host.sh --acquire LABEL)
scripts/sync-build-host.sh $HOST               # FIRST. the mini does not pull.
ssh $HOST 'cd oldmac && scripts/build-all.sh'  # THE WHOLE BUILD. Use this.
scripts/pick-build-host.sh --release $HOST

# arm64 is the ONE slice a mini cannot build. Run these HERE, before build-all:
scripts/build-arm64.sh                         # engine, Apple Silicon box only
scripts/build-mod-arm64.sh --all               # the 25 mod dylib pairs
scripts/build-installer-arm64.sh               # the Mods app's own slice
scripts/build-sysreport-arm64.sh               # the System Report app's
scripts/push-arm64-slice.sh $HOST              # carries the engine over, verifies by md5
scripts/push-mod-arm64.sh $HOST                # carries the other three over

# The Linux dedicated server is the OTHER non-mini product, built in a
# container from the same pins. `docs/adr/0013`, operator docs `server/README.md`
scripts/build-server-x86_64.sh                 # x86_64: prefers imac-2019 (native
                                                #   linux/amd64), falls back to HERE
                                                #   (emulated) if it's busy/off/
                                                #   unreachable. Both produce
                                                #   byte-identical output (issue #22,
                                                #   measured 2026-08-30) - never make
                                                #   imac-2019 the only path.
                                                #   HOST=imac-2019 / HOST=workstation
                                                #   forces one side.
scripts/build-server-linux.sh --arch aarch64   # ARM VPS: runs HERE, no wrapper -
                                                #   this box is native for aarch64,
                                                #   imac-2019 would be the emulated
                                                #   side, so there is nothing to
                                                #   prefer it for. Issue #22.

scripts/make-dmg.sh [version-label]      # Tiger G4 ONLY, see the hard rules
scripts/pick-bench-host.sh --status      # bench/test boxes: who is free
scripts/deploy-dmg.sh HOST [version]     # install on a bench box as a user would
# Smoke and single-shot bench are TRIGGERED VIA old-mac-build-host, which runs
# these same scripts from a clone there, under the same lock. Trigger commands
# and the bench-CSV review flow: docs/BENCHMARKING.md.
scripts/smoke-dmg.sh HOST                # implementation; job smoke-halflife-<machine>
scripts/fleet-bench.sh -l LABEL [host]   # implementation; job bench-halflife-imac-g5
python3 tests/test-repo.py               # repo invariants, runs on this box
tests/test-artifact.sh                   # checks a built artifact
```

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
not take it, because the flow above already holds it and the lock is not
reentrant. `scripts/lock-check.sh`, issue #5.

`build-all.sh` runs `fetch-sources.sh`, the FOUR slice drivers it can run
(`build-lion.sh` twice, for x86_64 and for i386, then both PowerPC ones),
`make-universal.sh`, `make-app.sh`, then `build-installer.sh` and
`build-sysreport.sh`, in that order, checking each exit code. It does NOT build
arm64, which no mini can, and every fuse takes whatever slices it finds: a slice
that was never pushed is simply absent from the release, which is why each fuse
SAYS so either way. It does NOT build the 25 mod dylibs either: that is
`build-mod.sh`, it takes hours, and its output is an INPUT to
`build-installer.sh`.
**Do not run those steps chained by hand.** A pipeline returns its LAST command's
status, so `driver.sh 2>&1 | tail -25 && next.sh` reads `tail`'s status, and
`tail` always succeeds. That has already happened here: all three drivers
correctly refused to build a tree at the wrong pin, and the run still finished
saying "done".

`;` inside a group is the same trap wearing different clothes, and it caught a
release run on 2026-08-29. `{ echo A; deploy.sh X; echo B; echo DONE; }` reports
the status of the LAST `echo`, which cannot fail. Both deploys had refused
immediately, one because the version label wanted a `v` prefix and one because
the host was locked, and the group still exited 0 with "DONE" printed. The
script was right both times; the harness around it threw the answer away. Chain
with `&&`, and when steps must all run, check each one's status rather than the
group's.

To change engine, menu or game code: commit it on the `oldmac` branch of that
fork, push, bump the pin in `scripts/build-pins.sh`, `scp` that file to the mini,
then `build-all.sh`. If a submodule changed, **the recorded commit must move**;
editing `.gitmodules` is not enough. `docs/adr/0012`

`OLDMAC_KEEP_BUILD=1` skips the clean for a fast fix-compile loop. It poisons the
`BUILD-STAMP` so the result cannot be fused. Never use it for anything shippable.

`lipo` and `strings` checks belong on **this** box, never on Lion.
**All build output lives under `~/oldmac/dist/`**, never at the repo root and never
on a Desktop; `~/Desktop/Half-Life` is a deployed game, not a build directory.
