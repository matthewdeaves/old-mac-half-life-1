#!/bin/bash
# build-installer-arm64.sh - the Mods app's arm64 slice.
#
#   scripts/build-installer-arm64.sh
#
# RUN THIS ON THE APPLE SILICON BOX. Third and last of the "no mini can do this"
# drivers, after scripts/build-arm64.sh (engine) and scripts/build-mod-arm64.sh
# (the 25 mod dylib pairs). Xcode 4.6 on Lion predates arm64 by seven years.
#
# Output: dist/installer-arm64/installer, a THIN arm64 Mach-O. The fuse stays in
# one place, and that place is build-installer.sh on the mini, which picks this
# file up if scripts/push-mod-arm64.sh has carried it over and says so either way.
#
# WHY BOTHER, GIVEN ROSETTA 2 EXISTS
#   The x86_64 slice already runs on Apple Silicon under translation, so this is
#   a downgrade to be without rather than a failure. It is worth having anyway:
#   Rosetta 2 is not a permanent fixture of macOS, and this is the app that
#   downloads and unpacks archives, so it is the one place in the project doing
#   real CPU work outside the engine.
#
# It deliberately mirrors build-installer.sh's source lists rather than sharing
# them. That is duplication, and the alternative was worse: the two builds do not
# agree about the compiler, the SDK, the floor, or which mbedTLS workarounds are
# needed, so a shared list would have grown a branch at every line anyway.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/installer"
BUILD="$ROOT/dist/installer-arm64-build"
OUT="$ROOT/dist/installer-arm64"

ARCH=arm64
# Apple Silicon shipped with Big Sur, so there is no older macOS for an arm64
# slice to run on. Same floor as the engine's arm64 slice.
ARM64_MIN="${OLDMAC_ARM64_MIN:-11.0}"

[ "$(uname -m)" = "arm64" ] || {
	echo "!! this must run on an Apple Silicon Mac; uname -m says $(uname -m)" >&2
	exit 1
}

SOURCES="$SRC/main.m $SRC/OMController.m $SRC/OMInstaller.m $SRC/OMDownload.m $SRC/OMTGA.m $SRC/OMAbout.m $SRC/OMFetch.m $SRC/OMUtil.m $SRC/OMTLS.m $SRC/OMArchive.m $SRC/om7z.c"

ZLIB="$ROOT/vendor/zlib-installer"
LZMA="$ROOT/vendor/lzma-installer/C"
MBEDTLS="$ROOT/vendor/mbedtls-installer"
for d in "$ZLIB" "$LZMA" "$MBEDTLS/library"; do
	[ -d "$d" ] || { echo "ERROR: missing $d - run scripts/fetch-sources.sh" >&2; exit 1; }
done
[ -f "$ZLIB/zconf.h" ] || cp "$ZLIB/zconf.h.in" "$ZLIB/zconf.h"

# inflate only: we never compress.
ZLIB_SRC=""
for c in adler32 crc32 inflate inftrees inffast zutil; do
	ZLIB_SRC="$ZLIB_SRC $ZLIB/$c.c"
done

# The 7z reader set. No encoder, no Sha256 (AES-encrypted archives are refused
# rather than supported).
LZMA_SRC=""
for c in 7zAlloc 7zArcIn 7zBuf 7zCrc 7zCrcOpt 7zDec 7zFile 7zStream \
         Bcj2 Bra Bra86 BraIA64 CpuArch Delta Lzma2Dec LzmaDec Ppmd7 Ppmd7Dec; do
	LZMA_SRC="$LZMA_SRC $LZMA/$c.c"
done

ARCHIVE_FLAGS="-I$ZLIB -I$LZMA -DZ7_ST -D_7ZIP_ST"

