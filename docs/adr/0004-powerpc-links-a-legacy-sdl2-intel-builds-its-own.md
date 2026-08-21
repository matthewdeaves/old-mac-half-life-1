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
under 10.4 and the G5 under 10.5, and the engine link fails against the 10.4u SDK
(`scripts/build-ppc-tiger.sh:26-30`). It was carried only by the `ppc970` slice,
dropped in v1.4.0 (ADR 0001), and is in no shipped slice since.

The link failure is measured. **The mechanism previously written here was
wrong and is retracted** (corrected 2026-08-20): this ADR said 2.0.6 links
"10.5-only AudioQueue, Text Input Services and Objective-C fast-enumeration
symbols". Only **AudioQueue** is new, and it arrives in **2.0.5**, not 2.0.6:
upstream commit `0265d3af9b`, "coreaudio: Move from AudioUnits to AudioQueues".
`AudioQueue.h` is absent from `MacOSX10.4u.sdk` and present in `MacOSX10.5.sdk`,
annotated `__OSX_AVAILABLE_STARTING(__MAC_10_5, ...)`. Text Input Services and
Objective-C fast enumeration are already used by stock **2.0.3**, which we ship;
`panther-sdl2` gates them behind `#if defined(MAC_OS_X_VERSION_10_5)` and
`leopard-sdl2` simply does not. So the difference is the gating, not the symbols.

**The version ceilings, restated correctly.** SDL **2.0.3** is the ceiling for
10.3.9 and 10.4; SDL **2.0.6** is the ceiling for 10.5. Two separate walls:
2.0.4 converts `NSAutoreleasePool` to `@autoreleasepool`, which needs a
clang-era Objective-C compiler and the only PowerPC compilers here are Apple
gcc-4.0/4.2; 2.0.5 is the AudioQueue move above. Only two legacy forks exist,
`alex-free/panther-sdl2` (2.0.3, 10.3.9+) and `alex-free/leopard-sdl2` (2.0.6,
10.5+), and neither goes higher.

An earlier version of this ADR also said 2.0.6 "refuses to compile below 10.6".
No such check exists: SDL2's `configure.ac` has no macOS floor. The failures are
compile and link failures against the old SDK, not a configure-time refusal.

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
  slices have no gamepad support. **Measured 2026-08-21: that flag is forced by
  the SDK floor, not a convenience.** Same `panther-sdl2` checkout, same
  `gcc-4.0`, same `-arch ppc -mcpu=7400`, configured `--enable-joystick
  --enable-haptic`, varying only the SDK: against 10.3.9 `make` exits 2, against
  10.5 it is clean and `SDL_sysjoystick.o`, `SDL_gamecontroller.o` and
  `SDL_syshaptic.o` all build.

  SDL2's only macOS joystick backend is written against the IOHIDManager API.
  `<IOKit/hid/IOHIDLib.h>` exists in the 10.3.9 and 10.4u SDKs, so the
  `#include` succeeds and the failure is a wall of `syntax error before
  'IOHIDElementRef'` rather than a missing header. On 10.5 that header pulls in
  `IOHIDBase.h`, `IOHIDDevice.h` and `IOHIDElement.h`, which declare
  `IOHIDDeviceRef`, `IOHIDElementRef` and `IOHIDManagerRef`; those three headers
  are absent below 10.5. `SDL_GameController` still compiles, but with the dummy
  joystick driver behind it it reports zero devices, so the engine's
  `joy_sdl2.c` finds no gamepads.

  **Fixed 2026-08-21, and the flag is now `--enable-joystick`.** SDL **1.2**'s
  darwin backend uses the older IOCFPlugIn / `IOHIDDeviceInterface` API, and
  `IOCFPlugIn.h` is present in both old SDKs, which is why the SDL 1.2 sister
  ports always had working joysticks on Panther and Tiger. Our `panther-sdl2`
  fork now carries `src/joystick/darwin/SDL_sysjoystick_legacy.c`, which
  reimplements SDL2's 13-function driver interface over that older API. Device
  discovery, HID element walking, value reading and auto-calibration are ported
  from SDL 1.2; the instance-id, GUID and attach/detach handling are what SDL2
  adds on top. Selection is by SDK version, so upstream's IOHIDManager file
  compiles to nothing below 10.5 and is used unchanged at 10.5 and above.

  The GUID deliberately keeps upstream's byte layout (vendor at `data[0]`,
  product at `data[8]`, name-derived Bluetooth-style fallback) so
  `gamecontrollerdb` entries keyed on it still match and a pad mapped on another
  platform maps here too. Vendor and product ids fall back to the USB registry
  dictionary two levels up, because 10.3 and 10.4 do not mirror every USB
  property onto the HID page.

  Verified: builds clean for `ppc` against the 10.3.9 SDK with
  `--enable-joystick`, upstream's `SDL_sysjoystick.o` correctly empty at 220
  bytes, the legacy object 19648 bytes and exporting all 13 `SDL_SYS_Joystick*`
  entry points.

  **Not verified on hardware.** No USB gamepad was available on a PowerPC Mac, so
  this is build-correct and reasoned rather than measured, and it ships on that
  basis. **Known limitation: no hotplug.** SDL 1.2 enumerated once at init and so
  does this, so a pad must be plugged in before the game starts; unplugging is
  noticed and the device then reports detached with axes and buttons zeroed.
  `--disable-haptic` stays, because force feedback needs the 10.5-only FFB API
  too and nothing here asks for rumble. Issue #2.
- Three SDL versions means three sets of behaviour to reason about when a
  display or input fault appears on one architecture and not the others.

**Risks accepted**

- The Intel SDL 2.0.22 and the `arm64` SDL 2.32.x sources are tarballs
  `scripts/build-lion.sh` and `scripts/build-arm64.sh` download from libsdl.org,
  so unlike every other input they carry a version string rather than a commit
  pin. This is the weakest link in the reproduction chain ADR 0002 sets up.
