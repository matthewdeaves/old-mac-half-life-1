#!/bin/bash
# Phase 3b - PowerPC Half-Life (Xash3D FWGS) for Mac OS X 10.3 Panther (G3).
# RUN THIS ON AN INTEL LION MINI - either mini-intel or mini-intel2 (identical
# Macmini2,1 / 10.7.5 / same toolchain). CROSS-compiles the PPC slice on Intel.
# It runs LOCALLY on that box and does no ssh of its own, so pick-build-host.sh
# does not apply here - run `scripts/pick-build-host.sh --status` to see which
# mini is free, then log in there and run this.
# Targets the G3 "yosemite" (Power Mac G3, ppc750, 10.3.9). The 750 has NO AltiVec, so
# this build is generic -arch ppc with AltiVec DISABLED (a plain ppc slice that also loads
# on any G4/G5). The G4 Tiger build (build-ppc-tiger.sh) keeps AltiVec/ppc7400.
#
# DELTA vs build-ppc-tiger.sh (the 10.4 Tiger build) - otherwise identical:
#   SDK       10.4u          -> 10.3.9        (oldest SDK on the box; a Panther G3 has these frameworks)
#   min-OS    10.4           -> 10.3          (so dyld doesn't gate it off Panther)
#   AltiVec   on (ppc7400)   -> off: ARCHFLAGS omit -faltivec, since the ppc750 G3 has no
#                              AltiVec unit and those instructions would SIGILL on it.
#                              This drops the engine's 465 -maltivec compiles and yields a generic
#                              'ppc' subtype that the kernel will actually load on a 750.
#   SDL       min-10.4       -> min-10.3      (panther-sdl2 rebuilt for 10.3. The 10.3.9 SDK has no
#                                             NSApplicationSupportDirectory, a 10.4 enum, and the
#                                             cross-SDK version guards and the 10.4-only display
#                                             name lookup bite here too. All of that is carried on
#                                             our own panther-sdl2 branch.)
#   waf out   build-tiger    -> build-panther (keep Tiger/Leopard artifacts intact)
#   prefixes  *-tiger        -> *-panther
#   compiler  gcc-4.0/g++-4.0 (unchanged: the 10.3.9 /usr/include stubs #include_next gcc-4.0's
#                              builtins, same as 10.4u; libbacktrace bswap fallback still applies).
#
# WHERE THE SOURCE COMES FROM
# Every fix this port makes is a commit on the `oldmac` branch of our own fork of
# the relevant upstream: the engine (with the menu, miniutl and libbacktrace as its
# submodules), the game dylibs, and SDL. scripts/build-pins.sh names the exact
# commit for each, scripts/fetch-sources.sh checks them out, and this script
# compiles what it finds. Nothing rewrites a source file on the way past.
set -euo pipefail

