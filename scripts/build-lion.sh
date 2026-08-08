#!/bin/bash
# The Intel x86_64 slice of Half-Life (Xash3D FWGS). Floor is 10.6 Snow Leopard.
# RUN THIS ON AN INTEL LION MINI - either mini-intel or mini-intel2 (identical
# Macmini2,1 / 10.7.5 / same toolchain). Proven working 2026-07-22: boots SP,
# plays the c0a0 opening sequence.
# It runs LOCALLY on that box and does no ssh of its own, so pick-build-host.sh
# does not apply here - run `scripts/pick-build-host.sh --status` to see which
# mini is free, then log in there and run this.
#
# The box it BUILDS ON is 10.7; the floor it builds FOR is 10.6. Those are
# different numbers and only the second one ships. Set OLDMAC_INTEL_MIN=10.7 to
# go back to the old floor for an A/B.
#
# WHY each step is the way it is (do not "simplify" without testing):
#
#  Toolchain: Lion ships Xcode 4.6.3 (Apple clang 4.2 / LLVM 3.2) which HAS C++11,
#    but /usr/bin/clang is a stale 1.7 stub - you MUST use the Xcode toolchain via
#    DEVELOPER_DIR. waf 2.1.9 runs fine on Lion's Python 2.7. Xcode ships git too.
#
#  SDK juggling (the crux):
#    - Framework headers (IOKit/OpenGL/Cocoa) only exist inside an SDK sysroot, so
#      we pin -isysroot to the 10.7 SDK. The SDK is NOT the floor: what a binary
#      runs on is set by -mmacosx-version-min, and building against a newer SDK
#      with an older version-min is the supported way to do this.
#    - Both legacy SDKs (10.7, 10.8) were stripped of libc++ headers, so on the
#      libc++ path C++11 code can't find <cinttypes> from the sysroot. libc++
#      actually lives at the toolchain's usr/lib/c++/v1 - add it with -isystem.
#
#  WHY THE FLOOR IS 10.6 AND WHY THAT MEANS libstdc++ (measured 2026-08-08):
#    The ONLY thing that ever held this slice at 10.7 was /usr/lib/libc++.1.dylib,
#    which does not exist on 10.6. Everything else in the whole Intel stack
#    resolves against libSystem.
#
#    The entire C++ runtime dependency is 13 symbols, measured with nm -u over
#    xash3d + all five engine dylibs + both game dylibs: operator new/new[]/
#    delete/delete[], __cxa_atexit, __cxa_pure_virtual, __gxx_personality_v0,
#    std::terminate, and the two __cxxabiv1 class_type_info vtables. xash3d and
#    libxash import NONE of them; only libmenu, filesystem_stdio and the two game
#    dylibs do. There is no STL use anywhere: mainui has zero std::string,
#    std::vector, std::move, std::unique_ptr or std::function (it uses MiniUTL),
#    and hlsdk uses no std:: at all. C++11 use is LANGUAGE only (nullptr,
#    override, static_assert, one constexpr).
#
#    10.6's libstdc++.6.dylib exports 9 of those 10 C++ symbols; the tenth,
#    __cxa_atexit, is in libSystem on Darwin (verified: T ___cxa_atexit).
#    So -stdlib=libstdc++ satisfies the lot.
#
#    libstdc++ is also the WIDER choice, not a compromise. On macOS 26 there is no
#    /usr/lib/libstdc++.6.dylib file on disk, but dlopen() of that path SUCCEEDS
#    from the dyld shared cache, so a libstdc++-linked x86_64 binary still runs
#    under Rosetta 2 today. Range is 10.6.8 -> macOS 26 inclusive, against
#    libc++'s 10.7+.
#
#    The one genuine gap is <cinttypes>, a C++11 header GCC 4.2's header set
#    predates, included by miniutl/fmtstr.h and miniutl/utllinkedlist.h and used
#    only for PRIi32/PRIi64/PRIu32/PRIu64/PRIx64. compat-include/cinttypes
#    supplies it from C99 <inttypes.h>. That is a build include path, NOT a patch
#    to a vendored tree, so docs/adr/0012 still holds.
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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- deployment floor, and the C++ runtime that follows from it ---------------
# These two are ONE decision, not two, so they are made in one place: below 10.7
# there is no libc++ on the machine, so the floor picks the runtime. Setting one
# without the other produces a slice that links happily on the build box and
# fails to load on the machine it was lowered for.
INTEL_MIN="${OLDMAC_INTEL_MIN:-10.6}"
case "$INTEL_MIN" in
	10.6) CXXLIB="libstdc++" ;;
	10.7) CXXLIB="libc++"    ;;
	*)    echo "!! OLDMAC_INTEL_MIN must be 10.6 or 10.7, got '$INTEL_MIN'" >&2; exit 2 ;;
esac
export MACOSX_DEPLOYMENT_TARGET="$INTEL_MIN"

