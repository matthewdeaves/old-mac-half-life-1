#!/bin/bash
# build-installer.sh - build "Half-Life Mods.app", the fat installer.
#
#   ./build-installer.sh [output.app]
#
# RUN THIS ON AN INTEL LION MINI, same as every other build here. It compiles the
# Cocoa app once per architecture - Apple gcc-4.0 against the 10.3.9 SDK for
# PowerPC, Xcode clang against the 10.7 SDK for each Intel one - then lipos them
# into one binary and wraps it in a bundle.
#
# WHY COCOA
#   Carbon was never ported to 64-bit, so a Carbon app could not produce our
#   x86_64 slice at all. Cocoa has everything this UI needs as far back as 10.3
#   (NSProgressIndicator, NSTextView, NSImageView, real buttons), and the PowerPC
#   Objective-C path is already proven on this toolchain - panther-sdl2 is a
#   native-Cocoa build.
#
# WHY ONE ppc SLICE, UNLIKE THE GAME
#   The hard rule against a generic `ppc (ALL)` slice exists because Tiger and
#   Leopard mis-grade a fat containing SEVERAL ppc slices on a 750 host. One
#   generic ppc slice alongside the Intel ones is the ordinary 2006 case and
#   grades correctly on G3, G4, G5 and Intel alike.
#
# WHAT GETS BUNDLED (and why as much as possible is)
#   Contents/Resources/mods/<branch>/{server,client}.dylib   our fat game code
#   Contents/Resources/mods.map                              gamedir -> branch/name
#   Contents/Resources/manifests.txt                         expected install size
#   Contents/Resources/mod-sources.txt                       per-mod URL + md5 + root
#   Contents/Resources/descriptions/<gamedir>.txt            Custom Game blurbs
#   Contents/Resources/artwork/<gamedir>.tga                 Custom Game previews
#   Contents/Resources/About-Gordon.png                      About-box artwork
#   Contents/Resources/Half-Life-Mods.icns                   the app icon
#   Everything precompiled and verified here is one less thing that can go wrong
#   on a 20-year-old machine, and means we take only content from the download.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/installer"
OUT="${1:-$ROOT/dist/Half-Life Mods.app}"
BUILD="$ROOT/dist/installer-build"
MODS="$ROOT/dist/mods"

# --- toolchains (mirroring build-lion.sh / build-ppc-panther.sh) -------------
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
XCBIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"
export PATH="$XCBIN:$DEVELOPER_DIR/usr/bin:$PATH"

SDK_INTEL="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.7.sdk"
SDK_PPC=/Developer/SDKs/MacOSX10.3.9.sdk

# Intel floor, matching the game (scripts/build-lion.sh). The SDK stays at 10.7,
# because the SDK is not the floor: -mmacosx-version-min is.
#
# This app needs none of the libc++ reasoning the engine needed. It is pure
# Objective-C with no C++ at all: nm -u on the shipped v1.5.7 binary finds zero
# __Z, __cxa or operator-new symbols, and it links only Cocoa, Foundation,
# AppKit, CoreFoundation, libSystem and libobjc, every one of which is on 10.6.
# The source uses no 10.7-only API (checked for NSRegularExpression,
# NSJSONSerialization, NSOrderedSet, NSPopover, autolayout, NSURLSession,
# full-screen and friends) and no ARC.
#
# It was left at 10.7 only because the engine was. Once the game reached 10.6 a
# 10.6 owner would have had the game and no mod installer.
INTEL_MIN="${OLDMAC_INTEL_MIN:-10.6}"

[ -d "$SDK_INTEL" ] || { echo "ERROR: missing 10.7 SDK: $SDK_INTEL" >&2; exit 1; }
[ -d "$SDK_PPC" ]   || { echo "ERROR: missing 10.3.9 SDK: $SDK_PPC" >&2; exit 1; }

SOURCES="$SRC/main.m $SRC/OMController.m $SRC/OMInstaller.m $SRC/OMDownload.m $SRC/OMTGA.m $SRC/OMAbout.m $SRC/OMFetch.m $SRC/OMUtil.m $SRC/OMTLS.m $SRC/OMArchive.m $SRC/om7z.c"

