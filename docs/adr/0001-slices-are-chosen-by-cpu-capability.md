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

**Ship five slices: `ppc750`, `ppc7400`, `i386`, `x86_64`, `arm64`.**
(Three until 2026-08-08; see the amendment at the end.) The G5 uses `ppc7400`.

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

## Amendment, 2026-08-08: two more slices, and the evidence that they are safe

The decision above is unchanged. What grew is the SET of CPU capabilities worth a
slice, once the last two gaps were closed:

- **`i386`** for the 2006 Core Solo and Core Duo Macs (Mac mini 1,1, iMac 4,1,
  MacBook 1,1, MacBook Pro 1,1). They have no 64-bit mode, so `x86_64` can never
  reach them, and they cap at 10.6.8, which the lowered Intel floor now matches.
- **`arm64`** for Apple Silicon, which until now ran `x86_64` under Rosetta 2.

Both are additive: a different cputype cannot displace an existing slice.

### The risk was mis-grading, not refusal

Old `dyld` has previous form here. A fat of `[ppc ALL, ppc7400, ppc970]`
mis-grades on a 750 host, which is why the executable's ppc slice is stamped to
the exact subtype in the first place. So the question was never "will it run",
it was "does adding a fourth cputype change which slice is chosen".

Tested with two hand-built fats (`scripts/` has no copy; the throwaway builder is
recorded in the task notes), identical except for the extra slice, in which
**each ppc slice prints its own name** so the answer is observed rather than
assumed:

    control:  ppc750 + ppc7400 + x86_64
    witharm:  ppc750 + ppc7400 + x86_64 + arm64

| machine | CPU | OS | control | with arm64 |
|---|---|---|---|---|
| `yosemite-tiger` | ppc750 | 10.4.11 | `SLICE=ppc750` | `SLICE=ppc750` |
| `mini-g4` | ppc7450 | 10.4.11 | `SLICE=ppc7400` | `SLICE=ppc7400` |
| `quicksilver` | ppc7450 | 10.4.11 | `SLICE=ppc7400` | `SLICE=ppc7400` |
| `g5-desktop` | ppc970 | 10.5.8 | `SLICE=ppc7400` | `SLICE=ppc7400` |
| `mini-sl` | x86_64 | 10.6.8 | ran | ran |
| `mini-intel2` | x86_64 | 10.7.5 | ran | ran |

Grading is identical in every case, including on the G3 under Tiger, which is
the exact machine and OS the historical mis-grading fault belongs to.

**Still untested: 10.3.9 Panther**, the oldest dyld shipped to. It needs the G3
or the G5 blessed into its Panther partition and rebooted.

### Lion's lipo can fuse arm64, it just cannot name it

The expected blocker was that the fuse happens on a 2011 machine. It is not one.
Lion's `/usr/bin/lipo` writes a correct fat containing arm64; it only fails to
NAME the slice, printing

    Architectures in the fat file: ... are: x86_64 (cputype (16777228) cpusubtype (0))

which is the same cosmetic quirk this project already records for Panther's lipo
and `x86_64`. Read back on a modern box the file is `x86_64 arm64`, with
`CPU_TYPE_ARM64` / `CPU_SUBTYPE_ARM64_ALL` and the correct 2^14 alignment, and
the arm64 slice runs natively. So the fuse stays in one place.

`arm64` is nonetheless the one slice that cannot be BUILT on a mini: Xcode 4.6
predates it by seven years. It is built on the Apple Silicon box by
`scripts/build-arm64.sh` and carried over by `scripts/push-arm64-slice.sh`, which
verifies the copy by checksum because `make-universal.sh` treats it as optional
and a slice that failed to arrive would otherwise just be missing from a release.

### Consequences for the game dylibs

The engine `dlopen`s game code by architecture NAME, and
`COM_GenerateLibraryName` special-cases 32-bit x86 on Apple, Windows and Linux
with no suffix at all, because that was Half-Life's original platform. So the
shipped set is `hl_ppc`, `hl_amd64`, `hl_arm64` and plain `hl` for i386, and the
same for `client`. Assuming a `_i386` suffix produces files the engine will never
look for.