# --- toolchain / SDK ---------------------------------------------------------
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # for git etc.
# oldmac: overridable so a host without /Developer/SDKs can build. imac-2019
# is macOS 15 with a sealed system volume, where that path can never exist;
# its real SDKs live at ~/SDKs/*.sdk. Default unchanged, so the Lion minis
# behave exactly as before. Issue #22.
SDK="${OLDMAC_PPC_SDK:-/Developer/SDKs/MacOSX10.3.9.sdk}"
# oldmac: overridable for the same reason. GCC14 satisfies every requirement
# these scripts state (unwind.h, __builtin_bswap32/64, AltiVec, the 10.3.9
# header chain), which also collapses the gcc-4.2/g++-4.0 split. Default
# unchanged. Issue #22.
export CC="${OLDMAC_PPC_CC:-gcc-4.0}" CXX="${OLDMAC_PPC_CXX:-g++-4.0}"
# oldmac: the SDL stage can need a DIFFERENT compiler from the engine stage,
# and cannot be told to use two at once. panther-sdl2 is C plus 28 Objective-C
# sources (src/video/cocoa/*.m and friends), and its generated Makefile.rules
# compiles BOTH with a single $(CC): there is no OBJCC in SDL 2.0.3 at all, so
# a per-file split is not available. The engine stage is the mirror image, C
# and C++ with no Objective-C.
#
# On the Lion minis one compiler covers everything and this default keeps their
# behaviour byte-identical. It exists for imac-2019, where the GCC14 cross
# toolchains are built per-language: ~/gcc14-ppc is c,c++ and cannot compile a
# .m, ~/gcc14-ppc-objc is c,objc and cannot compile a .cpp. So SDL takes the
# objc one, the engine takes the c++ one, and their objects link together.
# Issue #22, old-mac-build-host#50.
export SDL_CC="${OLDMAC_PPC_SDL_CC:-$CC}" SDL_CXX="${OLDMAC_PPC_SDL_CXX:-$CXX}"
# oldmac: extra CFLAGS for the SDL stage only, default EMPTY so the Lion minis
# compile exactly as before. This is for demoting diagnostics that a compiler
# newer than the vendor code promoted to errors, and every entry needs its own
# justification, because the alternative to each is a vendor patch we will not
# write and the lazy option is to blanket-disable and stop reading.
#
# What it is for today, on GCC14: SDL_render_gl.c:486 passes a GLint* where
# SDL_GL_GetAttribute wants an int*. GCC14 made -Wincompatible-pointer-types an
# error by default; gcc-4.0 warned. Passing
# -Wno-error=incompatible-pointer-types puts it back to a warning, which keeps
# it VISIBLE rather than silencing it.
#
# That is safe here for one reason and it is worth stating: this slice is
# 32-bit PowerPC, where int and long are both 32 bits, so the two pointers
# agree on size, alignment and representation. The same code on a 64-bit target
# would be a real defect and must not be waved through. Nothing else is demoted
# by default: implicit-function-declaration in particular is left as an error,
# because it can silently produce a wrong call. Issue #22.
export SDL_EXTRA_CFLAGS="${OLDMAC_PPC_SDL_EXTRA_CFLAGS:-}"
# oldmac: waf is invoked through this. Default `python` keeps the Lion minis
# identical, where python is 2.7 and present. macOS 15 ships no `python` at all,
# only `python3`, so the engine stage there died with "python: command not
# found" AFTER SDL had built clean, which reads like a broken driver and is a
# missing binary. Issue #22.
export PYTHON="${OLDMAC_PPC_PYTHON:-python}"
export MACOSX_DEPLOYMENT_TARGET=10.3

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OLDMAC="${OLDMAC:-$HOME/oldmac}"
# Overridable so the same recipe can be pointed at a different engine tree
# without duplicating 200 lines of toolchain setup. An override skips the pin
# check below, because by definition it is not the pinned tree.
ENGINE="${ENGINE_OVERRIDE:-$OLDMAC/vendor/xash3d-fwgs}"
HLSDK="$OLDMAC/vendor/hlsdk-portable"
SDLSRC="$OLDMAC/vendor/panther-sdl2"                   # our branch of panther-sdl2 (SDL 2.0.3)
SDLPREFIX="$OLDMAC/sdl2-ppc-panther"
SHIM="$OLDMAC/compat-include"
# All build output goes under dist/, which is the one .gitignore'd directory. It
# used to be a fan of dist-ppc-* siblings at the repo root: untracked to git (only
# `dist/` is ignored), and one keystroke away from the Desktop. Nothing here is
# ever the deployed game.
DP="$OLDMAC/dist/ppc-panther"; DH="$OLDMAC/dist/ppc-hlsdk-panther"
APP="$OLDMAC/dist/ppc-panther-app"
ASSETS="${HL_VALVE:-$HOME/hl-assets/valve}"
WAFOUT=build-panther

