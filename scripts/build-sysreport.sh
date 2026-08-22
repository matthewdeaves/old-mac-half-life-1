#!/bin/bash
# build-sysreport.sh - build "Half-Life System Report.app", fat ppc + i386 + x86_64.
#
#   ./build-sysreport.sh [output.app]
#
# RUN THIS ON AN INTEL LION MINI, same as build-installer.sh, and for the same
# reasons: the old SDKs live at /Developer/SDKs there, and lipo fuses the result.
#
# WHAT IT IS FOR
#   The fat binary grades by CPU subtype and ignores the OS, so a machine can be
#   locked out by a combination nobody in the test fleet owns (GitHub issue #14).
#   This app reports what a Mac actually is, so those combinations can be found
#   out rather than guessed at. See GitHub issue #15.
#
#   It therefore has to run on machines where the GAME does not. That is the
#   whole point, and until v1.4.1 it was not true of the two Intel cases the
#   game rules out (GitHub issue #24): a 32-bit-only Core Solo or Core Duo had
#   no slice here either, and the x86_64 slice was stamped 10.7 like the game's.
#
# WHY EACH SLICE TARGETS WHAT IT DOES
#   The game's floors come from things this app does not have. Its Intel floor
#   is 10.6, where the engine's C++ runtime need bottoms out (docs/adr/0010);
#   this app is plain Objective-C against Cocoa and links no C++ standard
#   library at all. Its 64-bit
#   requirement came from HLSDK; this app is about 240 KB and has no such tie.
#   So it can go considerably lower, and the floors below are the oldest SDK on
#   the build minis that supports each architecture at all:
#
#     ppc     gcc-4.0, 10.3.9 SDK, min 10.3    every PowerPC Mac from Panther
#     i386    clang,   10.4u SDK,  min 10.4    Core Solo / Core Duo, 10.4 to 10.6
#     x86_64  clang,   10.5 SDK,   min 10.5    64-bit Intel from Leopard onward
#
#   10.5 is the first Mac OS X with x86_64 userland, and 10.4 the first with any
#   Intel support at all, so nothing is left uncovered below these.
#
#   ONE ppc slice, not several: a plain [ppc, i386, x86_64] fat is the ordinary
#   2006 universal-binary case and grades correctly on G3, G4, G5 and Intel
#   alike. The project's exact-cpusubtype rule is about fats carrying SEVERAL
#   PowerPC slices of differing subtype, which Tiger and Leopard mis-grade. This
#   is not that case.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/sysreport"
OUT="${1:-$ROOT/dist/Half-Life System Report.app}"
BUILD="$ROOT/dist/sysreport-build"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
XCBIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"
export PATH="$XCBIN:$DEVELOPER_DIR/usr/bin:$PATH"

SDK_PPC=/Developer/SDKs/MacOSX10.3.9.sdk
SDK_I386=/Developer/SDKs/MacOSX10.4u.sdk
SDK_X64=/Developer/SDKs/MacOSX10.5.sdk

[ -d "$SDK_PPC" ]  || { echo "ERROR: missing 10.3.9 SDK: $SDK_PPC" >&2; exit 1; }
[ -d "$SDK_I386" ] || { echo "ERROR: missing 10.4u SDK: $SDK_I386" >&2; exit 1; }
[ -d "$SDK_X64" ]  || { echo "ERROR: missing 10.5 SDK: $SDK_X64" >&2; exit 1; }

SOURCES="$SRC/main.m $SRC/SRController.m"

rm -rf "$BUILD"; mkdir -p "$BUILD"

echo "==> [1/5] compiling ppc (gcc-4.0, 10.3.9 SDK, min 10.3)"
# -Wno-long-double: the 10.3.9 SDK headers still use it and gcc-4.0 warns loudly.
# gcc-4.0 predates LC_VERSION_MIN_MACOSX, so this slice records no floor at all,
# which is also true of every PowerPC slice of the game itself.
gcc-4.0 -arch ppc -isysroot "$SDK_PPC" -mmacosx-version-min=10.3 \
	-framework Cocoa -framework Foundation -framework OpenGL \
	-Wall -Wno-long-double -O2 -o "$BUILD/sysreport-ppc" $SOURCES -I"$SRC"

echo "==> [2/5] compiling i386 (clang, 10.4u SDK, min 10.4)"
clang -arch i386 -isysroot "$SDK_I386" -mmacosx-version-min=10.4 \
	-framework Cocoa -framework Foundation -framework OpenGL \
	-Wall -Wno-deprecated-declarations -O2 -o "$BUILD/sysreport-i386" $SOURCES -I"$SRC"

echo "==> [3/5] compiling x86_64 (clang, 10.5 SDK, min 10.5)"
clang -arch x86_64 -isysroot "$SDK_X64" -mmacosx-version-min=10.5 \
	-framework Cocoa -framework Foundation -framework OpenGL \
	-Wall -Wno-deprecated-declarations -O2 -o "$BUILD/sysreport-x86_64" $SOURCES -I"$SRC"

