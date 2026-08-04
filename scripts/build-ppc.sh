#!/bin/bash
# Phase 2 - PowerPC (ppc970) Half-Life (Xash3D FWGS) for Mac OS X 10.5 Leopard (iMac G5).
# This is the G5's DEDICATED slice in the universal fat binary (cpusubtype ppc970), carrying
# leopard-sdl2 2.0.6. The G5 auto-selects it; the G4 stays on the tiger ppc7400 slice.
# RUN THIS ON AN INTEL LION MINI - either mini-intel or mini-intel2 (identical
# Macmini2,1 / 10.7.5 / same toolchain). It runs LOCALLY on that box and does no
# ssh of its own, so pick-build-host.sh does not apply here - run
# `scripts/pick-build-host.sh --status` to see which mini is free, then log in
# there and run this. CROSS-compiles the PPC slice on Intel:
# Lion 10.7 has no Rosetta, so nothing ppc runs here - waf/SDL build in cross mode
# and the result is bench-tested on the iMac G5. Proven working 2026-07-22: engine +
# renderers + menu + game dylibs all link as Mach-O ppc7400.
#
# WHY each step is the way it is (hard-won - do not "simplify" without testing):
#
#  Toolchain: Apple gcc-4.2/g++-4.2 (the ONLY ppc-capable compiler on the mini; Xcode
#    4.6.3 clang dropped the ppc backend). gcc-4.2 => C++98/03 only, no C++11, and it
#    predates a pile of things the modern engine assumes. All the shims below exist to
#    bridge that gap. The 10.5 SDK lives in /Developer/SDKs/MacOSX10.5.sdk.
#
#  Endianness is decided at compile time from the real -arch ppc macro (__BIG_ENDIAN__)
#    inside build.h, so the ppc slice gets XASH_BIG_ENDIAN automatically. BUT waf probes
#    DEST_CPU with the *bare* compiler (no -arch ppc) and mis-detects x86_64 - patched in
#    the engine's scripts/waifulib/xcompile.py (oldmac_fixup_dest_cpu) so opus/etc. stop
#    enabling x86 SSE on ppc. hlsdk's public/build.h also needed __ppc__/__POWERPC__ added
#    to its arch test (Apple spells it that way, not __PPC__/__powerpc__).
#
#  SDL2: stock SDL 2.0.6+ has a hard "#error ... 10.6 and above" and Leopard-incompatible
#    Cocoa. Use alex-free/leopard-sdl2 (SDL 2.0.6 pre-patched for 10.5 PPC/Intel), built
#    from source as a STATIC lib in autotools cross mode (--host=powerpc-apple-darwin9)
#    so its configure never runs a ppc test binary. It links into libxash; no dylib to bundle.
#
#  compat-include shims (~/oldmac/compat-include), added via -isystem for C++:
#    - cinttypes / cstdint : gcc-4.2 libstdc++ predates these C++11 headers; the shims map
#      them to <inttypes.h>/<stdint.h>. cinttypes also #defines __STDC_FORMAT_MACROS so
#      PRIi64 & friends actually appear in C++.
#    - oldmac_cxx11.h (force-included with -include, ENGINE ONLY): nullptr/final/override/
#      constexpr fallbacks for the menu (mainui). NOT used for hlsdk - GoldSrc code uses
#      `override` as an identifier, so blanking it there breaks the build.
#
#  Other deltas. NOTHING is committed into the vendor trees - vendor/ is git-ignored and
#  must stay re-clonable, so each of these lives in this repo and is re-applied to a fresh
#  clone (patches/vendor/*.handedits.diff by scripts/bootstrap-vendor.sh, patch-*.py by the
#  build drivers). This retired script assumes a tree the LIVE drivers have already set up:
#    - ~12 duplicate-typedef guards/demotions (C11 allows identical typedef redefinition,
#      gcc-4.2 does not): searchpath_t, dir_t, httpfile_t, particle_t, convar_t, delta_t,
#      mip_t, sound_t, byte/word, int16_t, mpg_ssize_t, Opus* fwd decls, window_mode_t &
[removed]
#    - engine/wscript: only add ObjC -fno-lto where the compiler understands LTO (gcc>=4.5
#      or clang); Apple gcc-4.2 rejects it.  -> the same handedits diff
#    - miniutl/minbase_endian.h: map legacy __BIG_ENDIAN__ (Apple's gcc predates
#      __BYTE_ORDER__), or generichash.cpp and bitstring.cpp hit a bare #error.
#      -> scripts/patch-mainui-miniutl-endian.py, run by every driver, this one
#      included (step 1b below). Until #36 it existed only as an untracked edit on the
#      two build minis, so no driver had to ask for it.
#    - mainui ServerBrowser.cpp: replace a C++11 delegating constructor.
[removed]
#    - hlsdk-portable-ppc/wscript: drop GNU '-Wl,--no-undefined' on darwin (Apple ld).
#      -> patches/vendor/hlsdk-portable-ppc.handedits.diff
#    - leopard-sdl2 SDL_cocoamodes.m: don't CFRelease() the array returned by the
#      pre-10.6 CGDisplayAvailableModes() (Get rule, owned by CoreGraphics). The stock
#      over-release corrupted CG's cached mode array, so the first event pump crashed
#      SIGBUS-at-0x1 deep in CGDisplayCurrentMode()/objc_msgSend. This was THE G5 crash.
#      Applied to $SDLSRC below; also saved as patches/leopard-sdl2-cocoamodes-getrule.patch.
#
#  Configure deltas: --sdl-use-pkgconfig --skip-sdl2-sanity-check --disable-werror.
#    NOTE this engine fork has NO --disable-mbedtls (it doesn't bundle mbedTLS the Phase-1
#    way), so the 10.7 clock_gettime TLS blocker doesn't apply here.
#
#  TODO: enable AltiVec (--altivec, needs DEST_CPU=ppc which the xcompile.py patch now sets)
#    as a perf pass once the base build is validated on the G5. Tiger (10.4) is a separate
#    phase - the 10.4u SDK + gcc-4.2 can't find libstdc++ headers (needs gcc-4.0).
set -euo pipefail

