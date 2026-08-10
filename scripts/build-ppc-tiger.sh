#!/bin/bash
# Phase 3a - PowerPC Half-Life (Xash3D FWGS) for Mac OS X 10.4 Tiger (G4).
# RUN THIS ON AN INTEL LION MINI - either mini-intel or mini-intel2 (identical
# Macmini2,1 / 10.7.5 / same toolchain). CROSS-compiles the PPC slice on Intel.
# It runs LOCALLY on that box and does no ssh of its own, so pick-build-host.sh
# does not apply here - run `scripts/pick-build-host.sh --status` to see which
# mini is free, then log in there and run this.
# Targets every AltiVec PowerPC Mac: the Quicksilver (PowerMac3,5 / 7450, 10.4.11),
# the Mac mini G4 (PowerMac10,1 / 7450, 10.4.11) and, since v1.4.0, the iMac G5
# (970, 10.5.8). A ppc7400 subtype slice is fine on all three; the G3/Panther build
# is a separate, generic-ppc script.
#
# DELTA vs the retired 10.5 Leopard build - everything else is identical:
#   SDK       10.5           -> 10.4u        (frameworks/headers a Tiger box actually has)
#   min-OS    10.5           -> 10.4         (so dyld doesn't gate it off Tiger)
#   compiler  gcc/g++-4.2    -> CC gcc-4.2 / CXX g++-4.0  (split toolchain, the Tiger crux):
#     * C++  MUST be g++-4.0: the 10.4u SDK ships the 4.0 libstdc++, and g++-4.2 -isysroot 10.4u
#            can't find its C++ headers; the retired driver flagged exactly this.
#     * C    MUST stay gcc-4.2: the engine's bundled 3rdparty/libbacktrace (always linked) uses
#            __builtin_bswap32/64, which only became compiler builtins in gcc-4.3. Apple's gcc-4.2
#            backported them; gcc-4.0 has NOT, so a 4.0 C build fails to link libxash with
#            "Undefined symbols: ___builtin_bswap32". gcc-4.2 compiles C fine against the 10.4u SDK.
#     Mixing is safe: C and C++ share the ppc-darwin C ABI; only C++ pulls libstdc++.
#     C99/C++98 shims carry over unchanged.
#   SDL       min-10.5       -> min-10.4     (our panther-sdl2 branch, SDL 2.0.3, targets 10.3/10.4).
#     NOTE: leopard-sdl2 (2.0.6) is IMPOSSIBLE here - this ppc7400 slice runs on BOTH the G4
#     (10.4) and the G5 (10.5), and 2.0.6 links 10.5-only AudioQueue/TIS/objc-fast-enumeration
#     that don't exist on 10.4 (proven: the engine link fails "Undefined symbols" on the 10.4u
#     SDK). panther-sdl2's older AudioUnit/KeyboardLayout paths are the only SDL that runs on
#     10.4. Since v1.4.0 the G5 loads THIS slice too: the ppc970/leopard-sdl2 slice was
#     dropped (6% slower on the G5, and it locked a G5 out of 10.3/10.4). See
#     docs/adr/0001-slices-are-chosen-by-cpu-capability.md.
#   waf out   build/         -> build-tiger/ (keep the known-good Leopard artifacts intact)
#   prefixes  *-ppc          -> *-ppc-tiger  (parallel staging; nothing clobbers Leopard)
#
# WHERE THE SOURCE COMES FROM
# Every fix this port makes is a commit on the `oldmac` branch of our own fork of
# the relevant upstream: the engine (with the menu, miniutl and libbacktrace as its
# submodules), the game dylibs, and SDL. scripts/build-pins.sh names the exact
# commit for each, scripts/fetch-sources.sh checks them out, and this script
# compiles what it finds. Nothing rewrites a source file on the way past. The
# toolchain shims that are NOT source fixes (the compat-include headers and the
# C++11 force-include below) stay here, because they belong to this SDK, not to
# the engine.
set -euo pipefail

