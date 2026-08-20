# 10. The System Report app targets lower floors than the game

Date: 2026-07-27
Status: accepted

## Context

`dyld` grades a fat by CPU subtype and ignores the OS (ADR 0001), so a machine
can be locked out by a combination nobody in the fleet owns: issue #14, a G5
below Leopard taking a slice it could not run, discoverable only by report.

`Half-Life System Report.app` lets someone whose Mac will not run the game say
what they have (issue #15). It reads the machine, names the slice it would load,
and copies the result to the clipboard for pasting into an issue.

Through v1.4.1 it could not do that for the two Intel cases the game then ruled
out.
Measured on that image: `[ppc, x86_64]` with `LC_VERSION_MIN_MACOSX 10.7` on the
x86_64 slice, so a 32-bit-only Core Solo or Core Duo had no slice and a 64-bit
Intel Mac on 10.6 had one it could not load (issue #24).

## Decision

**Build for the oldest OS each architecture supports at all, not for the game's
floors** (`scripts/build-sysreport.sh:29-31`):

| Slice | Toolchain | Minimum | Covers |
|---|---|---|---|
| `ppc` | `gcc-4.0`, 10.3.9 SDK | 10.3 | every PowerPC Mac from Panther |
| `i386` | clang, 10.4u SDK | 10.4 | Core Solo and Core Duo, 10.4 to 10.6 |
| `x86_64` | clang, 10.5 SDK | 10.5 | 64-bit Intel from Leopard onward |
| `arm64` | current clang, `build-sysreport-arm64.sh` | 11.0 | Apple Silicon, natively |

10.5 is the first Mac OS X with an x86_64 userland and 10.4 the first with any
Intel support, so nothing below these is uncovered. `arm64` is **optional**, as
it is for the engine and the installer: it is built on the orchestration box and
carried over by `push-mod-arm64.sh`, and without it Apple Silicon runs the
`x86_64` slice under Rosetta 2 and still reports correctly. The driver says which
case it is rather than leaving a missing slice silent.

The game's floors do not apply (`scripts/build-sysreport.sh:20-27`): the game's
Intel floor is where the engine's C++ runtime need bottoms out, and this app is
plain Objective-C against Cocoa, Foundation and OpenGL with no C++ standard
library at all; the 64-bit requirement came from HLSDK, and this app is about
240 KB.

Verified, not assumed: `scripts/build-sysreport.sh:104-115` reads
`LC_VERSION_MIN_MACOSX` back out of the linked binary with `otool` and fails the
build if `i386` is not 10.4 or `x86_64` is not 10.5.

## Alternatives rejected

- **The game's slices and floors.** What v1.4.1 shipped, and it defeats the app's
  purpose. v1.4.1 only corrected the disk image's `README.txt`, which had
  promised the app "runs on machines where the game itself does not" (issue #24).
- **An i386 slice for the game too.** Rejected here in 2026-07 for want of
  32-bit-only Intel hardware to test on, HLSDK being built 64-bit to match the
  engine (issue #22). **Reversed 2026-08-08**: the game, the mod dylibs and the
  installer all ship `i386` now (ADR 0001's amendment). It is still untested on
  hardware, for the same want of a Core Solo or Core Duo, and is built and
  arch-checked like every other slice.
- **A command-line tool or shell script.** The audience is someone whose game
  will not start: they need something to double-click and a result to paste. It
  reads only and sends nothing.
- **Sharing the game's icon.** It did, on the argument that it was one less piece
  of artwork to keep in step. **Reversed 2026-08**: two apps beside each other in
  the Dock have to be tellable apart, and the app someone runs when the game will
  not start is the worst one to leave looking like the game. It now ships
  `MacOSX/Half-Life-SysReport.icns`, the lab-coat bust
  (`scripts/build-sysreport.sh:128-133`, `docs/ICONS.md`).
- **Treating `[ppc, i386, x86_64]` as a violation of the exact-cpusubtype rule.**
  That rule is about a fat carrying several PowerPC slices of differing subtype,
  which Tiger and Leopard mis-grade on a 750 host; one PowerPC slice in a 2006
  three-way universal grades correctly on G3, G4, G5 and Intel alike
  (`scripts/build-sysreport.sh:36-40`).

## Consequences

- The two machine classes the game rules out can now report themselves.
- `sysreport/SRController.m` reports `arm64 (Apple Silicon), reporting as x86_64
  under Rosetta 2`, checking `sysctl.proc_translated` before `cputype` because
  under Rosetta 2 the sysctls describe the translated process. That is why a
  missing `arm64` slice is a downgrade rather than a wrong answer.
- Three SDKs must stay installed on the build minis, 10.3.9, 10.4u and 10.5, for
  an app of about 240 KB.
- The app can never acquire a C++ dependency, a modern Cocoa API or a 64-bit
  assumption without silently losing a slice, and the `otool` check is the only
  thing that would notice.
- Its slice set and its floors differ from the game's, so the disk image's README
  states both. Since 2026-08-08 the sets differ only in the PowerPC split: the
  game ships `ppc750` and `ppc7400`, this app one generic `ppc`.
- Risk: `i386` cannot be tested here (issue #22) and the 10.5 and 10.6 x86_64
  cases cannot be confirmed until there is a Snow Leopard machine (issue #16).
  Both are built and their headers verified with `lipo` and `otool` without the
  hardware. An untested slice that might work beats none, since the app exists
  for the machine nobody has.
- Risk: `LSMinimumSystemVersion` is 10.3.9 (`scripts/build-sysreport.sh:164`),
  below every slice's own floor, so each slice's `LC_VERSION_MIN` does the real
  gating:
  LaunchServices allows the launch and the loader gates it, as in the game
  bundle.

## Notes

The `ppc` slice records no `LC_VERSION_MIN_MACOSX` at all, because `gcc-4.0`
predates that load command (`scripts/build-sysreport.sh:66-67`). True of every PowerPC
slice of the game too, and why ADR 0001 sets the PowerPC OS floor by comparing
undefined symbols rather than by reading the binary.

The app's claims must track the game's slices: it shipped a claim that a G5 owner
needed Leopard after the `ppc970` slice was dropped, so `tests/test-repo.py` now
fails on `ppc970` appearing in any shipped string.
