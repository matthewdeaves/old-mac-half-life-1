#!/bin/bash
# The arm64 slice of Half-Life (Xash3D FWGS), for Apple Silicon.
#
# RUN THIS ON THE APPLE SILICON DEV BOX, not on a mini. It is the one driver here
# that does not run on a build mini, and it cannot: Xcode 4.6 on Lion predates
# arm64 by seven years and cannot target it at all.
#
# That makes this the only slice built on a different machine from the other
# four, so it stages into its own directory and is carried to the mini for the
# fuse. See "HOW THIS REACHES THE FAT BINARY" below.
#
# WHY THE FUSE IS STILL DONE ON THE MINI (measured 2026-08-08)
#   The obvious worry was that Lion's lipo could not build a fat containing an
#   architecture from 2020. It can. It cannot NAME the slice, printing
#       Architectures in the fat file: ... are: x86_64 (cputype (16777228) cpusubtype (0))
#   which is the same cosmetic quirk CLAUDE.md already records for Panther's lipo
#   and x86_64, but the file it writes is correct: modern lipo on this box reads
#   it back as "x86_64 arm64", with CPU_TYPE_ARM64 / CPU_SUBTYPE_ARM64_ALL and the
#   right 2^14 alignment, and the arm64 slice runs natively. So make-universal.sh
#   keeps doing the whole fuse in one place.
#
# WHY arm64 NEEDS ITS OWN DEPLOYMENT FLOOR
#   There is no such thing as an arm64 Mac below macOS 11: Apple Silicon shipped
#   with Big Sur. So this slice's version-min has nothing to do with the 10.6
#   Intel floor and is not a knob worth exposing. 11.0 is simply the bottom.
#
# WHY libc++ HERE AND libstdc++ FOR INTEL
#   The Intel slice uses libstdc++ because 10.6 has no libc++ (see build-lion.sh).
#   That reasoning is entirely about old machines. Every arm64 Mac has libc++,
#   /usr/lib/libstdc++.6.dylib is long gone as a file, and the modern toolchain
#   has no libstdc++ headers at all. So arm64 uses libc++, and the two slices
#   legitimately differ. Nothing crosses between them: they are separate slices of
#   a fat binary and never share a process.
#
# WHERE THE SOURCE COMES FROM
#   The same pinned trees as every other slice, checked out by
#   scripts/fetch-sources.sh into $OLDMAC/vendor. Nothing is patched on the way to
#   the compiler. scripts/build-pins.sh names the exact commits. docs/adr/0012.
#
# HOW THIS REACHES THE FAT BINARY
#   1. here:  scripts/build-arm64.sh            -> $OLDMAC/dist/arm64
#   2. here:  scripts/push-arm64-slice.sh HOST  -> HOST:oldmac/dist/arm64
#   3. mini:  scripts/build-all.sh              -> fuses whatever slices exist
#   make-universal.sh treats dist/arm64 exactly like dist/lion-i386: optional,
#   fused when present, and SAID SO when absent, because a release that quietly
#   lost a slice looks just like one that never had it.
set -euo pipefail

OLDMAC="${OLDMAC:-$HOME/oldmac}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

ARCH=arm64
ARM64_MIN="${OLDMAC_ARM64_MIN:-11.0}"
GAMEARCH=arm64          # what 3rdparty/library_suffix calls it in a dylib name

ENGINE="$OLDMAC/vendor/xash3d-fwgs"
HLSDK="$OLDMAC/vendor/hlsdk-portable"
SDLPREFIX="$OLDMAC/sdl2-arm64"
OUT="$OLDMAC/dist/arm64"

