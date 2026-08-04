# 4. PowerPC links a legacy SDL2 statically, Intel builds its own

Date: 2026-07-27
Status: accepted

## Context

Xash3D FWGS uses SDL2 for window, input and audio. That makes SDL2 the one
third-party dependency that has to exist on every machine this port targets, from
a G3 on 10.3.9 up.

Modern SDL2 does not build for those systems: it refuses to compile below 10.6
(`vendor/MANIFEST.md:148`, `README.md:179`). Its Cocoa backend uses APIs that
10.3 and 10.4 do not have, and its build assumes a toolchain those SDKs do not
ship.

alex-free publishes legacy native-Cocoa SDL2 builds for old Mac OS X, from the
"SDL2 for legacy Mac OS X" MacRumors thread (`vendor/MANIFEST.md:145-147`):
`panther-sdl2` is SDL 2.0.3 targeting 10.3.9 and up, `leopard-sdl2` is SDL 2.0.6
targeting 10.5 and up.

## Decision

**Both PowerPC slices link `panther-sdl2` 2.0.3, built from source and linked
statically. The Intel slice builds SDL 2.0.22 from source as a dylib.**

- `scripts/build-ppc-panther.sh:92-116` and `scripts/build-ppc-tiger.sh:106-129`
  cross-build `panther-sdl2` for `ppc` with `--disable-shared --enable-static`,
  at min-OS 10.3 and 10.4 respectively.
- Six patch scripts prepare that source tree:
  `patch-panther-sdl-version-guards`, `-displayname`, `-panther-apis`,
  `-cursors`, `-altivec-include` (Panther only), and `-textinput` (#29, the
  Cocoa text input teardown that leaves 10.3 and 10.4 unable to type into a
  menu text box).
- Because the PowerPC slices link SDL statically, `libxash.dylib` has no SDL load
  command on those slices, so the `libSDL2-2.0.0.dylib` shipped in the bundle is
  x86_64 only and the PowerPC slices never open it
  (`scripts/make-universal.sh:24-26`, `:70-77`).
- `scripts/build-lion.sh:25-29`, `:65` builds SDL 2.0.22 for x86_64 at min-OS
  10.7, with the Metal render driver disabled: FWGS needs SDL 2.0.16 or newer for
  the gyro and sensor GameController API in `joy_sdl2.c`, and newer SDL uses
  `@available`, which Xcode 4's clang does not have, only in the iOS and Metal
  paths.

## Alternatives rejected

**One SDL version for all three slices.** There is no version that works. 2.0.22
cannot be built for PowerPC on these SDKs, and 2.0.3 is below the 2.0.16 floor
the Intel engine needs.

**`leopard-sdl2` 2.0.6 for the G4 and G5.** Impossible for the shipped slice
layout. The `ppc7400` slice runs on the G4 under 10.4 and on the G5 under 10.5,
and 2.0.6 links 10.5-only AudioQueue, Text Input Services and Objective-C
fast-enumeration symbols, so the engine link fails outright against the 10.4u SDK
(`scripts/build-ppc-tiger.sh:26-30`). It was carried only by the `ppc970` slice,
which was dropped in v1.4.0 (ADR 0001), and since then it is in no shipped slice
(`vendor/MANIFEST.md:141-143`).

**Dynamic SDL on PowerPC.** Static linking removes a dylib that has to be found,
graded and loaded on machines where the loader is the thing most likely to go
wrong, and it lets the Panther build compile AltiVec out of SDL entirely so the
whole static library is guaranteed not to trap on a 750
(`scripts/build-ppc-panther.sh:112-117`).

**SDL 1.2, which is native to that era.** The engine is written against the SDL2
API; the platform layer is `engine/platform/sdl2/`.

## Consequences

**Gained**

- One SDL source tree covers every PowerPC machine in the fleet, at two minimum
  OS settings from the same 2.0.3 checkout.
- The PowerPC slices carry no external SDL dependency at all.
- A structural side effect, established in ADR 0001: `panther-sdl2` 2.0.3 guards
  the `CFRelease` in `Cocoa_GetDisplayModes()` behind
  `MAC_OS_X_VERSION_MIN_REQUIRED >= 1060`, so at min-OS 10.3 or 10.4 the
  SIGBUS-at-0x1 that `patches/leopard-sdl2-cocoamodes-getrule.patch` exists for
  cannot occur.

**Lost**

- PowerPC runs a 2014 SDL. Anything fixed in SDL since 2.0.3 is not fixed there,
  and there is no path to a newer one on these systems.
- Five patch scripts have to keep applying to a source tree that is not under
  version control here.
- Joystick and haptic are disabled in the PowerPC SDL builds
  (`--disable-joystick --disable-haptic`), so those slices have no gamepad
  support.
- Two SDL versions means two sets of SDL behaviour to reason about when a display
  or input fault appears on one architecture and not the other.

**Risks accepted**

- The SDL2 sources are downloaded, not cloned, so unlike every other input to the
  build they carry no commit pin and no mirror (`vendor/MANIFEST.md:136`,
  `scripts/bootstrap-vendor.sh:150`). If the MacRumors thread's downloads
  disappear, the PowerPC slices cannot be rebuilt from this repo alone. This is
  the weakest link in the reproduction chain that ADR 0002 sets up.
- `leopard-sdl2` and its patch are still present in the repo
  (`patches/leopard-sdl2-cocoamodes-getrule.patch`) and referenced by the retired
  a retired driver. Nothing shipping reads them.
