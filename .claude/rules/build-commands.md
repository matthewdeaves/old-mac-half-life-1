---
description: Commands to claim a build host, build, deploy and package; lock and chaining rules
paths:
  - "scripts/build-*.sh"
  - "scripts/make-*.sh"
  - "scripts/push-*.sh"
  - "scripts/fuse-*.sh"
  - "scripts/*-build-host.sh"
  - "scripts/*-dmg.sh"
  - "scripts/shared.sh"
  - "scripts/fleet-bench.sh"
  - "scripts/bench-adapter.sh"
  - "scripts/lock-check.sh"
---

# Build Commands and Orchestration

Build drivers run **locally on a build mini** (repo at `~/oldmac`) and do no ssh
of their own: claim a host, then run them there.

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

- `shared.sh` scripts come from the `shared-scripts.pin` revision; `bench-evidence.sh`
  needs `BENCH_ADAPTER="$REPO_ROOT/scripts/bench-adapter.sh"` set explicitly.
- `pick-*`, `deploy-dmg.sh` and `smoke-dmg.sh` are shims Jenkins calls by fixed
  path: never delete or move them.
- **Hold the host lock until the artifact is FETCHED off it, then release at
  once.** Name the host on `--acquire` when a specific one holds your artifacts.
  Story: `docs/BUILD-COMMANDS.md` "Build-host lock timing".
- **Chain with `&&`.** A `;` group exits with its last command's status, so
  refused deploys still print DONE. Story: "Chained steps report the last status".
- Pin bump for engine, menu or game code: `docs/adr/0012`; a moved submodule needs
  its recorded commit moved, not just `.gitmodules`.
- `OLDMAC_KEEP_BUILD=1` poisons `BUILD-STAMP`: never for anything shippable.
- `lipo`/`strings` checks run on this box, never Lion. Output goes under
  `~/oldmac/dist/`, never the repo root or a Desktop.
- `make-dmg.sh` can stage from `imac-2019` (`SRC_HOST`/`DMG_HOST`), issue #32.

Long-form notes and stories: `docs/BUILD-COMMANDS.md`.