# A CURRENT SDL2, not the 2.0.22 the other slices link.
#
# 2.0.22 is pinned everywhere else for one reason: it is the newest SDL that
# Apple clang 4.2 on Lion will compile, because later versions use clang-5-only
# `@available`. That constraint is entirely about the Lion build box and has
# nothing to say about arm64, which is built here with clang 21.
#
# And 2.0.22 does NOT build here. Its configure turns on
# -Werror=declaration-after-statement for C89 compatibility, and clang 21 then
# rejects SDL's own src/hidapi/mac/hid.c with eight errors. Forcing that warning
# off would leave a 2022 SDL driving display and input on macOS 26, which is the
# part of SDL most exposed to OS change. Using the current SDL2 is both the
# smaller change and the safer one.
#
# The engine's SDL version guards are SDL_VERSION_ATLEAST tests, written so one
# branch builds against both the old and the new SDL, so a newer SDL here is
# exactly the case they exist for.
SDL_VER="${OLDMAC_ARM64_SDL:-2.32.4}"

if [ "$(uname -m)" != "arm64" ]; then
	echo "!! build-arm64.sh must run on an Apple Silicon Mac (uname -m says $(uname -m))" >&2
	echo "   The Lion minis cannot target arm64; Xcode 4.6 predates it." >&2
	exit 2
fi

echo "==> arm64 slice: floor macOS $ARM64_MIN, C++ runtime libc++"

# --- pre-flight: the trees must be at their pins -----------------------------
# Same rule as every other driver. A tree at the wrong commit builds the wrong
# code and every check downstream still passes, because they all look at the
# OUTPUT. Refuse to start instead.
. "$REPO/scripts/build-pins.sh"

check_pin() {
	local have=""
	# -e, not -d: a SUBMODULE's .git is a FILE pointing into the superproject,
	# so -d reports the menu, miniutl and libbacktrace trees as missing when
	# they are present and correct.
	[ -e "$2/.git" ] || { echo "!! $1: no source tree at $2 (run scripts/fetch-sources.sh)" >&2; exit 1; }
	have="$( cd "$2" && git rev-parse HEAD )"
	[ "$have" = "$3" ] || {
		echo "!! $1: $2" >&2
		echo "   is at $have" >&2
		echo "   want  $3   (scripts/build-pins.sh)" >&2
		exit 1
	}
	echo "    ok  $1 $( short "$3" )"
}

echo "==> pre-flight: source trees at their pins"
check_pin engine       "$ENGINE"                                     "$PIN_ENGINE_COMMIT"
check_pin menu         "$ENGINE/3rdparty/mainui"                     "$PIN_MENU_COMMIT"
check_pin miniutl      "$ENGINE/3rdparty/mainui/miniutl"             "$PIN_MINIUTL_COMMIT"
check_pin libbacktrace "$ENGINE/3rdparty/libbacktrace/libbacktrace"  "$PIN_LIBBACKTRACE_COMMIT"
check_pin hlsdk        "$HLSDK"                                      "$PIN_HLSDK_COMMIT"

# --- 0) SDL2 from source (once) ----------------------------------------------
if [ ! -x "$SDLPREFIX/bin/sdl2-config" ]; then
	echo "==> [0/3] building SDL $SDL_VER (arm64, macOS $ARM64_MIN)"
	SRC="/tmp/SDL2-arm64-$SDL_VER"
	if [ ! -d "$SRC" ]; then
		curl -fsSL "https://www.libsdl.org/release/SDL2-$SDL_VER.tar.gz" | tar xz -C /tmp
		mv "/tmp/SDL2-$SDL_VER" "$SRC"
	fi
	( cd "$SRC"
	  make distclean >/dev/null 2>&1 || true
	  CC="clang -arch $ARCH -mmacosx-version-min=$ARM64_MIN" \
	  CFLAGS="-arch $ARCH -mmacosx-version-min=$ARM64_MIN" \
	  LDFLAGS="-arch $ARCH -mmacosx-version-min=$ARM64_MIN" \
	  ./configure --prefix="$SDLPREFIX" --build="$ARCH-apple-darwin" \
	              --disable-render-metal --disable-video-x11
	  make -j"$(sysctl -n hw.ncpu)"
	  make install )
