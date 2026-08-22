#!/bin/bash
# build-sysreport-arm64.sh - the System Report app's arm64 slice.
#
#   scripts/build-sysreport-arm64.sh
#
# RUN THIS ON THE APPLE SILICON BOX. Fourth of the "no mini can do this"
# drivers, beside build-arm64.sh (engine), build-mod-arm64.sh (mod dylibs) and
# build-installer-arm64.sh (the Mods app). Xcode 4.6 on Lion predates arm64 by
# seven years.
#
# Output: dist/sysreport-arm64/sysreport, a THIN arm64 Mach-O, fused on the mini
# by build-sysreport.sh once push-mod-arm64.sh has carried it over.
#
# WHY THIS APP GETS ONE TOO, WHICH IS NOT OBVIOUS
#   This is the one app in the project that would arguably be BETTER translated:
#   its whole job is to describe the machine, and SRController.m already detects
#   Rosetta 2 properly, checking sysctl.proc_translated and hw.optional.arm64
#   rather than believing the cputype it is handed. So it reports an Apple
#   Silicon Mac correctly either way, and that detection stays: it is what an
#   older copy of the app, or the x86_64 slice run deliberately, still needs.
#
#   It gets a native slice anyway because the rule for this project is that every
#   shipped app runs natively on every CPU the project supports, and a diagnostic
#   tool that cannot run natively on the machine it is diagnosing is a poor
#   advertisement for the claim. It also removes Rosetta 2, which is not a
#   permanent fixture of macOS, from the path of the tool you would reach for
#   when something else will not run.
#
# The floors differ per architecture ON PURPOSE and this one is no exception:
# the app is deliberately able to run lower than the game, so that a machine the
# game refuses can still say why. 11.0 is not a choice here though, it is simply
# where Apple Silicon starts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/sysreport"
BUILD="$ROOT/dist/sysreport-arm64-build"
OUT="$ROOT/dist/sysreport-arm64"

ARCH=arm64
ARM64_MIN="${OLDMAC_ARM64_MIN:-11.0}"

[ "$(uname -m)" = "arm64" ] || {
	echo "!! this must run on an Apple Silicon Mac; uname -m says $(uname -m)" >&2
	exit 1
}

SOURCES="$SRC/main.m $SRC/SRController.m"

rm -rf "$BUILD" "$OUT"; mkdir -p "$BUILD" "$OUT"

echo "==> compiling $ARCH (floor macOS $ARM64_MIN)"
# -framework OpenGL as on every other slice. OpenGL is deprecated on Apple
# Silicon and still present; the app uses it to name the renderer, which is one
# of the more useful things it reports, and there is no replacement that answers
# the same question on a 2003 machine.
clang -arch "$ARCH" -mmacosx-version-min="$ARM64_MIN" \
	-framework Cocoa -framework Foundation -framework OpenGL \
	-Wall -Wno-deprecated-declarations -O2 -o "$OUT/sysreport" $SOURCES -I"$SRC"

echo "==> verifying"
info="$(lipo -info "$OUT/sysreport" | sed 's/.*: //')"
[ "$info" = "$ARCH" ] || { echo "!! expected $ARCH, got '$info'" >&2; exit 1; }
vm="$(otool -l "$OUT/sysreport" | awk '/LC_BUILD_VERSION/{v=1} v&&/minos/{print $2; exit}')"
[ "$vm" = "$ARM64_MIN" ] || { echo "!! floor is '${vm:-none}', wanted $ARM64_MIN" >&2; exit 1; }
# Nothing outside the OS. The mini that fuses this cannot check it: its otool
# refuses a file containing arm64 outright, so it is checked here or not at all.
if otool -L "$OUT/sysreport" | tail -n +2 | grep -vqE '^\s+(/usr/lib|/System/)'; then
	echo "!! depends on something outside /usr and /System:" >&2
	otool -L "$OUT/sysreport" >&2
	exit 1
fi
echo "    ok  $ARCH, floor macOS $vm, no outside dependencies"

# --- build stamp -------------------------------------------------------------
# What this slice was built FROM, so build-sysreport.sh on the mini can refuse to
# fuse it once sysreport/ has moved on. Same reasoning as the Mods app; see
# scripts/arm64-stamp.sh and docs/adr/0015. Issue #4.
. "$ROOT/scripts/arm64-stamp.sh"
oldmac_src_stamp $SOURCES "$SRC"/*.h > "$OUT/BUILD-STAMP"
echo "    source stamp $( cat "$OUT/BUILD-STAMP" )"

echo
echo "Carry it to the build host with:"
echo "  scripts/push-mod-arm64.sh HOST"