# -arch ppc with no -faltivec yields a generic ppc(ALL) slice (waf adds no -mcpu bump,
# which is what stamps ppc7400 on the AltiVec Tiger build). We KEEP that here for a clean
# build, then re-stamp the finished EXECUTABLE's cpusubtype to POWERPC_750 (9) in step 4 so a
# 750 host finds an EXACT match. Why: Panther's lax 2003 dyld accepts a ppc(ALL) slice, but
# Tiger/Leopard's kernel MIS-GRADES a fat of [ppc ALL, ppc7400, ppc970] on a 750 host and
# refuses to exec it (proven on the G3-Tiger: the thinned ppc slice runs; the ALL-in-fat does
# not; a ppc750-stamped fat does). Only the exec needs the exact subtype - the engine dylibs
# stay ALL and dlopen grades them fine on a 750 host (also proven).
# perf-ppc: -fno-math-errno drops errno bookkeeping around libm calls, none of
# the value-changing parts of -ffast-math. The SAME literal flag is in
# build-ppc-tiger.sh's ARCHFLAGS and build-mod.sh's build_ppc archflags; the
# three cannot share a variable because this line runs before build-pins.sh is
# sourced, so a change here must be made in all three places.
#
# TUNE750 (-mtune=750) is applied to the ENGINE and SDL steps only, NOT hlsdk:
# the ppc750-stamped executable and this build's generic-ppc engine dylib
# slices are only ever selected on a G3 (a G4/G5 grades the ppc7400 slice
# higher), but make-universal.sh ships THIS build's hlsdk game dylib pair as
# the single generic-ppc pair for G3, G4 and G5 alike, so the game code must
# stay untuned.
ARCHFLAGS="-arch ppc -fno-math-errno -isysroot $SDK -mmacosx-version-min=10.3"
TUNE750="-mtune=750"

# DBG=1 -> build with DWARF debug symbols (-g) so the engine's libbacktrace crash
# handler can symbolize frames (otherwise it prints "no debug info in Mach-O").
# Diagnostic only; leave off for release builds. Applies to engine + game dylibs.
if [ "${DBG:-0}" = "1" ]; then ARCHFLAGS="$ARCHFLAGS -g"; echo "==> DBG=1: building with -g debug symbols"; fi

# 10.3.9-SDK include gaps the cross driver doesn't fill (present/auto-added on the 10.4u SDK):
#  * unwind.h (used by 3rdparty/libbacktrace/simple.c) isn't in ANY SDK -- it's a gcc-4.0
#    compiler header; add gcc-4.0's own include dir so it's found.
#  * the 10.3.9 SDK's libstdc++ target subdir is powerpc-apple-darwin7 (Panther's kernel), which
#    the darwin10-hosted g++ doesn't probe, so <cmath> can't find bits/c++config.h. Add it.
# oldmac: overridable. This is the COMPILER's own include dir, not an SDK's,
# and the default path is Lion-specific. GCC14 on another host keeps its
# unwind.h somewhere else entirely. Issue #22.
GCCINC="${OLDMAC_PPC_GCCINC:-/usr/lib/gcc/powerpc-apple-darwin10/4.0.1/include}"
CXXINC="-isystem $SDK/usr/include/c++/4.0.0/powerpc-apple-darwin7"

# --- pre-flight: every tree must be at the commit build-pins.sh names ---------
# The port is not applied at build time any more, so a tree at the wrong commit
# silently builds the wrong code and every check in build-verification.md still
# passes, because those all look at the OUTPUT. Refuse to start instead.
. "$ROOT/scripts/build-pins.sh"

# fetch-sources.sh prefers a modern git under ~/local where one exists, because
# Lion's own git is Xcode 4's 1.7. Read the trees back with the same one.
PINGIT=git
for cand in "$HOME/local/bin/git" /usr/local/bin/git /opt/homebrew/bin/git; do
	[ -x "$cand" ] && { PINGIT="$cand"; break; }
done

# check_pin <label> <directory> <expected-commit>. git 1.7 has no `git -C`.
check_pin() {
	local have=""
	if [ ! -d "$2/.git" ]; then
		echo "!! $1: no source tree at $2" >&2
		echo "   run: scripts/fetch-sources.sh" >&2
		exit 1
	fi
	have="$( cd "$2" && "$PINGIT" rev-parse HEAD 2>/dev/null || true )"
	if [ "$have" != "$3" ]; then
		echo "!! $1: $2" >&2
		echo "   is at $have" >&2
		echo "   want  $3   (scripts/build-pins.sh)" >&2
		echo "   run: scripts/fetch-sources.sh" >&2
		exit 1
	fi
	echo "    ok  $1 $(short "$3")"
}

