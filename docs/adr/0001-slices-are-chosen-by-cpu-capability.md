# 1. Slices are chosen by CPU capability, not by OS version

Date: 2026-07-27
Status: accepted

## Context

The app is one Mach-O fat binary, and `dyld` picks a slice by **CPU subtype
alone**, never by OS version. A slice cannot encode "requires 10.5": if the CPU
matches, the machine gets it, and if the code needs a newer OS, the process does
not start.

Between v1.1.0 and v1.3.1 the binary carried four slices:

| Slice | Built for | SDL2 | Toolchain |
|---|---|---|---|
| `ppc` | G3, 10.3 | panther-sdl2 2.0.3 | gcc-4.0, 10.3.9 SDK |
| `ppc7400` | G4, 10.3 | panther-sdl2 2.0.3 | gcc-4.0, 10.3.9 SDK |
| `ppc970` | G5, 10.5 | leopard-sdl2 2.0.6 | gcc-4.2, 10.5 SDK |
| `x86_64` | Intel, 10.7 | SDL2 dylib | clang, 10.7 SDK |

`ppc970` existed for one reason: an intermittent SIGBUS on Finder launch, seen
when the G5 shared the G4's `ppc7400` slice and therefore panther-sdl2. A G5 slice
built against leopard-sdl2 appeared to settle it, and created the problem it was
later blamed for: leopard-sdl2 needs 10.5, so a G5 booted into 10.4 or 10.3 took a
slice it could not run and did not start at all. GitHub issue #14.

## Decision

**Ship three slices: `ppc`, `ppc7400`, `x86_64`. The G5 uses `ppc7400`.**

- `ppc` for the G3, which has no AltiVec unit
- `ppc7400` for the G4 and the G5, which both do
- `x86_64` for Intel

Anything that depends on the OS rather than the CPU is decided in the launcher, a
shell script that can read `sw_vers`. The display profile already worked that way
and is unchanged: Panther's broken `fullscreen` cvar is an OS fact handled by OS,
the G3's fillrate-bound Rage 128 is a CPU fact handled by CPU subtype on every OS.

## Evidence

Measured 2026-07-27 on an iMac G5 (PowerPC 970, 10.5.8, Radeon 9600), against a
build of v1.3.1 whose launcher was modified to run `ppc7400`.

**1. The crash that justified `ppc970` was never established.** Frequent for the
user at the machine, never reproduced from a shell: 12/12 clean launches on `ppc`,
12/12 on `ppc7400` thinned, 10/10 with a fake `-psn` argument. Only `open` showed
it, at one launch in four, and it was never root-caused: the launcher redirects
stdio to a log file and a SIGBUS never flushes it.

**2. The SIGBUS signature belongs to leopard-sdl2, not panther-sdl2.** On 10.5
PowerPC, leopard-sdl2's `Cocoa_GetDisplayModes()` calls `CFRelease()`
unconditionally on an array `CGDisplayAvailableModes()` still owns pre-10.6,
giving a SIGBUS at 0x1; we carried a patch for it. panther-sdl2 2.0.3 guards the
same `CFRelease` behind `MAC_OS_X_VERSION_MIN_REQUIRED >= 1060`, so at min-OS 10.4
it is compiled out and the fault cannot occur.

**3. `ppc7400` is faster on the G5 than `ppc970`.** `scripts/bench.sh`,
`timerefresh`, `gl`, 800x600 exclusive fullscreen, map `c0a0`, 300 frames, five
runs plus a warmup, interleaved against thermal drift:

| Slice | Round 1 min/med/max | Round 2 min/med/max |
|---|---|---|
| `ppc970` | 104.425 / **105.303** / 105.684 | 104.612 / **104.719** / 105.870 |
| `ppc7400` | 110.899 / **111.227** / 112.280 | 110.120 / **111.661** / 111.790 |

About 6% for `ppc7400`, no overlap across 16 runs. `ppc970` was built with gcc-4.2
and `-arch ppc970`, `ppc7400` with gcc-4.0; which of the compiler and the
scheduling target accounts for it was not separated, because the decision does not
depend on knowing.

**4. `ppc7400` is stable on the G5.** 20 of 20 clean launches via `open`, the one
method that had ever shown the fault, nothing else running, plus a full tram intro
played by hand to the guard opening the door, which exercises the save/restore
function-pointer path.

**5. The recorded "10.5 exclusive fullscreen hard-hangs" did not reproduce.**
`ppc7400` ran `-fullscreen -width 800 -height 600` on the G5 repeatedly with no
hang; that quirk also appears to have been leopard-sdl2's. The shipped G5 profile
stays `-borderless` regardless, so a machine with a built-in display runs at its
panel's native resolution.

## Consequences

**Gained**

- About 6% more frames on the G5.
- A G5 on 10.4 or 10.3 works by ordinary `dyld` grading, because `ppc7400` targets
  10.3 and links panther-sdl2. That is what issue #14 asked for, reached by
  removing a slice rather than adding a fallback.
- The v1.3.1 `ppc-compat` fallback is deleted: the thin-slice extraction in
  `make-app.sh`, the launcher's CPU/OS case, and its `XASH3D_RODIR` export. It
  could never be tested on the combination it existed for.
- Nothing shipped links leopard-sdl2, so its patch and the ppc970 driver are
  deleted; the record of that slice is this ADR and the git history.
- One fewer slice, toolchain path and build to verify per release.

**Lost**

- The G5 no longer runs code scheduled for its own pipeline. It is faster anyway.
- The G5 runs a 2014 SDL rather than a 2017 one. SDL is not in the frame loop, so
  this is not a performance question.

**Risks accepted**

- A G5 on 10.4 or 10.3 is untested here, there being no such machine in the fleet.
  It should work because it takes the same slice a G4 does; issue #14 stays open
  for a hardware report.
- If the SIGBUS returns on a G5 it will return on the G4 too, since they share a
  slice. The evidence says it will not, but 20 launches is 20 launches.

## Notes

The general rule: **a slice may only be added for a CPU capability difference.**
`dyld` cannot act on an OS difference, and a slice needing a newer OS than its CPU
implies is a machine that will not start.

The corollary is that PowerPC slices carry no `LC_VERSION_MIN` at all, only
`x86_64` does, so nothing in a PowerPC slice states its own OS floor. To establish
one, compare its undefined symbols against a slice known to run on the target OS.
That settled the G4-on-Panther question: `ppc7400` imports exactly the same 332
undefined symbols as `ppc` in `libxash.dylib`, and `ppc` is proven on 10.3.9 by
the G3.