# --- zlib and the LZMA SDK --------------------------------------------------
# Mods now arrive as whatever archive their publisher chose: 6 zip, 12 7z. Both
# decoders are vendored and pinned rather than taken from the system.
#
# zlib: Panther ships libz 1.1.3 from 2003 and has no zlib.h on the live system
# at all. Linking whatever each machine happens to carry would mean a decoder fed
# files off the internet behaves differently on 10.3 than on 26.
#
# LZMA: there is no system 7z anywhere, at any vintage.
#
# om7z.c is compiled as C, NOT Objective-C, and that is not a style choice. On
# 10.3, Cocoa pulls in Carbon's MacTypes.h, which defines UInt32/UInt16; the LZMA
# SDK's 7zTypes.h defines the same names, and gcc-4.0 refuses:
#   7zTypes.h:182: error: conflicting types for 'UInt32'
# The Intel slice does not hit this, because the 10.7 SDK's Cocoa does not pull
# Carbon in the same way. Keeping the decoder free of Foundation avoids it on
# both.
ZLIB="$ROOT/vendor/zlib-installer"
LZMA="$ROOT/vendor/lzma-installer/C"
[ -d "$ZLIB" ] || { echo "ERROR: missing zlib at $ZLIB - run scripts/fetch-sources.sh" >&2; exit 1; }
[ -d "$LZMA" ] || { echo "ERROR: missing LZMA SDK at $LZMA - run scripts/fetch-sources.sh" >&2; exit 1; }
[ -f "$ZLIB/zconf.h" ] || cp "$ZLIB/zconf.h.in" "$ZLIB/zconf.h"

# inflate only: we never compress, so deflate.c, trees.c and the gz* wrappers are
# dead weight and more surface than we need.
ZLIB_SRC=""
for c in adler32 crc32 inflate inftrees inffast zutil; do
	ZLIB_SRC="$ZLIB_SRC $ZLIB/$c.c"
done

# The 7z *reader* set. No encoder, and no Sha256: that is only needed for
# AES-encrypted archives, which we refuse rather than support, and pulling it in
# drags a hardware-accelerated variant that does not link cleanly here.
LZMA_SRC=""
for c in 7zAlloc 7zArcIn 7zBuf 7zCrc 7zCrcOpt 7zDec 7zFile 7zStream \
         Bcj2 Bra Bra86 BraIA64 CpuArch Delta Lzma2Dec LzmaDec Ppmd7 Ppmd7Dec; do
	LZMA_SRC="$LZMA_SRC $LZMA/$c.c"
done

ARCHIVE_FLAGS="-I$ZLIB -I$LZMA -DZ7_ST -D_7ZIP_ST"

# --- mbedTLS ----------------------------------------------------------------
# The app carries its own TLS because each mod now comes from wherever that mod
# is published, and every host that matters (moddb, gamebanana,
# runthinkshootlive, twhl ...) answers plain http with a 301 to https.
#
# This is NOT the engine's mbedTLS. That one is the 4.x line with the
# tf-psa-crypto split, and its old-macOS clock fix routes mbedtls_ms_time()
# through the engine's Platform_DoubleTime(), which does not exist in a Cocoa
# app. This is 3.6 LTS, pinned in vendor/MANIFEST.md, one tree, C99.
#
# TWO FILES ARE EXCLUDED, both measured against the 10.3.9 SDK with gcc-4.0:
#   net_sockets.c    "'suseconds_t' undeclared" - and unneeded, since OMTLS.m
#                    drives mbedTLS over the socket layer this app already had.
#   timing.c         DTLS/self-test only, and another clock liability on 10.3.
# The third old-macOS problem, platform_util.c's hard
# `#error "No mbedtls_ms_time available"` (clock_gettime is 10.12+), is fixed
# rather than excluded: om_mbedtls_config.h selects MBEDTLS_PLATFORM_MS_TIME_ALT
# and OMTLS.m supplies the function from gettimeofday.
MBEDTLS="$ROOT/vendor/mbedtls-installer"
[ -d "$MBEDTLS/library" ] || { echo "ERROR: missing mbedTLS at $MBEDTLS - run scripts/fetch-sources.sh" >&2; exit 1; }