# check_sub <label> <directory> <expected-commit>. The menu, miniutl and
# libbacktrace are submodules of the engine, and a superproject can record the
# wrong commit for one while .gitmodules names the right fork. That happened, and
# it silently built unported source, so check the commit rather than trusting that
# `git submodule update` ran.
check_sub() {
	local have=""
	if [ ! -e "$2/.git" ]; then
		echo "!! $1: submodule missing at $2" >&2
		echo "   run: scripts/fetch-sources.sh" >&2
		exit 1
	fi
	have="$( cd "$2" && "$PINGIT" rev-parse HEAD 2>/dev/null || true )"
	if [ "$have" != "$3" ]; then
		echo "!! $1: $2" >&2
		echo "   is at $have" >&2
		echo "   want  $3   (scripts/build-pins.sh)" >&2
		echo "   run: scripts/fetch-sources.sh" >&2
		exit 1
	fi
	echo "    ok  $1 $(short "$3")"
}

echo "==> pre-flight: source trees at their pins"
if [ -n "${ENGINE_OVERRIDE:-}" ]; then
	echo "    ENGINE_OVERRIDE set, pin check skipped for: $ENGINE"
else
	check_pin engine "$ENGINE" "$PIN_ENGINE_COMMIT"
fi
check_sub menu         "$ENGINE/3rdparty/mainui"                    "$PIN_MENU_COMMIT"
check_sub miniutl      "$ENGINE/3rdparty/mainui/miniutl"            "$PIN_MINIUTL_COMMIT"
check_sub libbacktrace "$ENGINE/3rdparty/libbacktrace/libbacktrace" "$PIN_LIBBACKTRACE_COMMIT"
check_pin hlsdk "$HLSDK"  "$PIN_HLSDK_COMMIT"
check_pin sdl   "$SDLSRC" "$PIN_SDL_COMMIT"

# --- 0) compat-include shims ------------------------------------------------
# cinttypes and cstdint are TRACKED files, shipped by sync-build-host.sh and
# shared with build-lion.sh and build-mod.sh. This script used to regenerate
# them, which is the two-owners-one-path fault build-mod.sh already documents:
# the generated copy silently replaced the tracked, commented one and the next
# sync put it back. Check they arrived instead. Anything generated below stays
# generated, with this heredoc as its one owner.
mkdir -p "$SHIM"
for shim in cinttypes cstdint; do
	[ -f "$SHIM/$shim" ] || {
		echo "!! missing $SHIM/$shim" >&2
		echo "   compat-include/ is tracked in the repo. Run" >&2
		echo "     scripts/sync-build-host.sh HOST   (this box's ssh alias)" >&2
		echo "   from the workstation, or this build has no <$shim> at all." >&2
		exit 1
	}
done
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

