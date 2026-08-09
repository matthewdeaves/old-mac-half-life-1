#!/bin/sh
# test-mod-dylibs.sh - can this machine actually LOAD the mod game code?
#
#   tests/test-mod-dylibs.sh [dir]      default: dist/mods
#
# Run it anywhere, including on the old hardware. It tests THIS machine's slice
# of each fat dylib, because that is all dlopen will ever give you, which makes
# it a different test on every box: on a G3 it proves the ppc slice, on a Core
# Duo the i386 one, on Apple Silicon the arm64 one.
#
# WHY THIS IS WORTH HAVING ON TOP OF lipo
#   lipo answers "is there a slice for this architecture", which is the question
#   the build drivers already ask. It does not answer "will dyld accept it and is
#   the entry point the engine calls actually in there". Those come apart: a
#   dylib built at the wrong deployment floor, or against a library the target
#   does not have, contains a perfectly good slice for the right CPU and still
#   fails at load. That is exactly the shape of the fault that shipped mod dylibs
#   at version-min 10.7 beside a 10.6 game, where every slice was present and
#   correct and no mod would load on 10.6.
#
# The symbols are the ones the engine looks up by name after dlopen: server-side
# GiveFnptrsToDll and GetEntityAPI, client-side Initialize and HUD_VidInit. A
# missing one means the dylib loaded but is not game code the engine can drive.
#
# THE PROBE, AND THE MACHINES THAT CANNOT COMPILE ONE
#   A stock Panther or Tiger install has no /Developer, so there is no compiler
#   on the two oldest boxes in the fleet - the ones whose ppc slice this test
#   exists to check. Build a fat probe once with tests/make-probe.sh, carry it
#   over, and point OLDMAC_PROBE at it.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR="${1:-$ROOT/dist/mods}"

[ -d "$DIR" ] || { echo "!! no such directory: $DIR" >&2; exit 2; }

TMP="${TMPDIR:-/tmp}/modload.$$"
SRC="$ROOT/tests/modprobe.c"
BUILT=""

if [ -n "${OLDMAC_PROBE:-}" ]; then
	[ -x "$OLDMAC_PROBE" ] || { echo "!! OLDMAC_PROBE is not executable: $OLDMAC_PROBE" >&2; exit 2; }
	PROBE="$OLDMAC_PROBE"
elif [ -x "$ROOT/dist/modprobe" ]; then
	PROBE="$ROOT/dist/modprobe"
else
	[ -f "$SRC" ] || { echo "!! missing $SRC" >&2; exit 2; }
	CC="${CC:-cc}"
	if ! command -v "$CC" >/dev/null 2>&1; then
		echo "!! no compiler on this machine ($CC not found), and no prebuilt probe." >&2
		echo "   Build one on the Lion mini with tests/make-probe.sh, copy it here," >&2
		echo "   then re-run with OLDMAC_PROBE=/path/to/modprobe." >&2
		exit 2
	fi
	PROBE="$TMP.bin"
	BUILT="$PROBE"
	if ! $CC -o "$PROBE" "$SRC" 2>"$TMP.log"; then
		echo "!! could not build the probe with $CC:" >&2
		cat "$TMP.log" >&2
		rm -f "$TMP.log"
		exit 2
	fi
fi

arch=$(uname -m)
echo "mod dylibs in $DIR, loaded as $arch"
echo "probe: $PROBE"
echo

pass=0
fail=0
seen=0
for d in "$DIR"/*/; do
	b=$(basename "$d")
	case "$b" in _*) continue ;; esac

	# TWO LAYOUTS, and both matter.
	#   build      <mod>/server.dylib and <mod>/client.dylib, what build-mod.sh
	#              emits and what the installer packs
	#   installed  <mod>/dlls/<whatever liblist.gam names>.dylib and
	#              <mod>/cl_dlls/client.dylib, what a player actually has
	# Testing only the first would mean this could never run against a real
	# installed game, which is the only place a deployment fault shows up.
	if [ -f "$d/server.dylib" ]; then
		SRV="$d/server.dylib"
		CLI="$d/client.dylib"
	else
		SRV=$( ls "$d"dlls/*.dylib 2>/dev/null | head -1 )
		CLI="$d/cl_dlls/client.dylib"
		[ -n "$SRV" ] || continue
	fi
	seen=$((seen+1))

	for role in server client; do
		case "$role" in
			server) f="$SRV"; syms="GiveFnptrsToDll GetEntityAPI" ;;
			client) f="$CLI"; syms="Initialize HUD_VidInit" ;;
		esac
		[ -f "$f" ] || { printf '  %-20s %-6s MISSING\n' "$b" "$role"; fail=$((fail+1)); continue; }
		out=$( "$PROBE" "$f" $syms 2>&1 )
		if [ "$out" = "ok" ]; then
			pass=$((pass+1))
		else
			# dyld lists every path it tried, which is the same failure repeated
			# six times and hundreds of characters wide. The first one carries the
			# whole diagnosis - "have 'x86_64,ppc', need 'arm64'" - so keep that
			# and drop the rest. OLDMAC_VERBOSE=1 for the untouched text.
			[ -n "${OLDMAC_VERBOSE:-}" ] || out=$( printf '%s' "$out" | sed "s/)), '.*/))/" )
			printf '  %-20s %-6s %s\n' "$b" "$role" "$out"
			fail=$((fail+1))
		fi
	done
done

rm -f "$BUILT" "$TMP.log"

echo
if [ "$seen" -eq 0 ]; then
	echo "!! no mod found under $DIR in either layout" >&2
	exit 2
fi
if [ "$fail" -eq 0 ]; then
	echo "$pass loaded, 0 failed ($arch), $seen mods"
	exit 0
fi
echo "$pass loaded, $fail FAILED ($arch)" >&2
exit 1