MBED_SRC=""
for f in "$MBEDTLS"/library/*.c; do
	case "$(basename "$f")" in
		net_sockets.c|timing.c) continue ;;
	esac
	MBED_SRC="$MBED_SRC $f"
done

# MBEDTLS_USER_CONFIG_FILE is included AFTER mbedTLS's own config, so our header
# only takes things away and the stock, upstream-tested configuration stands.
# shellcheck disable=SC2089,SC2090 # the escaped quotes around the config file
# name must survive into the compiler argv; unquoted expansion does no
# quote removal, so the macro arrives correctly. An array cannot be used:
# this also runs under Lion bash 3.2 where the calling style predates it.
MBED_FLAGS="-I$MBEDTLS/include -I$MBEDTLS/library -I$SRC -DMBEDTLS_USER_CONFIG_FILE=\"om_mbedtls_config.h\""

# Which Intel architectures. i386 is for the 2006 Core Solo and Core Duo Macs,
# the only Intel Macs with no 64-bit mode, and it is a correctness gap rather
# than a nicety: the game grew an i386 slice and so did the mod dylibs, so
# without this an owner of one of those machines could run Half-Life and could
# run every mod, but could not launch the app that installs them.
INSTALLER_INTEL_ARCHES="${OLDMAC_INSTALLER_ARCHES:-x86_64 i386}"

rm -rf "$BUILD"; mkdir -p "$BUILD/obj-ppc"

# One function rather than a copy per architecture. The three compile steps only
# ever differed by -arch, and when they were spelled out separately the i386 one
# would have been a fourth near-identical block to keep in step by hand.
build_intel_slice() {
	# TWO statements, not `local arch="$1" obj="$BUILD/obj-$arch"`. Lion's bash is
	# 3.2, which expands every word of a `local` command BEFORE performing any of
	# its assignments, so $arch is still unset while obj is being built and
	# `set -u` kills the run with "arch: unbound variable". Modern bash assigns
	# left to right and the one-liner works there, which is exactly why this has
	# to be remembered rather than discovered: it passes every check on the dev
	# box and fails on the only machine that runs it.
	local arch="$1"
	local obj="$BUILD/obj-$arch"
	mkdir -p "$obj"
	for f in $MBED_SRC; do
		# shellcheck disable=SC2090 # see the note at the MBED_FLAGS assignment
		clang -arch "$arch" -isysroot "$SDK_INTEL" -mmacosx-version-min=$INTEL_MIN -std=gnu99 \
			$MBED_FLAGS -O2 -c "$f" -o "$obj/$(basename "$f" .c).o"
	done
	for f in $ZLIB_SRC $LZMA_SRC; do
		clang -arch "$arch" -isysroot "$SDK_INTEL" -mmacosx-version-min=$INTEL_MIN -std=gnu99 \
			$ARCHIVE_FLAGS -O2 -c "$f" -o "$obj/$(basename "$f" .c).o"
	done
	clang -arch "$arch" -isysroot "$SDK_INTEL" -mmacosx-version-min=$INTEL_MIN \
		-framework Cocoa -framework Foundation \
		-Wall -Wno-deprecated-declarations -O2 -o "$BUILD/installer-$arch" \
		$SOURCES "$obj"/*.o -I"$SRC" -I"$MBEDTLS/include" $ARCHIVE_FLAGS
}

for a in $INSTALLER_INTEL_ARCHES; do
	echo "==> [1/4] compiling $a (clang, 10.7 SDK, floor $INTEL_MIN)"
	build_intel_slice "$a"
done

echo "==> [2/4] compiling ppc (gcc-4.0, 10.3.9 SDK)"
# -Wno-long-double: the 10.3.9 SDK headers still use it and gcc-4.0 warns loudly.
for f in $MBED_SRC; do
	# shellcheck disable=SC2090 # see the note at the MBED_FLAGS assignment
	gcc-4.0 -arch ppc -isysroot "$SDK_PPC" -mmacosx-version-min=10.3 -std=gnu99 \
		$MBED_FLAGS -Wno-long-double -O2 -c "$f" -o "$BUILD/obj-ppc/$(basename "$f" .c).o"
done
for f in $ZLIB_SRC $LZMA_SRC; do
	gcc-4.0 -arch ppc -isysroot "$SDK_PPC" -mmacosx-version-min=10.3 -std=gnu99 \
		$ARCHIVE_FLAGS -Wno-long-double -O2 -c "$f" -o "$BUILD/obj-ppc/$(basename "$f" .c).o"
done
gcc-4.0 -arch ppc -isysroot "$SDK_PPC" -mmacosx-version-min=10.3 \
	-framework Cocoa -framework Foundation \
	-Wall -Wno-long-double -O2 -o "$BUILD/installer-ppc" \
	$SOURCES "$BUILD"/obj-ppc/*.o -I"$SRC" -I"$MBEDTLS/include" $ARCHIVE_FLAGS

echo "==> [3/4] lipo"
# arm64 is OPTIONAL and comes from elsewhere, exactly as it does for the engine.
# Xcode 4.6 on Lion predates the architecture by seven years and cannot target
# it at all, so the slice is built on the Apple Silicon box by
# scripts/build-installer-arm64.sh and carried here by push-mod-arm64.sh.
# Without it the app still runs on Apple Silicon, under Rosetta 2 via the x86_64
# slice, so a missing slice is a downgrade and not a failure. Which is precisely
# why this SAYS which case it is: a four-slice and a five-slice app look
# identical until someone looks.
SLICES="$BUILD/installer-ppc"
for a in $INSTALLER_INTEL_ARCHES; do SLICES="$SLICES $BUILD/installer-$a"; done
ARM64_SLICE="$ROOT/dist/installer-arm64/installer"
if [ -f "$ARM64_SLICE" ]; then
	SLICES="$SLICES $ARM64_SLICE"
	echo "    arm64 slice present, fusing it in ($ARM64_SLICE)"
else
	echo "    NO arm64 slice; Apple Silicon will run this under Rosetta 2"
fi
lipo -create $SLICES -output "$BUILD/installer"
# Lion's lipo cannot NAME arm64 and prints its raw cputype, which is correct
# output and not an error. See docs/apple-silicon-arm64.md in old-mac-build-host.
lipo -info "$BUILD/installer"

# The floor is a claim until something reads it back off the Mach-O. Same reason
# as in build-lion.sh: a slice that quietly kept the build box's own version
# compiles, links, lipos and ships, and only fails on the one machine the floor
# was lowered for.
#
# Every Intel slice is checked, not just x86_64. Checking one and assuming the
# other is exactly the mistake that put a 10.7 mod dylib beside a 10.6 game.
# The ppc slice is not checked: it targets 10.3, which predates
# LC_VERSION_MIN_MACOSX, so it legitimately carries no such load command and
# there is nothing to read. The arm64 slice is not checked either, and cannot be:
# Lion's otool has no arm64 in its architecture table and refuses the flag. It is
# verified on the machine that built it instead.
for a in $INSTALLER_INTEL_ARCHES; do
	echo "==> verifying the $a floor"
	GOTMIN="$( otool -arch "$a" -l "$BUILD/installer" \
		| awk '/LC_VERSION_MIN_MACOSX/{g=1} g&&/^ *version /{print $2; exit}' )"
	if [ "$GOTMIN" != "$INTEL_MIN" ]; then
		echo "!! $a slice says version-min '${GOTMIN:-none}', wanted $INTEL_MIN" >&2
		exit 1
	fi
	# This app has no C++ at all, so any C++ runtime turning up means something was
	# linked that should not have been, and libc++ specifically does not exist below
	# 10.7.
	if otool -arch "$a" -L "$BUILD/installer" | grep -qE 'libc\+\+|libstdc\+\+'; then
		echo "!! $a slice links a C++ runtime; this app is pure Objective-C" >&2
		otool -arch "$a" -L "$BUILD/installer" >&2
		exit 1
	fi
	echo "    ok  $a version-min $INTEL_MIN, no C++ runtime"
done

echo "==> [4/4] assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BUILD/installer" "$OUT/Contents/MacOS/HalfLifeMods"
chmod +x "$OUT/Contents/MacOS/HalfLifeMods"

cp "$SRC/mods.map"      "$OUT/Contents/Resources/"
# Root certificates for https, the Mozilla set as published by curl.se. Shipped
# as a file, not compiled in, so a rotated CA can be fixed by replacing it rather
# than by cutting a new release. All six hosts we fetch from were verified
# against this exact file: files.runthinkshootlive.com, github.com,
# codeload.github.com, objects./raw.githubusercontent.com and archive.org.
cp "$SRC/ca-roots.pem"  "$OUT/Contents/Resources/"
# Per-mod download sources. Replaces the single-bundle sources.txt for the 18
# mods that have an automatable public source; see the file's own header for the
# seven that do not and why.
cp "$SRC/mod-sources.txt" "$OUT/Contents/Resources/"
[ -f "$SRC/manifests.txt" ] && cp "$SRC/manifests.txt" "$OUT/Contents/Resources/"
[ -d "$SRC/descriptions" ] && cp -R "$SRC/descriptions" "$OUT/Contents/Resources/"
# Mod preview art, 224x168 each, reconstructed offline by gen-mod-artwork.py. We
# ship it rather than read the mods' own game.tga because that file is a 16-64px
# Steam icon and only four mods have one at all.
[ -d "$SRC/artwork" ] && cp -R "$SRC/artwork" "$OUT/Contents/Resources/"

# About-window artwork. 300x400, scaled down from MacOSX/icon-source-gordon-*.png,
# which is 1086x1448 and far too big to have a G3 rescale on every open.
[ -f "$SRC/About-Gordon.png" ] && cp "$SRC/About-Gordon.png" "$OUT/Contents/Resources/"

# The app icon. Its own (gravity gun), not the game's (crowbar), so the two are
# told apart in the Dock and the Finder - they otherwise sit in the same folder.
# Optional: a missing icns just means the generic app icon, never a failed build.
ICON_SRC="$ROOT/MacOSX/Half-Life-Mods.icns"
ICONKEY=""
if [ -f "$ICON_SRC" ]; then
	cp "$ICON_SRC" "$OUT/Contents/Resources/Half-Life-Mods.icns"
	ICONKEY='	<key>CFBundleIconFile</key><string>Half-Life-Mods.icns</string>'
	echo "    icon: Half-Life-Mods.icns"
else
	echo "    icon: none ($ICON_SRC missing) - shipping the generic app icon"
fi

# the fat game dylibs, one folder per hlsdk branch
if [ -d "$MODS" ]; then
	mkdir -p "$OUT/Contents/Resources/mods"
	for d in "$MODS"/*/; do
		b="$(basename "$d")"
		case "$b" in _*) continue ;; esac
		[ -f "$d/server.dylib" ] || continue
		mkdir -p "$OUT/Contents/Resources/mods/$b"
		cp "$d/server.dylib" "$d/client.dylib" "$OUT/Contents/Resources/mods/$b/"
		[ -f "$d/mod.info" ] && cp "$d/mod.info" "$OUT/Contents/Resources/mods/$b/"
	done
	echo "    bundled $(ls "$OUT/Contents/Resources/mods" | wc -l | tr -d ' ') mod builds"
