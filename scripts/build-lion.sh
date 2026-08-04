#!/bin/bash
# Phase 1 - Intel x86_64 Half-Life (Xash3D FWGS) for Mac OS X 10.7 Lion.
# RUN THIS ON AN INTEL LION MINI - either mini-intel or mini-intel2 (identical
# Macmini2,1 / 10.7.5 / same toolchain). Proven working 2026-07-22: boots SP,
# plays the c0a0 opening sequence. Reproduces the Mac Source Ports 10.7+ floor.
# It runs LOCALLY on that box and does no ssh of its own, so pick-build-host.sh
# does not apply here - run `scripts/pick-build-host.sh --status` to see which
# mini is free, then log in there and run this.
#
# WHY each step is the way it is (do not "simplify" without testing):
#
#  Toolchain: Lion ships Xcode 4.6.3 (Apple clang 4.2 / LLVM 3.2) which HAS C++11,
#    but /usr/bin/clang is a stale 1.7 stub - you MUST use the Xcode toolchain via
#    DEVELOPER_DIR. waf 2.1.9 runs fine on Lion's Python 2.7. Xcode ships git too.
#
#  SDK juggling (the crux):
#    - Framework headers (IOKit/OpenGL/Cocoa) only exist inside an SDK sysroot, so
#      we pin -isysroot to the 10.7 SDK.
#    - BUT both legacy SDKs (10.7, 10.8) were stripped of libc++ headers, so C++11
#      code (mainui) can't find <cinttypes> from the sysroot. libc++ actually lives
#      at the toolchain's usr/lib/c++/v1 - add it with -isystem.
#    - clang 4.2 defaults to the ancient GNU libstdc++ (no C++11 headers); force
#      -stdlib=libc++ for all C++.
#
#  SDL2: FWGS needs SDL >= 2.0.16 (gyro/sensor GameController API in joy_sdl2.c,
#    plus various hints). The alex-free legacy 'leopard-sdl2' 2.0.6 is TOO OLD for
#    the Intel engine. Newer SDL uses clang-5-only `@available` - but ONLY in iOS
#    (uikit) and the Metal renderer. Disable the Metal render driver and SDL 2.0.22
#    compiles clean on clang 4.2. We build it from source, x86_64, min 10.7.
#
#  Engine configure deltas vs upstream build_apple.sh:
#    --sdl-use-pkgconfig  : consume our sdl2-config (no /Library/Frameworks framework,
#                           no pkg-config on the mini - waf falls back to sdl2-config)
#    (mbedTLS is now ENABLED - task #6.) The one 10.7 blocker was mbedtls_ms_time()
#      calling clock_gettime() (a 10.12+ symbol) in tf-psa-crypto's platform_util.c.
#      patch-mbedtls-oldmac.py defines MBEDTLS_PLATFORM_MS_TIME_ALT for old macOS, so
#      the engine's own compat.c routes that clock through Platform_DoubleTime() and
#      the clock_gettime path is compiled out. Entropy already works (Unix /dev/random
#      fopen path, no getentropy). Verified: mbedTLS links into libxash (+~0.5MB) and
#      the dylib has no 10.12+ undefined imports, so it loads on 10.7.
#    --disable-werror     : upstream -Werror trips on its own warnings under old clang
#    (no --enable-lto: old clang chokes; no --enable-utils/tests needed for a play build)
#
#  The engine's SDL-version guards (#ifdef / SDL_VERSION_ATLEAST around version-specific
#  hints and display-orientation in engine/platform/sdl2/{sys_sdl2.c,vid_sdl2.c}) are
#  inert against SDL 2.0.22, and are there so the one branch also builds against the
#  older SDL the PowerPC slices link.
#
# WHERE THE SOURCE COMES FROM
# All three slices build from the same trees, and every fix this port makes is a
# commit on the `oldmac` branch of our own fork of the relevant upstream: the
# engine (with the menu, miniutl and libbacktrace as its submodules) and the game
# dylibs. scripts/build-pins.sh names the exact commit for each,
# scripts/fetch-sources.sh checks them out, and this script compiles what it
# finds. Nothing rewrites an engine or game source file on the way past.
#
# task #6 DONE (Intel): TLS/HTTPS restored via patch-mbedtls-oldmac.py (below).
#   Built-in HTTPS content-download works; UDP multiplayer was never affected.
set -euo pipefail

