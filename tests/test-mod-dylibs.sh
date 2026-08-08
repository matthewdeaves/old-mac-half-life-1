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
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR="${1:-$ROOT/dist/mods}"

[ -d "$DIR" ] || { echo "!! no such directory: $DIR" >&2; exit 2; }

TMP="${TMPDIR:-/tmp}/modload.$$"
PROBE="$TMP.bin"
SRC="$TMP.c"

# C89 on purpose: this has to compile with gcc-4.0 on the 10.3.9 SDK as well as
# with a current clang, so no declarations after statements and no // comments.
cat > "$SRC" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main( int argc, char **argv )
{
	void *h;
	int i, bad = 0;
	h = dlopen( argv[1], RTLD_NOW | RTLD_LOCAL );
	if( !h )
	{
		printf( "DLOPEN FAILED: %s", dlerror() );
		return 1;
	}
	for( i = 2; i < argc; i++ )
	{
		if( !dlsym( h, argv[i] ) )
		{
			printf( "missing %s ", argv[i] );
			bad = 1;
		}
	}
	if( !bad ) printf( "ok" );
	return bad;
}
EOF

CC="${CC:-cc}"
if ! $CC -o "$PROBE" "$SRC" 2>"$TMP.log"; then
	echo "!! could not build the probe with $CC:" >&2
	cat "$TMP.log" >&2
	rm -f "$SRC" "$TMP.log"
	exit 2
fi

arch=$(uname -m)
echo "mod dylibs in $DIR, loaded as $arch"
echo

pass=0
fail=0
for d in "$DIR"/*/; do
	b=$(basename "$d")
	case "$b" in _*) continue ;; esac
	[ -f "$d/server.dylib" ] || continue

	for role in server client; do
		f="$d/$role.dylib"
		[ -f "$f" ] || { printf '  %-20s %-6s MISSING\n' "$b" "$role"; fail=$((fail+1)); continue; }
		case "$role" in
			server) syms="GiveFnptrsToDll GetEntityAPI" ;;
			client) syms="Initialize HUD_VidInit" ;;
		esac
		out=$( "$PROBE" "$f" $syms 2>&1 )
		if [ "$out" = "ok" ]; then
			pass=$((pass+1))
		else
			printf '  %-20s %-6s %s\n' "$b" "$role" "$out"
			fail=$((fail+1))
		fi
	done
done

rm -f "$SRC" "$PROBE" "$TMP.log"

echo
if [ "$fail" -eq 0 ]; then
	echo "$pass loaded, 0 failed ($arch)"
	exit 0
fi
echo "$pass loaded, $fail FAILED ($arch)" >&2
exit 1