# --- 1) SDL2 (panther-sdl2 2.0.3, static ppc, cross mode, min-10.3) ----------
# The SDL fixes this slice needs are commits on our panther-sdl2 branch, so the
# tree scripts/fetch-sources.sh checked out is already ported.
# The prefix records which panther-sdl2 commit built it. Without that, the
# sdl2-config existence gate cannot tell a bumped pin from a built one: the
# SOURCE tree is pin-checked above, but nothing tied the installed prefix to
# it, so a pin bump would ship the previous pin's SDL silently.
# The marker includes the flags as well as the pin: a flag change must rebuild
# the cached static lib exactly like a pin bump, or two minis with identical
# pins can ship different SDL codegen depending on when each last wiped its
# prefix (found in review of the perf-ppc flag change).
SDL_BUILT_FROM="$PIN_SDL_COMMIT $ARCHFLAGS $TUNE750"
if [ ! -x "$SDLPREFIX/bin/sdl2-config" ] || \
   [ "$(cat "$SDLPREFIX/.built-from" 2>/dev/null)" != "$SDL_BUILT_FROM" ]; then
	echo "==> [1] cross-building panther-sdl2 (ppc, static, 10.3)"
	rm -rf "$SDLPREFIX"
	( cd "$SDLSRC" && make distclean >/dev/null 2>&1 || true
	  # --disable-altivec: SDL 2.0.3 otherwise compiles AltiVec blitters (calc_swizzle32 etc.).
	  # They're runtime-guarded by SDL_HasAltiVec(), but the G3 ppc750 has NO AltiVec, so build
	  # them out entirely -> the whole static lib (and thus libxash) is guaranteed SIGILL-free.
	  # --enable-joystick since 2026-08-21, via our panther-sdl2 fork's
	  # SDL_sysjoystick_legacy.c. SDL2's own macOS joystick backend targets
	  # IOHIDManager, whose headers first ship in the 10.5 SDK, so it cannot build
	  # here at all; the legacy backend uses the older IOCFPlugIn API that 10.3.9
	  # does have. Full mechanism and the measured A/B are in the same block of
	  # build-ppc-tiger.sh. --disable-haptic stays. Issue #2.
	  # CPP/CXXCPP pinned to the chosen compiler. Without them autoconf probes
	  # for a preprocessor and falls back to /lib/cpp, which on a modern host is
	  # not a PowerPC preprocessor at all: "C++ preprocessor /lib/cpp fails
	  # sanity check". Harmless on Lion, where the fallback happened to work.
	  #
	  # They carry ARCHFLAGS for the same reason CC and CXX do, and leaving it
	  # off cost an afternoon. -isysroot lives in ARCHFLAGS, and without it the
	  # preprocessor cannot reach the SDK's headers: gcc's own limits.h does an
	  # #include_next and dies with "limits.h: No such file or directory" at
	  # its line 210, which reads like a broken toolchain and is not. On Lion it
	  # passed anyway, because that host has a real /usr/include to fall into.
	  # On imac-2019 the system volume is sealed and there is nothing to fall
	  # into, so the same command fails. Measured both ways on the box, issue
	  # #22: identical g++ invocation, -isysroot the only difference, fatal
	  # without and clean with.
	  CC="$SDL_CC $ARCHFLAGS $TUNE750" CXX="$SDL_CXX $ARCHFLAGS $TUNE750" \
	  CPP="$SDL_CC $ARCHFLAGS $TUNE750 -E" CXXCPP="$SDL_CXX $ARCHFLAGS $TUNE750 -E" \
	  CFLAGS="$ARCHFLAGS $TUNE750 $SDL_EXTRA_CFLAGS" LDFLAGS="$ARCHFLAGS $TUNE750" \
	  ./configure --prefix="$SDLPREFIX" --host=powerpc-apple-darwin8 --build=i686-apple-darwin11 \
	              --enable-joystick --disable-haptic --without-x --disable-shared --enable-static \
	              --disable-altivec
	  make -j"$(sysctl -n hw.ncpu)" && make install )
	printf '%s\n' "$SDL_BUILT_FROM" > "$SDLPREFIX/.built-from"
fi
export PATH="$SDLPREFIX/bin:$PATH"

# --- shared flags ------------------------------------------------------------
export CFLAGS="$ARCHFLAGS $TUNE750 -std=gnu99 -isystem $GCCINC"
export LINKFLAGS="$ARCHFLAGS $TUNE750"
export LDFLAGS="$ARCHFLAGS $TUNE750"

# The engine, menu, miniutl and libbacktrace fixes are commits on our own branch
# of each of those upstreams, so the trees scripts/fetch-sources.sh checked out
# are already ported and go straight to the compiler.