# --- toolchain / SDK ---------------------------------------------------------
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SDK="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.7.sdk"
TCXX="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/c++/v1"
export PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$DEVELOPER_DIR/usr/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=10.7

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/vendor/xash3d-fwgs"             # our branch of FWGS/xash3d-fwgs
HLSDK="$ROOT/vendor/hlsdk-portable"           # our branch of FWGS/hlsdk-portable
SDLPREFIX="$ROOT/sdl2-x86_64"                 # our from-source SDL 2.0.22
OUT="$ROOT/dist/lion-x86_64"
SDL_VER=2.0.22

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
check_pin engine "$ENGINE" "$PIN_ENGINE_COMMIT"
check_sub menu         "$ENGINE/3rdparty/mainui"                    "$PIN_MENU_COMMIT"
check_sub miniutl      "$ENGINE/3rdparty/mainui/miniutl"            "$PIN_MINIUTL_COMMIT"
check_sub libbacktrace "$ENGINE/3rdparty/libbacktrace/libbacktrace" "$PIN_LIBBACKTRACE_COMMIT"
check_pin hlsdk  "$HLSDK"  "$PIN_HLSDK_COMMIT"

# --- 0) SDL2 from source (once) ---------------------------------------------
if [ ! -x "$SDLPREFIX/bin/sdl2-config" ]; then
	echo "==> [0/3] building SDL $SDL_VER (x86_64, 10.7, Metal disabled)"
	SRC="/tmp/SDL2-$SDL_VER"
	[ -d "$SRC" ] || curl -fsSL "https://www.libsdl.org/release/SDL2-$SDL_VER.tar.gz" | tar xz -C /tmp
	( cd "$SRC"
	  CC="clang -isysroot $SDK -arch x86_64 -mmacosx-version-min=10.7" \
	  CFLAGS="-isysroot $SDK -arch x86_64 -mmacosx-version-min=10.7" \
	  LDFLAGS="-isysroot $SDK -arch x86_64 -mmacosx-version-min=10.7" \
	  ./configure --prefix="$SDLPREFIX" --build=x86_64-apple-darwin11 \
	              --disable-render-metal --disable-video-x11
	  make -j"$(sysctl -n hw.ncpu)"
	  make install )
fi
export PATH="$SDLPREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$SDLPREFIX/lib/pkgconfig"

# --- build flags shared by hlsdk + engine ------------------------------------
export CFLAGS="-isysroot $SDK"
export CXXFLAGS="-isysroot $SDK -stdlib=libc++ -isystem $TCXX"
export LINKFLAGS="-isysroot $SDK -stdlib=libc++"
export LDFLAGS="-isysroot $SDK -stdlib=libc++"

ln -sfn "../$(basename "$HLSDK")" "$ENGINE/hlsdk"

# Nothing is edited here on the way past. Every fix, including the mbedTLS clock
# guard that gets built-in HTTPS working below 10.12, is a commit on our own
# branch of the tree it belongs to, and scripts/fetch-sources.sh checked those out
# already. docs/adr/0012.

# Clear the destdir before installing. Both PowerPC drivers do this and this one
# did not, so a waf task that failed while still exiting 0 left the PREVIOUS run's
# binaries in place, and the stamp written below then asserted they were built
# from the current pin. That is the stale-artifact fault the stamp exists to
# catch, reintroduced one directory upstream of the check.
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> [1/3] game dylibs (hlsdk-portable, x86_64/10.7)"
# The shared-client fixes, the same ones the mods carry, are commits on our own
# hlsdk-portable branch, checked out by scripts/fetch-sources.sh.
( cd "$ENGINE/hlsdk" && rm -rf build && python ./waf configure build install --destdir="$OUT" )

