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
statically. The Intel slices build SDL 2.0.22 from source as a dylib. `arm64`
builds a current SDL2 (2.32.x).**

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
- `scripts/build-lion.sh` builds SDL 2.0.22 with the Metal render driver
  disabled: FWGS needs SDL 2.0.16 or newer for the gyro and sensor
  GameController API in `joy_sdl2.c`, and newer SDL uses `@available`, which
  Xcode 4's clang does not have, only in the iOS and Metal paths. SDL is built
  **per floor and per architecture**, each in its own prefix
  (`sdl2-snow-<arch>` at 10.6, `sdl2-<arch>` at 10.7): a 10.7 `libSDL2` dropped
  into a 10.6 build links and installs without complaint and then refuses to
  load on 10.6, while an x86_64 one in an i386 build at least fails to link.
- `scripts/build-arm64.sh` builds a current SDL2 (`OLDMAC_ARM64_SDL`, 2.32.4 by
  default), deliberately unlike the Intel slices. 2.0.22 is pinned everywhere
  else because it is the newest SDL Apple clang 4.2 will compile, which is a
  fact about the Lion build box and not about Apple Silicon; 2.0.22 does not
  build under clang 21 at all. The engine's SDL guards are `SDL_VERSION_ATLEAST`
  tests written so one branch builds against both.

## Alternatives rejected

**One SDL version for every slice.** None works: 2.0.22 cannot be built for
PowerPC on these SDKs, 2.0.3 is below the 2.0.16 floor the Intel engine needs,
and 2.0.22 does not build under the modern clang the `arm64` slice uses.

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
- Three SDL versions means three sets of behaviour to reason about when a
  display or input fault appears on one architecture and not the others.

**Risks accepted**

- The Intel SDL 2.0.22 and the `arm64` SDL 2.32.x sources are tarballs
  `scripts/build-lion.sh` and `scripts/build-arm64.sh` download from libsdl.org,
  so unlike every other input they carry a version string rather than a commit
  pin. This is the weakest link in the reproduction chain ADR 0002 sets up.