# --- toolchain / SDK ---------------------------------------------------------
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # for git etc.
SDK=/Developer/SDKs/MacOSX10.5.sdk
export CC="gcc-4.2" CXX="g++-4.2"
export MACOSX_DEPLOYMENT_TARGET=10.5

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OLDMAC="${OLDMAC:-$HOME/oldmac}"                       # staging root on the mini
[removed]
[removed]
SDLSRC="$OLDMAC/leopard-sdl2"                          # alex-free/leopard-sdl2 checkout
SDLPREFIX="$OLDMAC/sdl2-ppc970"                        # ppc970-subtype leopard-sdl2 static lib
SHIM="$OLDMAC/compat-include"
DP="$OLDMAC/dist/ppc970"; DH="$OLDMAC/dist/ppc-hlsdk970"
APP="$OLDMAC/dist/ppc970-app"                          # build staging: under dist/, never the Desktop
ASSETS="${HL_VALVE:-$HOME/hl-assets/valve}"

# -arch ppc970 (NOT generic -arch ppc): stamps cpusubtype POWERPC_970 so this slice is a
# DEDICATED G5 compartment inside the universal. HW-verified 2026-07-24: the G5 (970) auto-
# selects this ppc970 slice over the shared ppc7400 (tiger) slice, while the G4s (7450) stay
# on ppc7400 and the G3 (750) on generic ppc - so the G5 alone runs leopard-sdl2 2.0.6 (the
# SDL it's proven reliable on) and the G4 keeps panther-sdl2. See leopard-sdl2-cannot-run-on-104.
ARCHFLAGS="-arch ppc970 -isysroot $SDK -mmacosx-version-min=10.5"

