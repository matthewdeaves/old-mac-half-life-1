#!/bin/sh
# make-probe.sh - build the dlopen probe as a fat binary, so the test can run on
# a machine that has no compiler.
#
#   tests/make-probe.sh                 writes dist/modprobe, run it on the Lion mini
#
# WHY THIS EXISTS
#   tests/test-mod-dylibs.sh compiles its probe on the spot, which is fine on a
#   build box and impossible on most of the fleet: a stock Panther or Tiger
#   install has no /Developer at all, and those are precisely the machines whose
#   ppc slice most needs testing. The G3 on 10.3.9 could not run the test.
#
#   So build the probe once on a box that has the toolchain, and carry it over.
#   It is a test tool and is never shipped, so it lives in dist/ and nowhere else.
#
# WHY THERE IS NO arm64 SLICE HERE
#   The probe only ever runs on the machine under test, and the only machines
#   that need a prebuilt one are the ones with no compiler. Every one of those is
#   PowerPC or Intel; anything that can execute arm64 is running a macOS with
#   clang in it, where the test builds its own probe in a second. Leaving arm64
#   out also keeps this buildable entirely on the Lion mini, in one run.
#
# The ppc slice is deliberately GENERIC ppc rather than ppc750 plus ppc7400. That
# is the same choice the mod dylibs make: with no 7400 slice beside it there is
# nothing for a G3 to grade wrongly, and one slice covers every PowerPC here.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/tests/modprobe.c"
OUT="$ROOT/dist/modprobe"
TMP="${TMPDIR:-/tmp}/modprobe.$$"

[ -f "$SRC" ] || { echo "!! missing $SRC" >&2; exit 2; }
mkdir -p "$ROOT/dist" "$TMP"

# The same two toolchain roots scripts/build-ppc-panther.sh and
# scripts/build-lion.sh use. Lion's /usr/bin/clang is a stale 1.7 stub, so the
# Intel slices have to come from Xcode's toolchain, not from PATH.
PPC_SDK=/Developer/SDKs/MacOSX10.3.9.sdk
DEV=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
LION_SDK="$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.7.sdk"
XCLANG="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"

built=""

# try_slice <name> <compiler> <flag ...>
try_slice()
{
	name=$1; shift
	cc=$1; shift
	command -v "$cc" >/dev/null 2>&1 || { echo "   no $cc, skipping $name"; return 0; }
	if $cc -o "$TMP/$name" "$@" "$SRC" 2>"$TMP/$name.log"; then
		echo "   built $name"
		built="$built $TMP/$name"
	else
		echo "   FAILED $name"
		sed 's/^/     /' "$TMP/$name.log" | head -4
	fi
}

echo "building the probe from $SRC"

# PowerPC, floor 10.3, exactly as scripts/build-ppc-panther.sh targets it.
if [ -d "$PPC_SDK" ]; then
	try_slice ppc gcc-4.0 -arch ppc -isysroot "$PPC_SDK" -mmacosx-version-min=10.3
else
	echo "   no $PPC_SDK, skipping ppc"
fi

# Intel, floor 10.6, matching the game's own floor (docs/adr/0010). i386 covers
# the 2006 Core Solo and Core Duo, which have no 64-bit mode at all.
if [ -d "$LION_SDK" ]; then
	CLANG="$XCLANG"
	[ -x "$CLANG" ] || CLANG=clang
	try_slice i386   "$CLANG" -arch i386   -isysroot "$LION_SDK" -mmacosx-version-min=10.6
	try_slice x86_64 "$CLANG" -arch x86_64 -isysroot "$LION_SDK" -mmacosx-version-min=10.6
else
	echo "   no $LION_SDK, skipping i386 and x86_64"
fi

[ -n "$built" ] || { echo "!! no slice could be built on this machine" >&2; rm -rf "$TMP"; exit 1; }

# shellcheck disable=SC2086
lipo -create $built -output "$OUT"
chmod 755 "$OUT"
rm -rf "$TMP"

echo
echo "wrote $OUT"
lipo -info "$OUT"
echo
echo "carry it to a machine with no compiler, then:"
echo "    OLDMAC_PROBE=/tmp/modprobe tests/test-mod-dylibs.sh <dir>"
