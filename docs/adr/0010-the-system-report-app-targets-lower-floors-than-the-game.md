# 10. The System Report app targets lower floors than the game

Date: 2026-07-27
Status: accepted

## Context

`dyld` grades a fat binary by CPU subtype and ignores the OS (ADR 0001), so a
machine can be locked out by a combination nobody in the test fleet owns. Issue
#14 was exactly that: a G5 below Leopard took a slice it could not run, and the
only way to find out was for someone to report it.

`Half-Life System Report.app` exists so that a person whose Mac will not run the
game can still say what they have (issue #15). It reads the machine, names the
slice it would load, and copies the result to the clipboard for pasting into an
issue.

Through v1.4.1 it could not do that for the two Intel cases the game rules out.
Measured on that image, it was `[ppc, x86_64]` with `LC_VERSION_MIN_MACOSX 10.7`
on the x86_64 slice, so a 32-bit-only Core Solo or Core Duo had no slice, and a
64-bit Intel Mac on 10.6 had a slice it could not load. Those are precisely the
machines the app is most needed on (issue #24).

## Decision

**Build the report app for the oldest OS each architecture supports at all, not
for the game's floors.** From `scripts/build-sysreport.sh:28-30`:

| Slice | Toolchain | Minimum | Covers |
|---|---|---|---|
| `ppc` | `gcc-4.0`, 10.3.9 SDK | 10.3 | every PowerPC Mac from Panther |
| `i386` | clang, 10.4u SDK | 10.4 | Core Solo and Core Duo, 10.4 to 10.6 |
| `x86_64` | clang, 10.5 SDK | 10.5 | 64-bit Intel from Leopard onward |

10.5 is the first Mac OS X with an x86_64 userland and 10.4 the first with any
Intel support, so nothing is left uncovered below these.

The game's floors do not apply here, and the reasons are specific
(`build-sysreport.sh:20-25`). The Intel floor of 10.7 comes from `mainui` being
C++11 and needing libc++; this app is plain Objective-C against Cocoa, Foundation
and OpenGL, and links no C++ standard library. The 64-bit requirement came from
HLSDK; this app is about 240 KB and has no such tie.

The floors are verified rather than assumed: `build-sysreport.sh:86-96` reads
`LC_VERSION_MIN_MACOSX` back out of the linked binary with `otool` and fails the
build if `i386` is not 10.4 or `x86_64` is not 10.5.

## Alternatives rejected

**Keep the report app aligned with the game's slices and floors.** That is what
v1.4.1 shipped, and it defeats the app's only purpose. v1.4.1 corrected the disk
image's `README.txt`, which had promised the app "runs on machines where the game
itself does not", to say plainly which machines it covers. Honest, but not the
same as fixing it (issue #24).

**Ship an i386 slice for the game too.** Different question, and still no. There
is no 32-bit-only Intel hardware in the fleet to test on, and HLSDK is built
64-bit to match the engine. That gap is issue #22, separate from this one.

**A command-line tool or a shell script instead of an app.** The audience is
someone whose game will not start; they need something to double-click, and a
result they can paste. It reads only and sends nothing.

**Give it its own icon.** It shares the game's icon
(`build-sysreport.sh:104-106`): it is a companion to the game, and a third piece
of artwork would be one more thing to keep in step.

**Treat `[ppc, i386, x86_64]` as a violation of the exact-cpusubtype rule.** It
is not. That rule is about a fat carrying several PowerPC slices of differing
subtype, which Tiger and Leopard mis-grade on a 750 host. A plain three-way 2006
universal binary with one PowerPC slice grades correctly on G3, G4, G5 and Intel
alike (`build-sysreport.sh:35-39`).

## Consequences

**Gained**

- The two machine classes the game rules out can now report themselves.
- The app answers the question `dyld` cannot be asked: what this Mac is, and
  which slice it would take.
- The report distinguishes Apple Silicon from Intel. `SRController.m:141-152`
  reports `arm64 (Apple Silicon), reporting as x86_64 under Rosetta 2` by
  checking `sysctl.proc_translated` before `cputype`, because under Rosetta 2 the
  sysctls describe the translated process.

**Lost**

- Three SDKs must stay installed on the build minis, 10.3.9, 10.4u and 10.5, for
  an app of about 240 KB.
- The app can never acquire a C++ dependency, a modern Cocoa API, or a 64-bit
  assumption without silently losing a slice. The floors are a standing
  constraint on its source, and the `otool` check is the only thing that would
  notice.
- Its slice set now differs from the game's, so "which slices do we ship" has two
  answers and the disk image's own README has to state both.

**Risks accepted**

- The `i386` slice cannot be tested here at all: there is no 32-bit-only Intel
  Mac in the fleet (issue #22). The 10.5 and 10.6 x86_64 cases cannot be
  confirmed either until there is a Snow Leopard machine (issue #16). Both slices
  are built and their headers verified with `lipo` and `otool` without the
  hardware. Shipping an untested slice that might work was judged better than
  shipping none, given that the whole purpose of the app is the machine nobody
  has.
- `LSMinimumSystemVersion` in the bundle is 10.3.9
  (`build-sysreport.sh:132`), so the plist floor is below every slice's own
  floor and each slice's `LC_VERSION_MIN` does the real gating. On an Intel Mac
  the app is allowed to launch by LaunchServices and then gated by the loader,
  which is the same arrangement the game bundle uses.

## Notes

The `ppc` slice records no `LC_VERSION_MIN_MACOSX` at all, because `gcc-4.0`
predates that load command (`build-sysreport.sh:65-66`). That is true of every
PowerPC slice of the game as well, and is why ADR 0001 establishes a PowerPC OS
floor by comparing undefined symbols rather than by reading the binary.

What the app says has to stay true as the game's slices change. It shipped a
claim that a G5 owner needed Leopard after the `ppc970` slice was dropped, which
is why `tests/test-repo.py` now fails on `ppc970` appearing in any shipped
string.