# --- 0) compat-include shims -------------------------------------------------
mkdir -p "$SHIM"
printf '#pragma once\n#ifndef __STDC_FORMAT_MACROS\n#define __STDC_FORMAT_MACROS 1\n#endif\n#include <inttypes.h>\n' > "$SHIM/cinttypes"
printf '#pragma once\n#include <stdint.h>\n' > "$SHIM/cstdint"
cat > "$SHIM/oldmac_cxx11.h" <<'EOF'
#pragma once
#ifdef __cplusplus
#include <cstddef>
#ifndef nullptr
#define nullptr NULL
#endif
#ifndef final
#define final
#endif
#ifndef override
#define override
#endif
#ifndef constexpr
#define constexpr
#endif
#endif
EOF

# --- 1) SDL2 (alex-free leopard-sdl2, static ppc, cross mode) ----------------
# THE G5 CRASH FIX: leopard-sdl2's Cocoa_GetDisplayModes over-releases the array
# from the pre-10.6 CGDisplayAvailableModes() (Get rule -> owned by CoreGraphics),
# which later makes CGDisplayCurrentMode() return freed memory and SIGBUS at 0x1 on
# the first event pump. Guard the CFRelease to the 10.6+ (Copy-rule) path only.
# Applied idempotently to the source before building (see patches/ for the diff).
CMODES="$SDLSRC/src/video/cocoa/SDL_cocoamodes.m"
if [ -f "$CMODES" ] && ! grep -q 'oldmac Leopard-PPC fix' "$CMODES"; then
	echo "==> [1a] patching leopard-sdl2 Cocoa_GetDisplayModes over-release"
	perl -0pi -e 's/(\n\s*CVDisplayLinkRelease\(link\);\n)(\s*CFRelease\(modes\);\n)/$1#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060\n        \/* pre-10.6 CGDisplayAvailableModes follows the Get rule; releasing it\n         * over-releases CoreGraphics'"'"'s cached mode array and crashes the next\n         * CGDisplayCurrentMode() on the first event pump. (oldmac Leopard-PPC fix.) *\/\n$2#endif\n/s' "$CMODES"
	grep -q 'oldmac Leopard-PPC fix' "$CMODES" || { echo "SDL2 cocoamodes patch FAILED to apply"; exit 1; }
	# force a rebuild so the fix lands in the .a
	rm -f "$SDLPREFIX/bin/sdl2-config"
fi
if [ ! -x "$SDLPREFIX/bin/sdl2-config" ]; then
	echo "==> [1] cross-building leopard-sdl2 (ppc, static, 10.5)"
	( cd "$SDLSRC" && make distclean >/dev/null 2>&1 || true
	  CC="gcc-4.2 $ARCHFLAGS" CFLAGS="$ARCHFLAGS" LDFLAGS="$ARCHFLAGS" \
	  ./configure --prefix="$SDLPREFIX" --host=powerpc-apple-darwin9 --build=i686-apple-darwin11 \
	              --disable-joystick --disable-haptic --without-x --disable-shared --enable-static
	  make -j"$(sysctl -n hw.ncpu)" && make install )
fi
export PATH="$SDLPREFIX/bin:$PATH"

# --- shared flags ------------------------------------------------------------
export CFLAGS="$ARCHFLAGS -std=gnu99"
export LINKFLAGS="$ARCHFLAGS"
export LDFLAGS="$ARCHFLAGS"