# --- 2) engine + renderers + menu (AltiVec OFF for the G3 ppc750) ------------
echo "==> [2] engine (generic ppc / Panther, no AltiVec)"
export CXXFLAGS="$ARCHFLAGS $TUNE750 -isystem $SHIM -isystem $GCCINC $CXXINC -DMY_COMPILER_SUCKS=1 -include $SHIM/oldmac_cxx11.h"
( cd "$ENGINE"
  # --disable-rpath: the min-10.3 linker rejects -rpath ("requires 10.5 or later"), and our .app
  # doesn't need it anyway -- the launcher uses dlopen + DYLD_LIBRARY_PATH (make-app.sh), not rpath.
  # Always from scratch. waf decides for itself whether a task needs redoing,
  # and on 31 July 2026 it decided wrong: the tree was at a new commit, the
  # link ran, the output carried a fresh timestamp, and the object for
  # filesystem_engine.c was the previous commit's. Both PowerPC slices shipped
  # code that was not in the source tree, and every freshness check passed
  # because they all look at mtimes. Deleting the out directory costs a few
  # minutes and removes the entire question.
  # OLDMAC_KEEP_BUILD=1 skips this for a fix-compile-fix loop, where a clean
  # build per attempt is minutes of waiting per error. It is NOT for releases,
  # and it cannot become one by accident: the stamp below records that it was
  # used and make-universal.sh refuses to fuse a slice carrying that mark.
  if [ "${OLDMAC_KEEP_BUILD:-0}" = "1" ]; then
  	echo "    !! OLDMAC_KEEP_BUILD=1: reusing objects, this build is not shippable"
  else
  	rm -rf "$WAFOUT"
  fi
  # No --disable-altivec here. Mainline FWGS has no such option: AltiVec is
  # decided entirely by the compiler flags, and ARCHFLAGS for this slice omit
  # -faltivec precisely so the ppc750 G3, which has no AltiVec unit, does not
  # get instructions that would SIGILL. Passing it made waf print its usage and
  # exit. SDL keeps its own --disable-altivec above: that is SDL's option, and
  # SDL 2.0.3 really does compile AltiVec blitters without it.
  "$PYTHON" waf --out="$WAFOUT" configure --sdl-use-pkgconfig --skip-sdl2-sanity-check --disable-werror --disable-rpath
  "$PYTHON" waf --out="$WAFOUT" build -j"$(sysctl -n hw.ncpu)"
  rm -rf "$DP"; "$PYTHON" waf --out="$WAFOUT" install --destdir="$DP" )

# waf can print "The configuration failed" or "Build failed" and still leave this
# script running, which is how a broken PowerPC configure reached the fuse step on
# 31 July 2026. Do not take its word for anything: look for the artifacts.
for f in xash3d libxash.dylib libref_gl.dylib libref_soft.dylib libmenu.dylib filesystem_stdio.dylib; do
	if [ ! -f "$DP/$f" ]; then
		echo "!! engine build produced no $DP/$f" >&2
		echo "   waf may have exited 0 on a failed task. Read the log above and" >&2
		echo "   $ENGINE/$WAFOUT/config.log before trusting anything downstream." >&2
		exit 1
	fi
done

