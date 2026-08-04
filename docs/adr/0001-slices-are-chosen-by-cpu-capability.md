# 1. Slices are chosen by CPU capability, not by OS version

Date: 2026-07-27
Status: accepted

## Context

The app is one Mach-O fat binary. `dyld` picks a slice from it by **CPU subtype
alone** and never looks at the OS version. That single fact drives every decision
below, because it means a slice cannot encode "requires 10.5": if the CPU matches,
the machine gets it, and if the code inside needs a newer OS than the machine is
running, the process does not start.

Between v1.1.0 and v1.3.1 the binary carried four slices:

| Slice | Built for | SDL2 | Toolchain |
|---|---|---|---|
| `ppc` | G3, 10.3 | panther-sdl2 2.0.3 | gcc-4.0, 10.3.9 SDK |
| `ppc7400` | G4, 10.3 | panther-sdl2 2.0.3 | gcc-4.0, 10.3.9 SDK |
| `ppc970` | G5, 10.5 | leopard-sdl2 2.0.6 | gcc-4.2, 10.5 SDK |
| `x86_64` | Intel, 10.7 | SDL2 dylib | clang, 10.7 SDK |

The `ppc970` slice existed for one reason: an intermittent SIGBUS on Finder launch,
observed when the G5 shared the G4's `ppc7400` slice and therefore panther-sdl2.
Giving the G5 its own slice built against leopard-sdl2 appeared to settle it.

That slice also created the problem it was later blamed for. leopard-sdl2 needs
10.5, so a G5 booted into 10.4 or 10.3 took a slice it could not run and did not
start at all, with no fallback. That was GitHub issue #14.

## Decision

**Ship three slices: `ppc`, `ppc7400`, `x86_64`. The G5 uses `ppc7400`.**

Slice selection keys on CPU capability, which is the only thing `dyld` can act on:

- `ppc` for the G3, which has no AltiVec unit
- `ppc7400` for the G4 and the G5, which both do
- `x86_64` for Intel

Where a decision depends on the OS rather than the CPU, it is made in the
launcher, which is a shell script and can read `sw_vers`. The display profile already
worked this way and is unchanged: Panther's broken `fullscreen` cvar is an OS fact and
is handled by OS, the G3's fillrate-bound Rage 128 is a CPU fact and is handled by CPU
subtype on every OS.

## Evidence

Everything below was measured on 2026-07-27, on an iMac G5 (PowerPC 970, 10.5.8,
Radeon 9600), against a build of v1.3.1 whose launcher was modified to run the
`ppc7400` slice.

**1. The crash that justified `ppc970` was never established.**
It was frequent for the user at the machine but never reproduced from a shell:
12/12 clean launches on `ppc`, 12/12 on `ppc7400` thinned, 10/10 with a fake `-psn`
argument. Only `open` ever showed it, at one launch in four. It was never
root-caused, because the launcher redirects stdio to a log file and a SIGBUS never
flushes it, so no backtrace was ever obtained.

**2. The SIGBUS signature belongs to leopard-sdl2, not panther-sdl2.**
`patches/leopard-sdl2-cocoamodes-getrule.patch` in this repo fixes a SIGBUS-at-0x1
on 10.5 PPC: `Cocoa_GetDisplayModes()` calls `CFRelease()` unconditionally on an
array that `CGDisplayAvailableModes()` still owns on pre-10.6. panther-sdl2 2.0.3
guards the same `CFRelease` behind `MAC_OS_X_VERSION_MIN_REQUIRED >= 1060`, so at
min-OS 10.4 it is compiled out and the fault cannot occur there. The library blamed
for the crash is the one structurally immune to it.

**3. `ppc7400` is faster on the G5 than `ppc970`.**
`scripts/bench.sh`, `timerefresh`, `gl`, 800x600 exclusive fullscreen, map `c0a0`,
300 frames, five runs plus a warmup, the two apps interleaved to control for thermal
drift:

| Slice | Round 1 min/med/max | Round 2 min/med/max |
|---|---|---|
| `ppc970` | 104.425 / **105.303** / 105.684 | 104.612 / **104.719** / 105.870 |
| `ppc7400` | 110.899 / **111.227** / 112.280 | 110.120 / **111.661** / 111.790 |

About 6% in favour of `ppc7400`, with no overlap across 16 runs. The G5-tuned slice
is the slower one. `ppc970` was built with gcc-4.2 and `-arch ppc970`; `ppc7400` with
gcc-4.0. Which of the compiler and the scheduling target accounts for the difference
was not separated, because the decision does not depend on knowing.

**4. `ppc7400` is stable on the G5.**
20 of 20 clean launches via `open`, the one method that had ever shown the fault, with
nothing else running. Plus a full tram intro played by hand to the guard opening the
door, which exercises the save/restore function-pointer path.

**5. The recorded "10.5 exclusive fullscreen hard-hangs" did not reproduce.**
The `ppc7400` slice ran `-fullscreen -width 800 -height 600` on the G5 repeatedly with
no hang. That quirk also appears to have been leopard-sdl2's. The shipped G5 profile
stays `-borderless` regardless, because a machine with a built-in display should run at
its panel's native resolution.

## Consequences

**Gained**

- The G5 gets about 6% more frames.
- A G5 on 10.4 or 10.3 now works by ordinary `dyld` grading, because `ppc7400`
  targets 10.3 and links panther-sdl2. That is what issue #14 asked for, reached by
  removing a slice rather than by adding a fallback.
- The `ppc-compat` fallback introduced in v1.3.1 is deleted: the thin-slice extraction
  in `make-app.sh`, the launcher's CPU/OS case, and its `XASH3D_RODIR` export. That
  code could never be tested on the combination it existed for.
- Nothing shipped links leopard-sdl2 any more, so
  `patches/leopard-sdl2-cocoamodes-getrule.patch` is no longer applied by any
  build. The file stays in the repo, for the same reason `scripts/build-ppc.sh`
  does: it is part of the record of how that slice was made.
- One fewer slice, one fewer toolchain path, one fewer build to verify per release.

**Lost**

- The G5 no longer runs code scheduled for its own pipeline. It is faster anyway.
- The G5 no longer uses SDL 2.0.6. SDL is not in the frame loop, so this is not a
  performance question; it does mean the G5 runs a 2014 SDL rather than a 2017 one.
- `scripts/build-ppc.sh` no longer contributes to the shipped binary. It is kept
  rather than deleted, because it is the only record of how the leopard-sdl2 slice
  was built.

**Risks accepted**

- A G5 running 10.4 or 10.3 is still untested here, because there is no such machine
  in the fleet. It should now work for the ordinary reason that it takes the same
  slice a G4 does. Issue #14 stays open for a hardware report.
- If the intermittent SIGBUS returns on a G5, it will return on the G4 too, since they
  now share a slice. The evidence says it will not, but 20 launches is 20 launches.

## Notes

The general rule this records, which outlived the specific decision: **a slice may
only be added for a CPU capability difference.** An OS difference is not a reason to
add one, because `dyld` cannot act on it, and a slice that needs a newer OS than its
CPU implies is a machine that will not start.

The corollary is that PowerPC slices carry no `LC_VERSION_MIN` at all, only the
`x86_64` slice does, so nothing in a PowerPC slice states its own OS floor. The way to
establish one is to compare its undefined symbols against a slice known to run on the
target OS. That is how the G4-on-Panther question was settled: `ppc7400` imports
exactly the same 332 undefined symbols as `ppc` in `libxash.dylib`, and `ppc` is
proven on 10.3.9 by the G3.