fi
export PATH="$SDLPREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$SDLPREFIX/lib/pkgconfig"

# --- build flags -------------------------------------------------------------
# -arch goes in CC and CXX, not only in CFLAGS. waf probes the target CPU by
# compiling with the BARE compiler and never sees CFLAGS, and DEST_CPU decides
# the game dylib NAME. build-lion.sh learned this the hard way on the i386 slice:
# it reported "Target CPU: x86_64" while emitting i386 objects, which would have
# produced hl_amd64.dylib full of i386 code. Here the host is already arm64 so it
# would happen to be right, but relying on that is how it breaks the day this is
# cross-built.
export CC="clang -arch $ARCH"
export CXX="clang++ -arch $ARCH"
export CFLAGS="-arch $ARCH -mmacosx-version-min=$ARM64_MIN"
export CXXFLAGS="-arch $ARCH -mmacosx-version-min=$ARM64_MIN -stdlib=libc++"
export LINKFLAGS="-arch $ARCH -mmacosx-version-min=$ARM64_MIN -stdlib=libc++"
export LDFLAGS="-arch $ARCH -mmacosx-version-min=$ARM64_MIN -stdlib=libc++"
export MACOSX_DEPLOYMENT_TARGET="$ARM64_MIN"

ln -sfn "../$(basename "$HLSDK")" "$ENGINE/hlsdk"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> [1/3] game dylibs (hlsdk-portable, $ARCH/$ARM64_MIN)"
( cd "$ENGINE/hlsdk" && rm -rf build && python3 ./waf configure build install --destdir="$OUT" )

echo "==> [2/3] engine + renderers + menu ($ARCH/$ARM64_MIN)"
( cd "$ENGINE"
  rm -rf build
  # --enable-bundled-deps is NOT optional here, unlike on the minis.
  #
  # Without it waf finds Homebrew's opus, opusfile and vorbis under
  # /opt/homebrew and links them, and the result is a binary that depends on
  # dylibs no player has, built for macOS 26 while we target 11.0. The link even
  # says so:
  #   ld: warning: building for macOS-11.0, but linking with dylib
  #       '/opt/homebrew/opt/opusfile/lib/libopusfile.0.dylib' which was built
  #       for newer version 26.0
  # The Lion minis have no Homebrew, so this never came up for the other four
  # slices and the flag is not in build-lion.sh.
  python3 ./waf configure --sdl-use-pkgconfig --skip-sdl2-sanity-check \
                          --disable-werror --enable-bundled-deps
  python3 ./waf build
  python3 ./waf install --destdir="$OUT" )

# --- verify ------------------------------------------------------------------
# waf exits 0 on a failed task, so the output is the only evidence. Same checks
# as build-lion.sh: existence, architecture and floor, read back off the Mach-O.
for f in xash3d libxash.dylib libref_gl.dylib libref_soft.dylib libmenu.dylib filesystem_stdio.dylib; do
	[ -s "$OUT/$f" ] || { echo "!! build-arm64: $OUT/$f missing after install, the build did not do what it said" >&2; exit 1; }
done

