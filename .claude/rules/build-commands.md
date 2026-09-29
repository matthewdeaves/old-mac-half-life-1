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

Legacy build drivers run **locally on a build mini** (repo at `~/oldmac`) and do no ssh
of their own: claim a host, then run them there.

Commands, including all four local arm64 drivers: `docs/BUILD-COMMANDS.md`.


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