# --- which Intel architecture ------------------------------------------------
# x86_64 is every Intel Mac from 2006's Core 2 Duo onwards. i386 exists solely
# for the 2006 Core Solo and Core Duo machines (Mac mini 1,1, iMac 4,1,
# MacBook 1,1, MacBook Pro 1,1), which have no 64-bit mode at all and cap at
# 10.6.8. They are the last Intel machines the x86_64 slice can never reach.
#
# A fat may hold both: they are different cputypes, so this is additive and
# cannot disturb the grading of the existing slices, which was measured
# separately on the G3, both G4s, the G5 and both Intel minis.
INTEL_ARCH="${OLDMAC_INTEL_ARCH:-x86_64}"
# The game dylib NAMES are not "the architecture with an underscore in front".
# COM_GenerateLibraryName (3rdparty/library_suffix) special-cases 32-bit x86 on
# Windows, Linux and Apple:
#
#     if( arch == ARCHITECTURE_X86 )
#         snprintf( out, size, "%s%s.%s", prefix, name, ext );      // hl.dylib
#     else
#         snprintf( out, size, "%s%s_%s.%s", prefix, name, arch, ext );
#
# because 32-bit x86 was Half-Life's original platform and its libraries have
# never carried a suffix. So i386 is hl.dylib and client.dylib, with no _i386
# anywhere, while ppc, amd64 and arm64 all take the suffixed form. Getting this
# wrong is not cosmetic: the engine dlopen's these BY NAME, so a suffixed i386
# pair would simply never be found.
case "$INTEL_ARCH" in
	x86_64) GAME_CL=client_amd64.dylib ; GAME_SV=hl_amd64.dylib ;;
	i386)   GAME_CL=client.dylib       ; GAME_SV=hl.dylib       ;;
	*) echo "!! OLDMAC_INTEL_ARCH must be x86_64 or i386, got '$INTEL_ARCH'" >&2; exit 2 ;;
esac

# SDL is built per floor AND per architecture, each in its own prefix. A 10.7
# libSDL2 dropped into a 10.6 build links and installs without complaint and then
# refuses to load on 10.6; an x86_64 one in an i386 build does not link at all,
# which is at least loud. Keep them apart either way.
case "$INTEL_MIN" in
	10.6) SDLPREFIX="$ROOT/sdl2-snow-$INTEL_ARCH" ;;
	10.7) SDLPREFIX="$ROOT/sdl2-$INTEL_ARCH" ;;
esac
# The historical x86_64 prefixes have no -x86_64 suffix problem: sdl2-x86_64 and
# sdl2-snow-x86_64 are exactly the names that were already there.

ENGINE="$ROOT/vendor/xash3d-fwgs"             # our branch of FWGS/xash3d-fwgs
HLSDK="$ROOT/vendor/hlsdk-portable"           # our branch of FWGS/hlsdk-portable
OUT="$ROOT/dist/lion-$INTEL_ARCH"
SDL_VER=2.0.22

echo "==> Intel slice: $INTEL_ARCH, floor $INTEL_MIN, C++ runtime $CXXLIB"

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
	echo "==> [0/3] building SDL $SDL_VER (x86_64, $INTEL_MIN, Metal disabled)"
	SRC="/tmp/SDL2-$SDL_VER"
	[ -d "$SRC" ] || curl -fsSL "https://www.libsdl.org/release/SDL2-$SDL_VER.tar.gz" | tar xz -C /tmp
	# Configure caches results per source dir, and this tree is shared between the
	# 10.6 and 10.7 prefixes, so a cached probe from the other floor would be
	# reused. Start it clean.
	( cd "$SRC"
	  make distclean >/dev/null 2>&1 || true
	  CC="clang -isysroot $SDK -arch $INTEL_ARCH -mmacosx-version-min=$INTEL_MIN" \
	  CFLAGS="-isysroot $SDK -arch $INTEL_ARCH -mmacosx-version-min=$INTEL_MIN" \
	  LDFLAGS="-isysroot $SDK -arch $INTEL_ARCH -mmacosx-version-min=$INTEL_MIN" \
	  ./configure --prefix="$SDLPREFIX" --build="$INTEL_ARCH-apple-darwin11" \
	              --disable-render-metal --disable-video-x11
	  make -j"$(sysctl -n hw.ncpu)"
	  make install )
fi
export PATH="$SDLPREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$SDLPREFIX/lib/pkgconfig"

# --- build flags shared by hlsdk + engine ------------------------------------
# The extra C++ include dir differs by runtime, and in BOTH cases it exists to
# supply C++11 headers the sysroot does not have:
#   libc++    the 10.7/10.8 SDKs were stripped of libc++ headers, so point at the
#             toolchain's own copy
#   libstdc++ GCC 4.2's header set predates C++11 entirely, so supply the one
#             header this port actually uses (see compat-include/cinttypes)
case "$CXXLIB" in
	libc++)    CXXINC="$TCXX" ;;
	libstdc++) CXXINC="$ROOT/compat-include" ;;
esac
[ -d "$CXXINC" ] || { echo "!! missing C++ include dir $CXXINC" >&2; exit 1; }