# --- 1b) engine source patches (idempotent) ----------------------------------
# ALL out-of-tree engine fixes are (re)applied here so a fresh checkout of the
# vendor tree builds a correct app. Every script is guarded/idempotent (re-running
# on an already-patched tree just prints "already patched") and endian/platform
# guarded. All but the last (gl-default-texture, PPC-only) are shared with the Intel
# build; build-lion.sh applies the same set minus that one (see there for why):
#  Finder-launch (.app runs with cwd "/"; dyld won't resolve a bare leaf name):
#  - patch-game-launch:    launcher dlopen()s libxash.dylib next to the executable.
#  - patch-lib-posix:      COM_LoadLibrary retries every engine dylib exe-relative.
#  - patch-fs-applebundle: read-only game root -> Contents/Resources/Half-Life/valve.
#  Big-endian byte-swaps the modern renderer never had (ppc is the only BE target):
#  - patch-vid-drawable:   guard a byte-swapped SDL drawable size that dropped the
#      software renderer's fullscreen to the console on the G5 (no-op on Intel).
#  - patch-palette-endian: img_wad.c cleared palette[255]'s alpha with & 0xFFFFFF,
#      which clears RED on big-endian -> fluorescent light-tube centres (fullbright
#      index 255) rendered cyan on the G5. THE light bug. (no-op on Intel.)
#  - patch-soft-screenshot: ref_soft VID_ScreenShot stored the framebuffer with an
#      endian-dependent 32-bit write -> every ppc screenshot came out solid blue.
#  - patch-gl-default-texture-endian: ref_gl painted its "missing texture" fallback
#      with packed-uint constants -> yellow/transparent instead of magenta/black on BE.
echo "==> [1b] apply engine source patches"
python "$ROOT/scripts/patch-game-launch.py"            "$ENGINE/game_launch/game.cpp"
python "$ROOT/scripts/patch-lib-posix.py"              "$ENGINE/engine/platform/posix/lib_posix.c"
python "$ROOT/scripts/patch-fs-applebundle.py"         "$ENGINE/engine/common/filesystem_engine.c"
python "$ROOT/scripts/patch-timerefresh.py"          "$ENGINE"  # demo-free timerefresh benchmark cmd
python "$ROOT/scripts/patch-vid-drawable.py"           "$ENGINE/engine/platform/sdl2/vid_sdl2.c"
python "$ROOT/scripts/patch-palette-endian.py"         "$ENGINE/engine/common/imagelib/img_wad.c"
python "$ROOT/scripts/patch-bmp-palette-alpha.py"      "$ENGINE/engine/common/imagelib/img_bmp.c"  # #44: a BMP palette entry has no alpha byte, and reading one made every palettised BMP transparent
python "$ROOT/scripts/patch-soft-screenshot.py"        "$ENGINE/ref/soft/r_glblit.c"
python "$ROOT/scripts/patch-gl-default-texture-endian.py" "$ENGINE/ref/gl/gl_image.c"
python "$ROOT/scripts/patch-gl-version-query.py"       "$ENGINE/ref/gl/gl_opengl.c"  # #17: don't ask a GL 1.x/2.x context for a GL 3.0 enum
python "$ROOT/scripts/patch-con-font-renderer-switch.py" "$ENGINE"  # #43: the console font kept a texture handle owned by the renderer being unloaded
python "$ROOT/scripts/patch-single-pass-multitexture.py" "$ENGINE"  # single-pass world multitexture (fillrate win, gl_singlepass cvar)
python "$ROOT/scripts/patch-net-local-address.py"      "$ENGINE/engine/common/net_ws.c"  # #34: our own address from the interface list, not a 15s blocking getaddrinfo
python "$ROOT/scripts/patch-net-no-blocking-resolve.py" "$ENGINE"  # #29: connect, ui_queryserver and master shutdown must never block the frame loop on DNS
python "$ROOT/scripts/patch-mainui-console.py"         "$ENGINE/3rdparty/mainui/menus/Main.cpp"  # #3: Console button without -dev 1
python "$ROOT/scripts/patch-gamedll-plain-name.py"     "$ENGINE"  # mods: accept ONE fat dylib at liblist.gam's plain name
python "$ROOT/scripts/patch-cl-gamedir-client.py"      "$ENGINE/engine/client/cl_main.c"  # mods: don't load valve's client dylib
python "$ROOT/scripts/patch-sys-newinstance-fork.py"  "$ENGINE"  # mods: fork before exec so "change game" can restart
python "$ROOT/scripts/patch-mainui-modart.py"          "$ENGINE/3rdparty/mainui"  # mods: artwork + description in Custom Game
python "$ROOT/scripts/patch-mainui-modlist.py"          "$ENGINE/3rdparty/mainui"  # mods: readable Type column + wider Name column
python "$ROOT/scripts/patch-mainui-localize-optional.py" "$ENGINE/3rdparty/mainui"  # #20: an absent optional dictionary is not a fault
python "$ROOT/scripts/patch-mainui-menu-reload-statics.py" "$ENGINE/3rdparty/mainui"  # #35: a Darwin dlclose does not unload the menu, so a reload left the dictionary freed and never rebuilt
python "$ROOT/scripts/patch-mainui-logo-nullcheck.py" "$ENGINE/3rdparty/mainui"  # #26: spray logo spinner crashed on an unloadable BMP
python "$ROOT/scripts/patch-mainui-bmp-endian.py" "$ENGINE/3rdparty/mainui"  # #33: CBMP::LoadFile read the little-endian BMP header raw, so every BMP failed on PowerPC
python "$ROOT/scripts/patch-mainui-picbutton-endian.py" "$ENGINE/3rdparty/mainui"  # #8: draw the btns_main.bmp artwork on PowerPC too, so a mod's own menu lettering shows
python "$ROOT/scripts/patch-mainui-logo-picker.py" "$ENGINE/3rdparty/mainui"  # #33: drop the phantom "lambda" slot, and preview a spray BMP the way it is sprayed
python "$ROOT/scripts/patch-mainui-modsize.py" "$ENGINE/3rdparty/mainui"  # #27: no "0.0 Mb" for mods that omit the optional size field
python "$ROOT/scripts/patch-mainui-name-dialog-escape.py" "$ENGINE/3rdparty/mainui"  # #29: Escape must dismiss the name dialog
python "$ROOT/scripts/patch-mainui-space-metrics.py" "$ENGINE/3rdparty/mainui"  # #27: uninitialised glyph box gave the space a garbage advance width
python "$ROOT/scripts/patch-mainui-miniutl-endian.py" "$ENGINE/3rdparty/mainui"  # #36: miniutl only knows __BYTE_ORDER__ (gcc 4.3+), so Apple's gcc hits a bare #error
python "$ROOT/scripts/patch-startup-diagnostics.py"     "$ENGINE"  # #21: physics interface declined, and AVI, are not failures
python "$ROOT/scripts/patch-crash-libbacktrace.py"      "$ENGINE"  # #21: crash traces on the gcc-4.0 slices, and a pointer-sized buffer length