# Same two exclusions as the other slices, and they are NOT old-macOS specific:
# OMTLS.m drives mbedTLS over the socket layer this app already had, so
# net_sockets.c is unused, and timing.c is DTLS/self-test only. Building them
# here and not there would mean the arm64 slice ran different code.
MBED_SRC=""
for f in "$MBEDTLS"/library/*.c; do
	case "$(basename "$f")" in
		net_sockets.c|timing.c) continue ;;
	esac
	MBED_SRC="$MBED_SRC $f"
done
# shellcheck disable=SC2089,SC2090 # the escaped quotes around the config file
# name must survive into the compiler argv; unquoted expansion does no
# quote removal, so the macro arrives correctly. An array cannot be used:
# this also runs under Lion bash 3.2 where the calling style predates it.
MBED_FLAGS="-I$MBEDTLS/include -I$MBEDTLS/library -I$SRC -DMBEDTLS_USER_CONFIG_FILE=\"om_mbedtls_config.h\""

rm -rf "$BUILD" "$OUT"; mkdir -p "$BUILD/obj" "$OUT"

CFL="-arch $ARCH -mmacosx-version-min=$ARM64_MIN"

echo "==> compiling $ARCH (clang $(clang --version | head -1 | sed 's/.*version //;s/ .*//'), floor macOS $ARM64_MIN)"
for f in $MBED_SRC; do
	# shellcheck disable=SC2090 # see the note at the MBED_FLAGS assignment
	clang $CFL -std=gnu99 $MBED_FLAGS -O2 -c "$f" -o "$BUILD/obj/$(basename "$f" .c).o"
done
for f in $ZLIB_SRC $LZMA_SRC; do
	clang $CFL -std=gnu99 $ARCHIVE_FLAGS -O2 -c "$f" -o "$BUILD/obj/$(basename "$f" .c).o"
done
# -Wno-deprecated-declarations is doing more work here than on the other slices.
# This is 10.3-era Cocoa compiled against a 2026 SDK, so a great deal of it is
# formally deprecated and none of it is gone. Warnings, not errors: an API that
# has actually been REMOVED fails to compile and is not silenced by this.
clang $CFL -framework Cocoa -framework Foundation \
	-Wall -Wno-deprecated-declarations -O2 -o "$OUT/installer" \
	$SOURCES "$BUILD"/obj/*.o -I"$SRC" -I"$MBEDTLS/include" $ARCHIVE_FLAGS

# Prove it, rather than trusting the flags. The floor especially: a slice that
# quietly kept this box's own version compiles, links, lipos and ships.
echo "==> verifying"
info="$(lipo -info "$OUT/installer" | sed 's/.*: //')"
[ "$info" = "$ARCH" ] || { echo "!! expected $ARCH, got '$info'" >&2; exit 1; }
vm="$(otool -l "$OUT/installer" | awk '/LC_BUILD_VERSION/{v=1} v&&/minos/{print $2; exit}')"
[ "$vm" = "$ARM64_MIN" ] || { echo "!! floor is '${vm:-none}', wanted $ARM64_MIN" >&2; exit 1; }
# This app has no C++ at all. Anything C++ turning up means something was linked
# that should not have been.
if otool -L "$OUT/installer" | grep -qE 'libc\+\+|libstdc\+\+'; then
	echo "!! links a C++ runtime; this app is pure Objective-C" >&2
	otool -L "$OUT/installer" >&2
	exit 1
fi
# Nothing outside the OS. The mini that fuses this cannot check any of that,
# because its install_name_tool and otool refuse a file containing arm64
# outright, so it has to be checked here or not at all.
if otool -L "$OUT/installer" | tail -n +2 | grep -vqE '^\s+(/usr/lib|/System/)'; then
	echo "!! depends on something outside /usr and /System:" >&2
	otool -L "$OUT/installer" >&2
	exit 1
fi
echo "    ok  $ARCH, floor macOS $vm, no C++ runtime, no outside dependencies"

# --- build stamp -------------------------------------------------------------
# What this slice was built FROM, so build-installer.sh on the mini can refuse
# to fuse it once installer/ has moved on. Without this the fuse tested only
# that the file existed, and an ordinary commit to installer/ shipped an app
# running old code on Apple Silicon and new code on the other four slices.
# Issue #4. The reasoning, and why this is a content hash rather than a commit
# id, is at the top of scripts/arm64-stamp.sh and in docs/adr/0015.
#
# MEASURED, not restated: it is taken from the files that were just compiled.
# Nothing in this script writes into $SRC, so there is no ordering trap of the
# kind old-mac-quake2 hit in ea922696; the stamp is the same before and after.
. "$ROOT/scripts/arm64-stamp.sh"
oldmac_src_stamp $SOURCES "$SRC"/*.h > "$OUT/BUILD-STAMP"
echo "    source stamp $( cat "$OUT/BUILD-STAMP" )"

echo
echo "Carry it to the build host with:"
echo "  scripts/push-mod-arm64.sh HOST"