# --- 3) game dylibs (C++03; NO force-include, NO MY_COMPILER_SUCKS) ----------
echo "==> [3] hlsdk game dylibs (generic ppc / Panther)"
# The waf cross-compile fix and the big-endian shared-client fixes are commits on
# our own hlsdk-portable branch, checked out by scripts/fetch-sources.sh.
# No TUNE750 here, and CFLAGS/LDFLAGS drop it again: this hlsdk pair ships as
# the one generic-ppc game dylib pair for every PowerPC machine (see the
# ARCHFLAGS note). -fno-math-errno stays; it changes no values.
export CFLAGS="$ARCHFLAGS -std=gnu99 -isystem $GCCINC"
export LINKFLAGS="$ARCHFLAGS"
export LDFLAGS="$ARCHFLAGS"
export CXXFLAGS="$ARCHFLAGS -isystem $SHIM -isystem $GCCINC $CXXINC"
( cd "$HLSDK"
  # Always from scratch. waf decides for itself whether a task needs redoing,
  # and on 31 July 2026 it decided wrong: the tree was at a new commit, the
  # link ran, the output carried a fresh timestamp, and the object for
  # filesystem_engine.c was the previous commit's. Both PowerPC slices shipped
  # code that was not in the source tree, and every freshness check passed
  # because they all look at mtimes. Deleting the out directory costs a few
  # minutes and removes the entire question.
  # OLDMAC_KEEP_BUILD=1 skips this for a fix-compile-fix loop, where a clean
  # build per attempt is minutes of waiting per error. It is NOT for releases,
  # and it cannot become one by accident: the stamp below records that it was
  # used and make-universal.sh refuses to fuse a slice carrying that mark.
  if [ "${OLDMAC_KEEP_BUILD:-0}" = "1" ]; then
  	echo "    !! OLDMAC_KEEP_BUILD=1: reusing objects, this build is not shippable"
  else
  	rm -rf "$WAFOUT"
  fi
  "$PYTHON" waf --out="$WAFOUT" configure --disable-werror
  "$PYTHON" waf --out="$WAFOUT" build -j"$(sysctl -n hw.ncpu)"
  rm -rf "$DH"; "$PYTHON" waf --out="$WAFOUT" install --destdir="$DH" )

# --- 4) assemble self-contained Panther app ----------------------------------
echo "==> [4] assemble $APP"
rm -rf "$APP"; mkdir -p "$APP/valve/cl_dlls" "$APP/valve/dlls"
cp "$DP"/xash3d "$DP"/*.dylib "$APP/"
# Re-stamp the EXECUTABLE's Mach-O cpusubtype ALL(0) -> POWERPC_750(9) so a 750 host finds an
# exact slice in the universal fat (see the ARCHFLAGS note). Thin 32-bit Mach-O: cpusubtype is
# the 4-byte big-endian field at offset 8; write 00 00 00 09. Idempotent. Dylibs stay ALL.
printf '\000\000\000\011' | dd of="$APP/xash3d" bs=1 seek=8 count=4 conv=notrunc 2>/dev/null
echo "    re-stamped $APP/xash3d -> $(lipo -info "$APP/xash3d" | sed 's/.*: //')"
cp -R "$ASSETS"/. "$APP/valve/"
cp "$DP/valve/extras.pk3" "$APP/valve/" 2>/dev/null || true
cp "$DH"/valve/cl_dlls/*.dylib "$APP/valve/cl_dlls/"
cp "$DH"/valve/dlls/*.dylib    "$APP/valve/dlls/"

# --- build stamp -------------------------------------------------------------
# Record what this slice was actually built from. make-universal.sh refuses to
# fuse slices whose stamps disagree with each other or with build-pins.sh, so a
# directory left behind by an earlier run cannot be quietly folded into a release.
if [ "${OLDMAC_KEEP_BUILD:-0}" = "1" ]; then
	printf '%s\n' "not-shippable-OLDMAC_KEEP_BUILD" > "$APP/BUILD-STAMP"
else
	# MEASURED, not copied from the pin. Writing $PIN_ENGINE_COMMIT made the stamp a
	# restatement of what we asked for rather than a record of what was built, so it
	# could not notice a tree moved after the pre-flight, and under ENGINE_OVERRIDE
	# it asserted a pin that was never checked. make-universal.sh compares stamps
	# against build-pins.sh, so the stamp has to be evidence to be worth anything.
	if [ -n "${ENGINE_OVERRIDE:-}" ]; then
		printf '%s\n' "not-shippable-ENGINE_OVERRIDE" > "$APP/BUILD-STAMP"
	else
		printf '%s\n' "$( cd "$ENGINE" && git rev-parse HEAD )" > "$APP/BUILD-STAMP"
	fi
fi

echo "==> done. Panther ppc build at $APP"
echo "    Arch check: lipo -info '$APP'/xash3d   (expect ppc750 - exact subtype 9, NOT generic ppc/ALL)"
echo "    Target: Power Mac G3 (ppc750) on 10.3/10.4/10.5 - must be ppc750, NOT ppc(ALL) or ppc7400."