# --- 2) engine + renderers + menu (needs the C++11 shims) --------------------
echo "==> [2] engine (ppc7400)"
export CXXFLAGS="$ARCHFLAGS -isystem $SHIM -DMY_COMPILER_SUCKS=1 -include $SHIM/oldmac_cxx11.h"
( cd "$ENGINE"
  python waf configure --sdl-use-pkgconfig --skip-sdl2-sanity-check --disable-werror
  python waf build -j"$(sysctl -n hw.ncpu)"
  rm -rf "$DP"; python waf install --destdir="$DP" )

# --- 3) game dylibs (C++03; NO force-include, NO MY_COMPILER_SUCKS) ----------
echo "==> [3] hlsdk game dylibs (ppc7400)"
# Big-endian faults on the director/HLTV path, same fix the 25 mods carry.
python "$ROOT/scripts/patch-hlsdk-shared-clientbugs.py" "$HLSDK"
export CXXFLAGS="$ARCHFLAGS -isystem $SHIM"
( cd "$HLSDK"
  python waf configure --disable-werror
  python waf build -j"$(sysctl -n hw.ncpu)"
  rm -rf "$DH"; python waf install --destdir="$DH" )

# --- 4) assemble self-contained ~/Desktop/Half-Life-PPC ----------------------
echo "==> [4] assemble $APP"
rm -rf "$APP"; mkdir -p "$APP/valve/cl_dlls" "$APP/valve/dlls"
cp "$DP"/xash3d "$DP"/*.dylib "$APP/"
cp -R "$ASSETS"/. "$APP/valve/"
cp "$DP/valve/extras.pk3" "$APP/valve/" 2>/dev/null || true
cp "$DH"/valve/cl_dlls/*.dylib "$APP/valve/cl_dlls/"
cp "$DH"/valve/dlls/*.dylib    "$APP/valve/dlls/"

echo "==> done. ppc build at $APP"
echo "    Arch check: file '$APP'/xash3d   (expect Mach-O ... ppc)"
echo "    Bench on the iMac G5 - WINDOWED ONLY (fullscreen mode-switch hard-hangs Leopard)."
