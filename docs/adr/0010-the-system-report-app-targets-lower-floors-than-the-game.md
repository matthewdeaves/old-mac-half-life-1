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

Through v1.4.1 it could not do that for the two Intel cases the game rules out.
Measured on that image: `[ppc, x86_64]` with `LC_VERSION_MIN_MACOSX 10.7` on the
x86_64 slice, so a 32-bit-only Core Solo or Core Duo had no slice and a 64-bit
Intel Mac on 10.6 had one it could not load (issue #24).

## Decision

**Build for the oldest OS each architecture supports at all, not for the game's
floors** (`scripts/build-sysreport.sh:28-30`):

| Slice | Toolchain | Minimum | Covers |
|---|---|---|---|
| `ppc` | `gcc-4.0`, 10.3.9 SDK | 10.3 | every PowerPC Mac from Panther |
| `i386` | clang, 10.4u SDK | 10.4 | Core Solo and Core Duo, 10.4 to 10.6 |
| `x86_64` | clang, 10.5 SDK | 10.5 | 64-bit Intel from Leopard onward |

10.5 is the first Mac OS X with an x86_64 userland and 10.4 the first with any
Intel support, so nothing below these is uncovered.

The game's floors do not apply (`build-sysreport.sh:20-25`): its Intel floor of
10.7 comes from `mainui` being C++11 and needing libc++, and this app is plain
Objective-C against Cocoa, Foundation and OpenGL with no C++ standard library;
the 64-bit requirement came from HLSDK, and this app is about 240 KB.

Verified, not assumed: `build-sysreport.sh:86-96` reads `LC_VERSION_MIN_MACOSX`
back out of the linked binary with `otool` and fails the build if `i386` is not
10.4 or `x86_64` is not 10.5.

## Alternatives rejected

- **The game's slices and floors.** What v1.4.1 shipped, and it defeats the app's
  purpose. v1.4.1 only corrected the disk image's `README.txt`, which had
  promised the app "runs on machines where the game itself does not" (issue #24).
- **An i386 slice for the game too.** No 32-bit-only Intel hardware in the fleet
  to test on, and HLSDK is built 64-bit to match the engine: issue #22.
- **A command-line tool or shell script.** The audience is someone whose game
  will not start: they need something to double-click and a result to paste. It
  reads only and sends nothing.
- **Its own icon.** It shares the game's (`build-sysreport.sh:104-106`), one less
  piece of artwork to keep in step.
- **Treating `[ppc, i386, x86_64]` as a violation of the exact-cpusubtype rule.**
  That rule is about a fat carrying several PowerPC slices of differing subtype,
  which Tiger and Leopard mis-grade on a 750 host; one PowerPC slice in a 2006
  three-way universal grades correctly on G3, G4, G5 and Intel alike
  (`build-sysreport.sh:35-39`).

## Consequences

- The two machine classes the game rules out can now report themselves.
- `SRController.m:141-152` reports `arm64 (Apple Silicon), reporting as x86_64
  under Rosetta 2`, checking `sysctl.proc_translated` before `cputype` because
  under Rosetta 2 the sysctls describe the translated process.
- Three SDKs must stay installed on the build minis, 10.3.9, 10.4u and 10.5, for
  an app of about 240 KB.
- The app can never acquire a C++ dependency, a modern Cocoa API or a 64-bit
  assumption without silently losing a slice, and the `otool` check is the only
  thing that would notice.
- Its slice set differs from the game's, so the disk image's README states both.
- Risk: `i386` cannot be tested here (issue #22) and the 10.5 and 10.6 x86_64
  cases cannot be confirmed until there is a Snow Leopard machine (issue #16).
  Both are built and their headers verified with `lipo` and `otool` without the
  hardware. An untested slice that might work beats none, since the app exists
  for the machine nobody has.
- Risk: `LSMinimumSystemVersion` is 10.3.9 (`build-sysreport.sh:132`), below
  every slice's own floor, so each slice's `LC_VERSION_MIN` does the real gating:
  LaunchServices allows the launch and the loader gates it, as in the game
  bundle.

## Notes

The `ppc` slice records no `LC_VERSION_MIN_MACOSX` at all, because `gcc-4.0`
predates that load command (`build-sysreport.sh:65-66`). True of every PowerPC
slice of the game too, and why ADR 0001 sets the PowerPC OS floor by comparing
undefined symbols rather than by reading the binary.

The app's claims must track the game's slices: it shipped a claim that a G5 owner
needed Leopard after the `ppc970` slice was dropped, so `tests/test-repo.py` now
fails on `ppc970` appearing in any shipped string.