# -mmacosx-version-min is passed EXPLICITLY as well as via
# MACOSX_DEPLOYMENT_TARGET. waf spawns compilers through several paths and an
# exported variable is easy to lose; the flag is not. If the two ever disagree
# the flag wins, which is the safe direction.
# -arch goes in CC and CXX, NOT only in CFLAGS. This is the whole reason the
# first i386 attempt was wrong.
#
# waf probes the target CPU by compiling a small program with the BARE compiler
# and reading its predefined macros. It never sees CFLAGS during that probe, so
# with -arch only in CFLAGS it reported "Target CPU: x86_64" while actually
# emitting i386 objects. That is not cosmetic: DEST_CPU decides the game dylib
# NAME, so hlsdk would have written hl_amd64.dylib containing i386 code, and the
# i386 engine would then have looked for hl_i386.dylib at runtime and found
# nothing. It also drives compiler_optimizations.py, which appends x86_64 -march
# flags.
#
# Both PowerPC drivers already do it this way (CC="gcc-4.0 $ARCHFLAGS"), which is
# exactly why they detect ppc correctly and this did not. Our engine branch even
# carries an oldmac_fixup_dest_cpu for the ppc case; putting -arch where waf can
# see it means no equivalent hack is needed for i386.
export CC="clang -arch $INTEL_ARCH"
export CXX="clang++ -arch $INTEL_ARCH"

export CFLAGS="-isysroot $SDK -arch $INTEL_ARCH -mmacosx-version-min=$INTEL_MIN"
export CXXFLAGS="-isysroot $SDK -arch $INTEL_ARCH -mmacosx-version-min=$INTEL_MIN -stdlib=$CXXLIB -isystem $CXXINC"
export LINKFLAGS="-isysroot $SDK -arch $INTEL_ARCH -mmacosx-version-min=$INTEL_MIN -stdlib=$CXXLIB"
export LDFLAGS="-isysroot $SDK -arch $INTEL_ARCH -mmacosx-version-min=$INTEL_MIN -stdlib=$CXXLIB"

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

echo "==> [1/3] game dylibs (hlsdk-portable, $INTEL_ARCH/$INTEL_MIN)"
# The shared-client fixes, the same ones the mods carry, are commits on our own
# hlsdk-portable branch, checked out by scripts/fetch-sources.sh.
( cd "$ENGINE/hlsdk" && rm -rf build && python ./waf configure build install --destdir="$OUT" )

echo "==> [2/3] engine + renderers + menu ($INTEL_ARCH/$INTEL_MIN)"
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

# --- the floor is a claim until something checks it --------------------------
# A slice built on a 10.7 box that quietly kept a 10.7 version-min, or that still
# links libc++, builds clean, installs clean, passes every existing check and
# then fails to launch on the ONE machine the floor was lowered for. waf gets its
# flags from four environment variables through several spawn paths; losing one
# is not hypothetical. So read it back off the Mach-O.
echo "==> verifying every artifact really targets $INTEL_MIN"
floor_bad=0
for f in xash3d libxash.dylib libref_gl.dylib libref_soft.dylib libmenu.dylib \
         filesystem_stdio.dylib "valve/cl_dlls/$GAME_CL" \
         "valve/dlls/$GAME_SV" \
         "$SDLPREFIX/lib/libSDL2-2.0.0.dylib"; do
	case "$f" in /*) p="$f" ;; *) p="$OUT/$f" ;; esac
	if [ ! -s "$p" ]; then
		echo "    !! $f missing"; floor_bad=1; continue
	fi
	# The architecture is checked as well as the floor. -arch is passed
	# explicitly, but the compiler's default here is x86_64, so a flag lost
	# anywhere in waf's spawn paths would produce a perfectly good x86_64 build
	# in dist/lion-i386 that only fails much later, at lipo, with a confusing
	# "duplicate architecture" rather than anything naming the real cause.
	got_arch="$( lipo -info "$p" 2>/dev/null | sed 's/.*: //' | tr -d ' ' )"
	if [ "$got_arch" != "$INTEL_ARCH" ]; then
		echo "    !! $(basename "$f"): built $got_arch, wanted $INTEL_ARCH"; floor_bad=1
	fi
	vm="$( otool -l "$p" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/{g=1} g&&/^ *version /{print $2; exit}' )"
	if [ "$vm" != "$INTEL_MIN" ]; then
		echo "    !! $(basename "$f"): version-min is '${vm:-none}', wanted $INTEL_MIN"; floor_bad=1
	fi
	# libc++ arrived in 10.7. On the 10.6 floor its presence anywhere is fatal,
	# and it is the exact thing that kept this slice at 10.7 for so long.
	if [ "$CXXLIB" = "libstdc++" ] && otool -L "$p" 2>/dev/null | grep -q 'libc++'; then
		echo "    !! $(basename "$f"): links libc++, which does not exist on $INTEL_MIN"; floor_bad=1
	fi
done
if [ "$floor_bad" -ne 0 ]; then
	echo "!! build-lion: the Intel slice does not match the floor it claims" >&2
	exit 1
fi
echo "    ok  every artifact $INTEL_ARCH, version-min $INTEL_MIN, C++ runtime $CXXLIB"

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
