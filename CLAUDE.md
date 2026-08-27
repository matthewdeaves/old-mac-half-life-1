# Half-Life old-Mac port (Agent Router)

Half-Life 1 on Xash3D FWGS as ONE universal fat app across PowerPC and Intel Macs, from a single `Half-Life.app`.

This file is a high-level router. Depending on the task at hand, **you must read the relevant files in `.claude/rules/`** to get specific context and hard rules.

## Core Documentation Rules

- **Reasoning and rejected alternatives**: `docs/adr/`.
- **Anything that dates**: `README.md` or an issue.
- **NEVER PR or push to upstream repos**. Changes are commits on the `oldmac` branch of our own forks.

## Context Router

When you encounter specific problems, consult the following specialized context files before proceeding:

### 1. Build and Orchestration (`.claude/rules/build-commands.md`)
Read this for:
- Finding the exact commands to acquire a host, build, or deploy.
- Understanding how slices (`x86_64`, `i386`, `ppc`, `arm64`) are built and fused.
- Modifying engine, menu, or game code pins.

### 2. Fleet & Hardware (`.claude/rules/legacy-mac-hardware.md`)
Read this for:
- Navigating the specifics of the fleet (`yosemite`, `mini-intel`, the dual/quad G5s).
- Understanding OS targets and CPU capabilities.
- Lion build-box limitations (e.g. `strings`, `lipo`, older toolchains).

### 3. Core Architecture & Facts (`.claude/rules/core-facts.md`)
Read this for:
- Understanding architecture choices (CPU subtypes, Intel OS floors, SDL2 linking).
- Renderer default behavior (`gl_vsync`, `FCVAR_GLCONFIG`, `FCVAR_ARCHIVE`).
- The Linux dedicated server builds.

### 4. Working Method & Hard Rules (`.claude/rules/working-method-and-hard-rules.md`)
Read this for:
- Understanding the refutation pass.
- Verification steps (e.g. trusting `done`, codebase layout rules).
- Hard rules about content, code, and packaging.

### 5. Issue Tracking & Workflows (`.claude/rules/ticketing-workflow.md`)
Read this for:
- How to file and triage issues correctly.
- Managing project board transitions.
- Understanding constraints when interacting with `retro-server-infra`.

### 6. Build Verification (`.claude/rules/build-verification.md`)
Read this for:
- Procedures on verifying built artifacts, cpusubtype stamping, and the launcher's display profiles.

### 7. Shipped Layout (`.claude/rules/shipped-layout.md`)
Read this for:
- Understanding the required structure of the shipped `.app` bundle and where payload must sit.

## Read on demand

- `README.md`: Fleet matrix, per-machine config, upstream credits.
- `docs/MODS.md`: Mods and rebuilds.
- `docs/MOD-AUDIT.md`: The source audit.
- `docs/ICONS.md`: Icons and the Panther size ceiling.
- `docs/LICENSING.md`: Licensing and terms.
- `docs/BENCHMARKING.md`: Timerefresh harness and benchmarking procedures.
- `docs/port/POWERPC-FINDINGS.md`: Write-ups of porting findings.
- `docs/port/PPC-PORT-NOTES.md`: Move onto mainline, including diagnoses made and retracted.
