# Half-Life old-Mac port (Agent Router)

Half-Life 1 on Xash3D FWGS as ONE universal fat app across PowerPC and Intel Macs, from a single `Half-Life.app`.

This file is a high-level router. Depending on the task at hand, **you must read the relevant files in `.claude/rules/`** to get specific context and hard rules.

## Core Documentation Rules

- **Reasoning and rejected alternatives**: `docs/adr/`.
- **Anything that dates**: `README.md` or an issue.
- **NEVER PR or push to upstream repos**. Changes are commits on the `oldmac` branch of our own forks.

## Context Router

`build-commands.md`, `legacy-mac-hardware.md`, `core-facts.md`,
`build-verification.md` and `shipped-layout.md` carry `paths:` frontmatter and
load themselves when you read a matching file (mostly `scripts/**`) - you don't
need to fetch them by hand for that work. `working-method-and-hard-rules.md`
and `ticketing-workflow.md` are always loaded.

- **Build and Orchestration** (`build-commands.md`): host acquisition, build,
  deploy, slice fusion, engine/menu/game pins. `qemu-tiger3d` iteration:
  `scripts/pick-bench-host.sh --run qemu-tiger3d <label> -- <script>` wraps
  `scripts/deploy-dmg.sh`/`scripts/smoke-dmg.sh` as on any Mac; for
  `scripts/shared.sh bench-evidence.sh` the adapter never sets
  `BENCH_ARTEFACT` (this port's own `make-dmg.sh` stage is a trap-removed
  mktemp dir) - mount the current `dist/*.dmg`, copy out
  `Half-Life.app/Contents/MacOS/xash3d.bin`, and export
  `BENCH_ARTEFACT=<extracted path>` yourself; `scripts/vm-frame-check.sh`
  self-claims for the frame capture.
- **Fleet & Hardware** (`legacy-mac-hardware.md`): machine aliases, OS/CPU
  targets, Lion toolchain limits.
- **Core Architecture & Facts** (`core-facts.md`): CPU subtypes, Intel OS
  floors, SDL2 linking, renderer defaults, the Linux server.
- **Working Method & Hard Rules** (`working-method-and-hard-rules.md`):
  refutation pass, build-trust, content/code/packaging hard rules.
- **Ticketing** (`ticketing-workflow.md`): filing, board, `retro-server-infra`.
- **Build Verification** (`build-verification.md`): artifact/cpusubtype
  checks, launcher display profiles.
- **Shipped Layout** (`shipped-layout.md`): required `.app` bundle structure.

## Read on demand

- `README.md`: Fleet matrix, per-machine config, upstream credits.
- `docs/MODS.md`: Mods and rebuilds.
- `docs/MOD-AUDIT.md`: The source audit.
- `docs/ICONS.md`: Icons and the Panther size ceiling.
- `docs/LICENSING.md`: Licensing and terms.
- `docs/BENCHMARKING.md`: Timerefresh harness and benchmarking procedures.
- `docs/port/POWERPC-FINDINGS.md`: Write-ups of porting findings, including
  refuted mechanisms.
- `docs/INCIDENTS.md`: Process incidents behind the hard rules in
  `.claude/rules/`.
- `docs/port/PPC-PORT-NOTES.md`: Move onto mainline, including diagnoses made and retracted.