echo "==> verifying every artifact really is $ARCH / macOS $ARM64_MIN"
bad=0
for f in xash3d libxash.dylib libref_gl.dylib libref_soft.dylib libmenu.dylib \
         filesystem_stdio.dylib "valve/cl_dlls/client_$GAMEARCH.dylib" \
         "valve/dlls/hl_$GAMEARCH.dylib" "$SDLPREFIX/lib/libSDL2-2.0.0.dylib"; do
	case "$f" in /*) p="$f" ;; *) p="$OUT/$f" ;; esac
	[ -s "$p" ] || { echo "    !! $f missing"; bad=1; continue; }
	got="$( lipo -info "$p" 2>/dev/null | sed 's/.*: //' | tr -d ' ' )"
	[ "$got" = "$ARCH" ] || { echo "    !! $(basename "$f"): built $got, wanted $ARCH"; bad=1; }
	# Modern toolchains write LC_BUILD_VERSION rather than LC_VERSION_MIN_MACOSX,
	# so read whichever is present rather than assuming the old one.
	vm="$( otool -l "$p" 2>/dev/null | awk '/LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX/{g=1} g&&/^ *(minos|version) /{print $2; exit}' )"
	[ "$vm" = "$ARM64_MIN" ] || { echo "    !! $(basename "$f"): floor is '${vm:-none}', wanted $ARM64_MIN"; bad=1; }
done
[ "$bad" -eq 0 ] || { echo "!! build-arm64: the slice does not match what it claims" >&2; exit 1; }
echo "    ok  every artifact $ARCH, floor macOS $ARM64_MIN"

# --- stage a self-contained SDL, and do the install-name surgery HERE ---------
#
# For the other four slices make-universal.sh copies the SDL and rewrites
# libxash's reference to it. It cannot do that for arm64, because the machine it
# runs on is Lion:
#
#   $ otool -arch arm64 -L libxash.dylib
#   otool: unknown architecture specification flag: -arch arm64
#   otool: known architecture flags are: any little big ppc64 x86_64 ... arm
#
# arm64 is not in that build of otool's architecture table at all, and neither
# lipo nor install_name_tool can select the slice inside a fat. Lion's lipo CAN
# fuse arm64, which is the one thing make-universal.sh actually needs from it.
#
# So everything that requires understanding arm64 load commands happens here,
# with a current toolchain, and the directory that gets carried over is already
# self-contained. make-universal.sh then only has to lipo it in.
echo "==> staging a self-contained libSDL2 for the arm64 slice"
cp "$SDLPREFIX/lib/libSDL2-2.0.0.dylib" "$OUT/"
chmod u+w "$OUT/libSDL2-2.0.0.dylib" "$OUT/libxash.dylib"
install_name_tool -id @loader_path/libSDL2-2.0.0.dylib "$OUT/libSDL2-2.0.0.dylib"
install_name_tool -change "$SDLPREFIX/lib/libSDL2-2.0.0.dylib" \
	@loader_path/libSDL2-2.0.0.dylib "$OUT/libxash.dylib"

# Same property the fused bundle is checked for: nothing may depend on a path
# that exists only on a build machine. Checked here because it cannot be checked
# on the mini.
echo "==> checking the arm64 slice depends on nothing outside /usr and /System"
dep_bad=0
for f in "$OUT/xash3d" "$OUT"/*.dylib "$OUT"/valve/*/*.dylib; do
	[ -e "$f" ] || continue
	own="$( otool -D "$f" 2>/dev/null | sed 1d )"
	while read -r dep; do
		case "$dep" in
			""|@*|/usr/*|/System/*) continue ;;
			"$own") continue ;;
		esac
		echo "    !! $(basename "$f") depends on $dep"
		dep_bad=1
	done < <( otool -L "$f" 2>/dev/null | sed 1d | awk '{print $1}' )
done
[ "$dep_bad" -eq 0 ] || {
	echo "!! build-arm64: the slice references paths that exist only on this box" >&2
	exit 1
}
echo "    ok  self-contained"

# --- build stamp -------------------------------------------------------------
# MEASURED from the tree, not copied from the pin, for the reason recorded in the
# other drivers: a stamp that restates the pin cannot detect a tree that moved.
STAMPED="$( cd "$ENGINE" && git rev-parse HEAD )"
[ "$STAMPED" = "$PIN_ENGINE_COMMIT" ] || {
	echo "!! build-arm64: engine tree is at $STAMPED but the pin says $PIN_ENGINE_COMMIT" >&2
	exit 1
}
printf '%s\n' "$STAMPED" > "$OUT/BUILD-STAMP"

echo
echo "== arm64 slice ready: $OUT =="
echo "   Next: scripts/push-arm64-slice.sh HOST   then build-all.sh on that host"