else
	echo "    WARNING: $MODS not found - app will ship with NO mod builds" >&2
fi

# Every branch mods.map names MUST have a build in the bundle. Without this the
# app ships happily with a mod whose game code is simply absent, and the failure
# only appears when someone tries to install that one.
#
# This is not hypothetical twice over. Xen Warrior shipped in v1.4.0 missing
# three of its four tables. And the build trees on the two Intel minis are hand
# managed rather than cloned (issue #39), so one can be a branch behind the other
# and nothing downstream notices: this check was added after a build on
# mini-intel2 silently produced 24 builds where mini-intel produced 25, because
# only one of them had ever built sohl1.2.
missing=""
while read -r gamedir branch rest; do
	case "${gamedir:-#}" in ''|'#'*) continue ;; esac
	[ -f "$OUT/Contents/Resources/mods/$branch/server.dylib" ] || missing="$missing $branch"
done < "$SRC/mods.map"
if [ -n "$missing" ]; then
	echo "ERROR: no build bundled for branch(es):$missing" >&2
	echo "       Run scripts/build-mod.sh for each on THIS host, then build again." >&2
	echo "       (The minis' dist/mods are not shared - see issue #39.)" >&2
	exit 1
fi

printf 'APPL????' > "$OUT/Contents/PkgInfo"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Half-Life Mods</string>
	<key>CFBundleDisplayName</key><string>Half-Life Mods</string>
	<key>CFBundleIdentifier</key><string>org.xash3d.halflife.mods</string>
	<key>CFBundleExecutable</key><string>HalfLifeMods</string>
$ICONKEY
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleSignature</key><string>????</string>
	<key>CFBundleVersion</key><string>$(tr -d ' \t\n' < "$ROOT/VERSION" 2>/dev/null || echo 1.0.0)</string>
	<key>CFBundleShortVersionString</key><string>$(tr -d ' \t\n' < "$ROOT/VERSION" 2>/dev/null || echo 1.0.0)</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>LSMinimumSystemVersion</key><string>10.3.9</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo
echo "== built $OUT =="
lipo -info "$OUT/Contents/MacOS/HalfLifeMods" | sed 's/^/   /'
du -sh "$OUT" | sed 's/^/   /'