# --- toolchain / SDK ---------------------------------------------------------
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # for git etc.
SDK=/Developer/SDKs/MacOSX10.3.9.sdk   # #6: build min-10.3 so a G4 booted on Panther can load this slice (was 10.4u/min-10.4)
export CC="gcc-4.0" CXX="g++-4.0"   # 10.3.9 SDK's /usr/include stubs #include_next gcc-4.0's builtins (same pairing as panther)
export MACOSX_DEPLOYMENT_TARGET=10.3

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OLDMAC="${OLDMAC:-$HOME/oldmac}"                       # staging root on the mini
# ENGINE stays overridable so this recipe can be pointed at another engine tree
# without duplicating the toolchain setup. An override skips the pin check below,
# because by definition it is not the pinned tree.
ENGINE="${ENGINE_OVERRIDE:-$OLDMAC/vendor/xash3d-fwgs}"   # our branch of FWGS/xash3d-fwgs
HLSDK="$OLDMAC/vendor/hlsdk-portable"                 # our branch of FWGS/hlsdk-portable
# Tiger/Panther can't build leopard-sdl2 (2.0.6 needs the 10.5 SDK: NSInteger/CGFloat/
# NSHUDWindowMask) AND 2.0.6 links 10.5-only runtime symbols absent on 10.4 (see the SDL
# note up top). Use panther-sdl2 (SDL 2.0.3), which targets 10.3/10.4, and whose
# cross-SDK version-guard fixes are commits on our branch of it.
SDLSRC="$OLDMAC/vendor/panther-sdl2"                   # our branch of panther-sdl2 (SDL 2.0.3)
SDLPREFIX="$OLDMAC/sdl2-ppc-tiger103"   # #6: rebuilt against 10.3.9 SDK, AltiVec ON (separate from the old 10.4 prefix)
SHIM="$OLDMAC/compat-include"
# All build output goes under dist/ (the one .gitignore'd directory), never at the
# repo root and never on the Desktop. See build-ppc-panther.sh for the reasoning.
DP="$OLDMAC/dist/ppc-tiger"; DH="$OLDMAC/dist/ppc-hlsdk-tiger"
APP="$OLDMAC/dist/ppc-tiger-app"                      # Tiger build staging
ASSETS="${HL_VALVE:-$HOME/hl-assets/valve}"
WAFOUT=build-tiger                                     # separate waf out dir per target

# 10.3.9-SDK include gaps (identical to build-ppc-panther.sh): gcc-4.0's own unwind.h for
# 3rdparty/libbacktrace, and the 10.3.9 SDK's libstdc++ target subdir (powerpc-apple-darwin7).
GCCINC=/usr/lib/gcc/powerpc-apple-darwin10/4.0.1/include
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

# -arch ppc -mcpu=7400 -faltivec  (the G4 AltiVec slice, min-10.3):
#  -mcpu=7400  : schedule for the 7400 + enable AltiVec codegen (waf also adds -maltivec per-file,
#                giving real AltiVec instructions - verified). NOTE it does NOT stamp the Mach-O
#                cpusubtype: the linker stamps from -arch, so the linked slice comes out generic
#                ppc(ALL) even with -mcpu=7400/-maltivec. Step 4 RE-STAMPS exec+dylibs to
#                POWERPC_7400 (an exact subtype like ppc750/ppc970) - a generic ALL slice is
#                mis-graded by the Tiger/Leopard kernel and collides with panther's ALL engine
#                dylibs in make-universal's lipo -create.
#  -faltivec   : enable Apple's context-sensitive `vector` keyword, REQUIRED so the 10.3.9 SDK's
#                MachineExceptions.h (AltiVec `vector` field, pulled via Carbon in menu_darwin.m)
#                parses; std::vector in mainui still parses. (Panther dodges this with
#                --disable-altivec; the G5 uses the 10.5 SDK.)
#  min-10.3 lets a Panther G4 load it; it runs forward on 10.4/10.5.
ARCHFLAGS="-arch ppc -mcpu=7400 -faltivec -isysroot $SDK -mmacosx-version-min=10.3"