echo "==> [2/3] engine + renderers + menu (x86_64/10.7)"
( cd "$ENGINE"
  # Always from scratch, for the reason recorded in the PowerPC drivers: waf
  # reused a stale object across a commit change and shipped code that was not
  # in the tree, while every mtime looked fresh.
  rm -rf build
  python ./waf configure --sdl-use-pkgconfig --skip-sdl2-sanity-check \
                         --disable-werror
  python ./waf build
  python ./waf install --destdir="$OUT" )

# Every artifact must exist and be from THIS run. waf exits 0 on a failed task,
# so the only trustworthy evidence is the output. The PowerPC drivers have carried
# this check for a while; the Intel one did not.
for f in xash3d libxash.dylib libref_gl.dylib libref_soft.dylib libmenu.dylib filesystem_stdio.dylib; do
	[ -s "$OUT/$f" ] || { echo "!! build-lion: $OUT/$f missing after install, the build did not do what it said" >&2; exit 1; }
done

# --- build stamp -------------------------------------------------------------
# Record what this slice was actually built from. make-universal.sh refuses to
# fuse slices whose stamps disagree with each other or with build-pins.sh, so a
# directory left behind by an earlier run cannot be quietly folded into a release.
# MEASURED, not copied. Writing $PIN_ENGINE_COMMIT here made the stamp a restatement
# of the pin, so it could not detect a tree that moved after the pre-flight, and
# under an override it was simply false. Ask the tree what it is.
STAMPED="$( cd "$ENGINE" && git rev-parse HEAD )"
[ "$STAMPED" = "$PIN_ENGINE_COMMIT" ] || {
	echo "!! build-lion: engine tree is at $STAMPED but the pin says $PIN_ENGINE_COMMIT" >&2
	exit 1
}
printf '%s\n' "$STAMPED" > "$OUT/BUILD-STAMP"

echo "==> [3/3] assemble self-contained play folder"
# This step does `rm -rf` on the folder, so it stages OFF the Desktop, the same
# way build-ppc-panther.sh and build-ppc-tiger.sh already do.
#
# It used to default to ~/Desktop/Half-Life, which on a bench machine is the
# DEPLOYED game: the player's retail valve/ and every installed mod, gigabytes we
# did not put there and cannot regenerate. A comment warned about it and told you
# to set HL_APP_OUT. That is not a safeguard, it is a note next to an unguarded
# hole, and it was walked into three times in one afternoon, taking the installed
# mods on mini-intel with it. A default that destroys data unless you remember a
# variable is the wrong default.
#
# Nothing downstream needs this folder: make-universal.sh reads dist/lion-x86_64.
# It exists only to play the raw Intel build on the mini. Set HL_APP_OUT to
# ~/Desktop/Half-Life if that is genuinely what you want, and note it will be
# erased first.
APP="${HL_APP_OUT:-$ROOT/dist/lion-play}"
ASSETS="${HL_VALVE:-$HOME/hl-assets/valve}"   # retail valve/ (from the GOTY ISO)
rm -rf "$APP"; mkdir -p "$APP"
cp "$OUT"/xash3d "$OUT"/*.dylib "$APP/"
cp "$SDLPREFIX/lib/libSDL2-2.0.0.dylib" "$APP/"
chmod u+w "$APP/libSDL2-2.0.0.dylib" "$APP/libxash.dylib"
install_name_tool -id @loader_path/libSDL2-2.0.0.dylib "$APP/libSDL2-2.0.0.dylib"
install_name_tool -change "$SDLPREFIX/lib/libSDL2-2.0.0.dylib" \
	@loader_path/libSDL2-2.0.0.dylib "$APP/libxash.dylib"
cp -R "$ASSETS" "$APP/valve"
mkdir -p "$APP/valve/cl_dlls" "$APP/valve/dlls"
cp "$OUT/valve/cl_dlls/"*.dylib "$APP/valve/cl_dlls/"
cp "$OUT/valve/dlls/"*.dylib    "$APP/valve/dlls/"
cp "$OUT/valve/extras.pk3" "$APP/valve/" 2>/dev/null || true

echo "==> done. Raw build staged at '$APP' (cd there and ./xash3d to play it)."
echo "    The DEPLOYED game on the Desktop is untouched; deploy-dmg.sh updates that."
echo "    Arch check: file '$APP'/xash3d  (expect Mach-O 64-bit executable x86_64)"
