---
description: How to verify a waf build actually succeeded, and how each slice is stamped
paths:
  - "scripts/build-*.sh"
  - "scripts/make-universal.sh"
  - "scripts/make-app.sh"
  - "scripts/patch-*.py"
---

# Build verification and slice stamping

## NEVER trust "done" or exit 0

The waf-based PPC/Intel builds can exit 0 even when a compile task FAILED
(`Build failed` / `task in xash failed with exit status 1` appears mid-log), and
the install step then silently ships STALE objects from a previous build. That is
a fake-success slice: it looks built, it installs, and it is old code.

After EVERY build you MUST:

1. `grep` the build log for `Build failed` and `error:` (ignore `--disable-werror`).
2. Confirm every expected artifact (`xash3d` + all dylibs) has a FRESH mtime from
   THIS run, not a mix of old and new.
3. Confirm arch/subtype with `lipo -info` (or `lipo -detailed_info`); where
   relevant check `LC_VERSION_MIN` and that a source patch's marker is present in
   the rebuilt output.

Run `lipo` on the dev box, for the same reason `strings` has to be run there.
Panther's `lipo` predates x86_64 and cannot name that slice: on a correct fat it
prints `ppc750 ppc7400 (cputype (16777223) cpusubtype (-2147483645))`, which
reads like a missing or malformed slice and is not. The dev box prints the
expected `ppc750 ppc7400 x86_64`.

When in doubt, force-clean the waf out dirs (`rm -rf` the `build-<target>` dirs,
e.g. `build-panther` / `build-tiger`) before rebuilding so no stale objects
survive.

`tests/test-artifact.sh` checks the shape of a finished disk image and is not a
substitute for any of the above: it runs after packaging, so a stale object that
happens to have the right architecture passes it.

## Exact cpusubtype, never generic ppc ALL

Each PPC slice MUST carry its EXACT cpusubtype: **ppc750** (G3) and **ppc7400**
(G4, and the G5). Never ship a generic `ppc (ALL)` **executable** slice. It loads
on Panther, whose 2003 dyld is lax, but Tiger and Leopard mis-grade a fat of
`[ppc ALL, ppc7400]` on a 750 host and refuse to exec, so the failure appears on
a machine other than the one you built for.

- The G3 slice is built `-arch ppc`, then its **executable's** Mach-O cpusubtype
  is re-stamped to POWERPC_750 (9) in `build-ppc-panther.sh`. The **dylibs stay
  ALL**: `dlopen` grades those fine on a 750 host.
- Only two PowerPC slices ship. `build-ppc.sh` builds the retired ppc970 /
  leopard-sdl2 slice and contributes nothing; it is kept as the record of how
  that slice was made. See
  `docs/adr/0001-slices-are-chosen-by-cpu-capability.md`.

## Display profile is chosen in the launcher, not by slice

`make-app.sh` writes a shell launcher that picks by CPU and OS, because `dyld`
cannot act on an OS difference at all:

- G3 (subtype 9 / `machine` = `ppc750`, gated on `uname -p = powerpc`): exclusive
  800x600 fullscreen on any OS, which suits its Rage 128. This is a fillrate
  decision about the CPU, not about the OS.
- Every other PowerPC machine, 10.3 through 10.5: `-borderless` at the display's
  native resolution. Panther's `fullscreen` cvar IS broken, which is why 10.3 was
  once pinned to 800x600 here, but `-borderless` is SDL fullscreen-desktop and
  never touches that cvar. Measured on the dual G5's Panther partition (10.3.9
  build 7W98, Radeon 9600): `Window size: 1680x1050 (real 1680x1050)`, hardware
  GL. Issue #41.
- Intel: exclusive `-fullscreen`. `-borderless` on 10.7 leaves the menu bar's top
  22 pixels unpainted as a white strip.

Never enumerate all cpusubtypes. The G3 is the only CPU exception.