# --- 0) compat-include shims ------------------------------------------------
# cinttypes and cstdint are TRACKED files, shipped by sync-build-host.sh and
# shared with build-lion.sh and build-mod.sh. This script used to regenerate
# them, which is the two-owners-one-path fault build-mod.sh already documents:
# the generated copy silently replaced the tracked, commented one and the next
# sync put it back. Check they arrived instead. oldmac_cxx11.h below is NOT
# tracked and this heredoc stays its one owner.
mkdir -p "$SHIM"
for shim in cinttypes cstdint; do
	[ -f "$SHIM/$shim" ] || {
		echo "!! missing $SHIM/$shim" >&2
		echo "   compat-include/ is tracked in the repo. Run" >&2
		echo "     scripts/sync-build-host.sh $(hostname -s)" >&2
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

# --- 1) SDL2 (panther-sdl2 2.0.3, static ppc, cross mode, min-10.4) ----------
# panther-sdl2 gates its 10.5-era code with `#if [!]defined(MAC_OS_X_VERSION_10_5)`, a
# test written for a *native* Panther/Tiger compiler, and our Lion cross-SDK DOES define
# that macro. That fix, and the rest this slice needs, are commits on our panther-sdl2
# branch, so the tree scripts/fetch-sources.sh checked out is already ported.
# The prefix records which panther-sdl2 commit built it. Without that, the
# sdl2-config existence gate cannot tell a bumped pin from a built one: the
# SOURCE tree is pin-checked above, but nothing tied the installed prefix to
# it, so a pin bump would ship the previous pin's SDL silently.
if [ ! -x "$SDLPREFIX/bin/sdl2-config" ] || \
   [ "$(cat "$SDLPREFIX/.built-from" 2>/dev/null)" != "$PIN_SDL_COMMIT" ]; then
	echo "==> [1] cross-building panther-sdl2 (ppc, static, 10.3, AltiVec ON)"
	rm -rf "$SDLPREFIX"
	( cd "$SDLSRC" && make distclean >/dev/null 2>&1 || true
	  # AltiVec LEFT ON (no --disable-altivec): the G4 has AltiVec; SDL's blitters are
	  # runtime-guarded by SDL_HasAltiVec anyway. gcc-4.0 + GCCINC for the 10.3.9 SDK.
	  CC="gcc-4.0 $ARCHFLAGS" CFLAGS="$ARCHFLAGS -isystem $GCCINC" LDFLAGS="$ARCHFLAGS" \
	  ./configure --prefix="$SDLPREFIX" --host=powerpc-apple-darwin8 --build=i686-apple-darwin11 \
	              --disable-joystick --disable-haptic --without-x --disable-shared --enable-static
	  make -j"$(sysctl -n hw.ncpu)" && make install )
	printf '%s\n' "$PIN_SDL_COMMIT" > "$SDLPREFIX/.built-from"
fi
export PATH="$SDLPREFIX/bin:$PATH"

# --- shared flags ------------------------------------------------------------
export CFLAGS="$ARCHFLAGS -std=gnu99 -isystem $GCCINC"
export LINKFLAGS="$ARCHFLAGS"
export LDFLAGS="$ARCHFLAGS"

# The engine, menu, miniutl and libbacktrace fixes are commits on our own branch
# of each of those upstreams, so the trees scripts/fetch-sources.sh checked out
# are already ported and go straight to the compiler.

# --- 2) engine + renderers + menu (needs the C++11 shims) --------------------
echo "==> [2] engine (ppc7400 / min-10.3)"
export CXXFLAGS="$ARCHFLAGS -isystem $SHIM -isystem $GCCINC $CXXINC -DMY_COMPILER_SUCKS=1 -include $SHIM/oldmac_cxx11.h"
( cd "$ENGINE"
  # --disable-rpath: the min-10.3 linker rejects -rpath (needs 10.5+); the .app uses dlopen +
  # DYLD_LIBRARY_PATH, not rpath. AltiVec stays ON (no --disable-altivec) -> ppc7400 subtype.
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
  python waf --out="$WAFOUT" configure --sdl-use-pkgconfig --skip-sdl2-sanity-check --disable-werror --disable-rpath
  python waf --out="$WAFOUT" build -j"$(sysctl -n hw.ncpu)"
  rm -rf "$DP"; python waf --out="$WAFOUT" install --destdir="$DP" )

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
echo "==> [3] hlsdk game dylibs (ppc / Tiger)"
# The waf DEST_CPU='ppc' cross-compile fix (without it waf mis-detects x86 and appends
# -march=pentium-m, which ppc cc1 rejects) and the big-endian shared-client fixes are
# commits on our own hlsdk-portable branch, checked out by scripts/fetch-sources.sh.
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
  python waf --out="$WAFOUT" configure --disable-werror
  python waf --out="$WAFOUT" build -j"$(sysctl -n hw.ncpu)"
  rm -rf "$DH"; python waf --out="$WAFOUT" install --destdir="$DH" )

# --- 4) assemble self-contained Tiger app ------------------------------------
echo "==> [4] assemble $APP"
rm -rf "$APP"; mkdir -p "$APP/valve/cl_dlls" "$APP/valve/dlls"
cp "$DP"/xash3d "$DP"/*.dylib "$APP/"
# Re-stamp exec + engine dylibs ppc(ALL) -> POWERPC_7400 (0x0A), an exact subtype (see the
# ARCHFLAGS note): make-universal fuses these as the ppc7400 slots; a generic ALL here collides
# with panther's ALL dylibs and is mis-graded by the Tiger/Leopard kernel. Thin 32-bit Mach-O:
# cpusubtype is the 4-byte big-endian field at offset 8 -> 00 00 00 0A. The shipped game dylibs
# are panther's generic-ppc pair (make-universal), so tiger's game dylibs are not restamped.
for f in "$APP/xash3d" "$APP"/*.dylib; do
	printf '\000\000\000\012' | dd of="$f" bs=1 seek=8 count=4 conv=notrunc 2>/dev/null
done
echo "    re-stamped tiger exec+dylibs -> $(lipo -info "$APP/xash3d" | sed 's/.*: //')"
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

echo "==> done. Tiger ppc build at $APP"
echo "    Arch check: file '$APP'/xash3d   (expect Mach-O ... ppc)"
echo "    Targets: Quicksilver + Mac mini G4 (both 10.4.11)."
