#!/bin/bash
# fuse-mod-arm64.sh - add the arm64 slice to the finished mod dylibs.
#
#   scripts/fuse-mod-arm64.sh [--check]
#
# Runs on the BUILD HOST, after the arm64 slices have been carried over with
# scripts/push-mod-arm64.sh. build-mod.sh calls this itself at the end of a run,
# so a normal full build needs nothing extra; it is a separate script so that the
# same code also retro-fits mods that were built before their arm64 slice
# existed, without rebuilding them.
#
#   dist/mods-arm64/<branch>/{server,client}.dylib   thin, from the Apple Silicon box
#   dist/mods/<branch>/{server,client}.dylib         the fat the installer ships
#
# WHY THIS CAN RUN ON LION AT ALL
#   lipo copies slices around without reading their load commands, so Xcode 4's
#   lipo fuses an architecture from 2020 quite happily. It only fails to NAME it,
#   printing `cputype (16777228)`. otool and install_name_tool do parse load
#   commands and choke on the whole file, which is why nothing here uses them.
#   Measured on mini-intel2, 2026-08-08.
#
# IDEMPOTENT ON PURPOSE. A dylib that already carries arm64 is left alone rather
# than re-fused, because `lipo -create` on an input that already has the slice
# fails with a duplicate-architecture error, and a script you cannot safely run
# twice is a script that gets run once and then skipped when it matters.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODS="$ROOT/dist/mods"
ARM="$ROOT/dist/mods-arm64"
MODE="${1:-}"

# Lion's /usr/bin/lipo is a stale stub. The Xcode copy has to win, same ordering
# as every other driver here.
XCBIN=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
[ -d "$XCBIN" ] && export PATH="$XCBIN:$PATH"

[ -d "$MODS" ] || { echo "!! no $MODS - nothing to fuse" >&2; exit 1; }
if [ ! -d "$ARM" ]; then
	echo "!! no $ARM"
	echo "   The arm64 mod slices are built on the Apple Silicon box, because no"
	echo "   mini can target arm64 at all. From the workstation:"
	echo "     scripts/build-mod-arm64.sh --all"
	echo "     scripts/push-mod-arm64.sh HOST   (this box's ssh alias)"
	exit 1
fi

# 16777228 is arm64's cputype (CPU_TYPE_ARM | CPU_ARCH_ABI64). Lion's lipo prints
# the number because the architecture is not in its table; a modern lipo prints
# the name. Accept either, so this reads the same answer on both.
has_arm64 () {
	lipo -info "$1" 2>/dev/null | grep -qE 'arm64|16777228'
}

fused=0; already=0; missing=""; bad=0

for d in "$MODS"/*/; do
	b="$(basename "$d")"
	case "$b" in _*) continue ;; esac
	[ -f "$d/server.dylib" ] || continue

	if [ ! -f "$ARM/$b/server.dylib" ] || [ ! -f "$ARM/$b/client.dylib" ]; then
		missing="$missing $b"
		continue
	fi

	for role in server client; do
		fat="$d/$role.dylib"
		thin="$ARM/$b/$role.dylib"
		if has_arm64 "$fat"; then
			already=$((already + 1))
			continue
		fi
		# Write to a temp and move into place, so an interrupted fuse cannot leave
		# a half-written dylib where a good one was.
		if ! lipo -create "$fat" "$thin" -output "$fat.new"; then
			echo "  !! $b/$role: lipo failed" >&2; rm -f "$fat.new"; bad=1; continue
		fi
		if ! has_arm64 "$fat.new"; then
			echo "  !! $b/$role: fused file still has no arm64 slice" >&2
			rm -f "$fat.new"; bad=1; continue
		fi
		mv "$fat.new" "$fat"
		fused=$((fused + 1))
	done
done

echo
echo "arm64 fused into $fused dylibs, $already already had it"
if [ -n "$missing" ]; then
	echo "NO arm64 slice for:$missing"
	echo "  those mods will ship without one, and run under Rosetta 2 on Apple Silicon"
fi
[ "$bad" -eq 0 ] || { echo "!! at least one fuse failed" >&2; exit 1; }

# Say what actually came out, per mod. The whole point of this file is that a
# four-slice and a five-slice dylib look identical until someone looks.
if [ "$MODE" = "--check" ] || [ "$fused" -gt 0 ]; then
	echo
	for d in "$MODS"/*/; do
		b="$(basename "$d")"
		[ -f "$d/server.dylib" ] || continue
		printf '  %-20s %s\n' "$b" "$(lipo -info "$d/server.dylib" | sed 's/.*: //')"
	done
fi
