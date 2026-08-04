# 4. PowerPC links a legacy SDL2 statically, Intel builds its own

Date: 2026-07-27
Status: accepted

## Context

Xash3D FWGS uses SDL2 for window, input and audio, so SDL2 has to exist on every
machine this port targets, from a G3 on 10.3.9 up. Modern SDL2 does not build for
those systems: it refuses to compile below 10.6, its Cocoa backend uses APIs 10.3
and 10.4 do not have, and its build assumes a toolchain those SDKs do not ship
(`scripts/build-ppc-tiger.sh`, header).

alex-free publishes legacy native-Cocoa SDL2 builds for old Mac OS X, from the
"SDL2 for legacy Mac OS X" MacRumors thread: `panther-sdl2` is SDL 2.0.3 targeting
10.3.9 and up, `leopard-sdl2` is SDL 2.0.6 targeting 10.5 and up.

## Decision

**Both PowerPC slices link `panther-sdl2` 2.0.3, built from source and linked
statically. The Intel slice builds SDL 2.0.22 from source as a dylib.**

- `scripts/build-ppc-panther.sh` and `scripts/build-ppc-tiger.sh` cross-build
  `panther-sdl2` for `ppc` with `--disable-shared --enable-static`, at min-OS 10.3
  and 10.4 respectively.
- The SDL fixes those slices need are commits on our own `panther-sdl2` branch,
  pinned by `PIN_SDL_*` in `scripts/build-pins.sh`, so the tree
  `scripts/fetch-sources.sh` checks out is already ported. They include the Cocoa
  text input teardown that left 10.3 and 10.4 unable to type into a menu text box
  (#29), and the `#if [!]defined(MAC_OS_X_VERSION_10_5)` gates, written for a
  native Panther or Tiger compiler, that our Lion cross-SDK does define.
- With SDL static, `libxash.dylib` has no SDL load command on those slices, so the
  `libSDL2-2.0.0.dylib` in the bundle is x86_64 only and the PowerPC slices never
  open it (`scripts/make-universal.sh`).
- `scripts/build-lion.sh` builds SDL 2.0.22 for x86_64 at min-OS 10.7 with the
  Metal render driver disabled: FWGS needs SDL 2.0.16 or newer for the gyro and
  sensor GameController API in `joy_sdl2.c`, and newer SDL uses `@available`,
  which Xcode 4's clang does not have, only in the iOS and Metal paths.

## Alternatives rejected

**One SDL version for all three slices.** None works: 2.0.22 cannot be built for
PowerPC on these SDKs, and 2.0.3 is below the 2.0.16 floor the Intel engine needs.

**`leopard-sdl2` 2.0.6 for the G4 and G5.** The `ppc7400` slice runs on the G4
under 10.4 and the G5 under 10.5, and 2.0.6 links 10.5-only AudioQueue, Text Input
Services and Objective-C fast-enumeration symbols, so the engine link fails
against the 10.4u SDK (`scripts/build-ppc-tiger.sh:26-30`). It was carried only by
the `ppc970` slice, dropped in v1.4.0 (ADR 0001), and is in no shipped slice since.

**Dynamic SDL on PowerPC.** Static linking removes a dylib that has to be found,
graded and loaded on machines where the loader is most likely to go wrong, and it
lets the Panther build compile AltiVec out of SDL entirely so the static library
cannot trap on a 750 (`scripts/build-ppc-panther.sh`).

**SDL 1.2, native to that era.** The engine is written against the SDL2 API; the
platform layer is `engine/platform/sdl2/`.

## Consequences

**Gained**

- One SDL source tree covers every PowerPC machine in the fleet, at two minimum OS
  settings from the same 2.0.3 checkout, with no external SDL dependency.
- A structural side effect, established in ADR 0001: `panther-sdl2` 2.0.3 guards
  the `CFRelease` in `Cocoa_GetDisplayModes()` behind
  `MAC_OS_X_VERSION_MIN_REQUIRED >= 1060`, so at min-OS 10.3 or 10.4 the
  SIGBUS-at-0x1 that leopard-sdl2 needed a patch for cannot occur.

**Lost**

- PowerPC runs a 2014 SDL. Nothing fixed in SDL since 2.0.3 is fixed there, and
  there is no path to a newer one on these systems.
- The PowerPC SDL builds set `--disable-joystick --disable-haptic`, so those
  slices have no gamepad support.
- Two SDL versions means two sets of behaviour to reason about when a display or
  input fault appears on one architecture and not the other.

**Risks accepted**

- The Intel SDL 2.0.22 source is a tarball `scripts/build-lion.sh` downloads from
  libsdl.org, so unlike every other input it carries no commit pin. This is the
  weakest link in the reproduction chain ADR 0002 sets up.
