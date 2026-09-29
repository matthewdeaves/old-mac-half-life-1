---
description: How to verify a waf build actually succeeded, and how each slice is stamped
paths:
  - "scripts/build-*.sh"
  - "scripts/make-universal.sh"
  - "scripts/make-app.sh"
  - "scripts/patch-*.py"
---

# Build verification and slice stamping

Stories and detail: `docs/BUILD-VERIFICATION.md`.

## Never trust exit 0

waf can exit 0 with `Build failed` mid-log and install STALE objects. After EVERY build:

1. `grep` the log for `Build failed` and `error:` (ignore `--disable-werror`).
2. Every expected artifact (`xash3d` + all dylibs) has a mtime from THIS run.
3. `lipo -info` (or `-detailed_info`) on the dev box, never an old host: old `lipo`
   prints raw cputype for slices newer than itself. Expected: game `ppc750 ppc7400
   i386 x86_64 arm64`; mod dylibs, Mods app, System Report `ppc i386 x86_64 arm64`.
4. Where relevant, `LC_VERSION_MIN` and a patch's marker in the rebuilt output.

In doubt, `rm -rf` the `build-<target>` dirs first. `tests/test-artifact.sh` runs
after packaging, so a stale object with the right arch passes it.

## Tests

- Watch a regression test FAIL on the unfixed artifact before trusting it (issue #21).
- A test that cannot reach its assertion says INCONCLUSIVE, never PASS.
- A headless run of something needing a human is a false-FAIL generator; never
  hand another team that fail.
- Before "X cannot work", diff your test command against the real build command.

## Exact cpusubtype, never generic ppc ALL

Executable slices are exactly `ppc750` (G3) and `ppc7400` (G4 and G5; no ppc970).
`ppc ALL` execs on Panther but Tiger/Leopard refuse a `[ppc ALL, ppc7400]` fat on a
750 host. The G3 executable is re-stamped to subtype 9 in `build-ppc-panther.sh`;
dylibs stay ALL. See `docs/adr/0001`.

## Launcher display profile (`make-app.sh`)

Chosen by CPU first, OS second; profiles in `docs/adr/0007`. Never enumerate
cpusubtypes: the G3 is the only exception (subtype 9, `machine` = `ppc750`, gated on
`uname -p = powerpc`). Its 800x600 is keyed on CPU, not OS (issue #4).