echo "==> [4/5] lipo"
# arm64 is OPTIONAL and comes from elsewhere, as it does for the engine and the
# Mods app: Lion cannot target the architecture at all, so the slice is built by
# scripts/build-sysreport-arm64.sh on the Apple Silicon box and carried here by
# push-mod-arm64.sh. Without it the app still runs on Apple Silicon under
# Rosetta 2, and still reports the machine correctly, because SRController.m
# checks sysctl.proc_translated rather than believing the cputype it is handed.
# So a missing slice is a downgrade, not a fault, which is exactly why this says
# out loud which case it is.
SLICES="$BUILD/sysreport-ppc $BUILD/sysreport-i386 $BUILD/sysreport-x86_64"
ARM64_SLICE="$ROOT/dist/sysreport-arm64/sysreport"
if [ -f "$ARM64_SLICE" ]; then
	# Existence is not enough, for the same reason as the Mods app: this slice was
	# built on the dev box and carried here, nothing cleans it up, and a stale one
	# fuses silently. Issue #4, docs/adr/0015.
	. "$ROOT/scripts/arm64-stamp.sh"
	WANT_STAMP="$( oldmac_src_stamp $SOURCES "$SRC"/*.h )" || exit 1
	GOT_STAMP="$( cat "$ROOT/dist/sysreport-arm64/BUILD-STAMP" 2>/dev/null || true )"
	if [ "$GOT_STAMP" != "$WANT_STAMP" ]; then
		echo "!! the arm64 slice was NOT built from this sysreport/ source" >&2
		echo "   this build's source hashes to $WANT_STAMP" >&2
		echo "   the arm64 slice says            ${GOT_STAMP:-nothing (no BUILD-STAMP)}" >&2
		echo "   On the Apple Silicon box: scripts/build-sysreport-arm64.sh" >&2
		echo "   then                      scripts/push-mod-arm64.sh $(hostname -s)" >&2
		exit 1
	fi
	SLICES="$SLICES $ARM64_SLICE"
	echo "    arm64 slice present and built from this source ($WANT_STAMP), fusing it in"
else
	echo "    NO arm64 slice; Apple Silicon will run this under Rosetta 2"
fi
lipo -create $SLICES -output "$BUILD/sysreport"
# Lion's lipo cannot NAME arm64 and prints its raw cputype (16777228). That is
# correct output, not an error.
lipo -info "$BUILD/sysreport"

# Verify the floors landed, rather than trusting the flags. Lion's otool reads
# these old-style Mach-O slices correctly; it is only MODERN x86_64 objects it
# cannot parse.
for a in i386 x86_64; do
	v=$( otool -arch $a -l "$BUILD/sysreport" | awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/^ *version/{print $2; exit}' )
	echo "    $a LC_VERSION_MIN_MACOSX = ${v:-none}"
	case "$a:$v" in
		i386:10.4|x86_64:10.5) ;;
		*) echo "ERROR: $a slice has floor '${v:-none}', expected 10.4/10.5" >&2; exit 1 ;;
	esac
done

echo "==> [5/5] assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BUILD/sysreport" "$OUT/Contents/MacOS/HalfLifeSystemReport"
chmod +x "$OUT/Contents/MacOS/HalfLifeSystemReport"

# Its own icon. This used to share the game's, on the grounds that it is a
# companion rather than its own thing. That was the wrong call for the one app
# whose whole job is to be found and run when the game will NOT start: three
# bundles sit in the same folder and have to be tellable apart in the Dock and
# in a Finder window, and two of them looking identical is a problem precisely
# when the user is already stuck.
ICON_SRC="$ROOT/MacOSX/Half-Life-SysReport.icns"
ICONKEY=""
if [ -f "$ICON_SRC" ]; then
	cp "$ICON_SRC" "$OUT/Contents/Resources/Half-Life-SysReport.icns"
	ICONKEY='	<key>CFBundleIconFile</key><string>Half-Life-SysReport.icns</string>'
	echo "    icon: Half-Life-SysReport.icns"
else
	echo "    icon: none ($ICON_SRC missing) - shipping the generic app icon"
fi

# About-box artwork: the figure cut out of its black backdrop, so it sits on the
# window's grey rather than as a black rectangle pasted onto it. Regenerate with
# scripts/make-about-art.py, which prints the point size to use in showAbout:.
if [ -f "$SRC/About-Scientist.png" ]; then
	cp "$SRC/About-Scientist.png" "$OUT/Contents/Resources/About-Scientist.png"
	echo "    about art: About-Scientist.png"
else
	echo "    about art: none - the About window will show text only"
fi

printf 'APPL????' > "$OUT/Contents/PkgInfo"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Half-Life System Report</string>
	<key>CFBundleDisplayName</key><string>Half-Life System Report</string>
	<key>CFBundleIdentifier</key><string>org.xash3d.halflife.sysreport</string>
	<key>CFBundleExecutable</key><string>HalfLifeSystemReport</string>
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
lipo -info "$OUT/Contents/MacOS/HalfLifeSystemReport" | sed 's/^/   /'
du -sh "$OUT" | sed 's/^/   /'
