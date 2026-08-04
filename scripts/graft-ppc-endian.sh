#!/bin/bash
# graft-ppc-endian.sh - make an hlsdk-portable checkout build correct game code
# for big-endian PowerPC, whatever vintage of mainline the branch carries.
#
#   ./graft-ppc-endian.sh <hlsdk-tree>
#
# WHY THIS IS CAPABILITY-BASED, NOT A FLAT PATCH
# ----------------------------------------------
[removed]
# so the obvious plan was "carry the fork's delta and graft it onto each mod
# branch". That is now mostly WRONG: FWGS/hlsdk-portable master has since
# absorbed the endian work, and did it better - the save/restore path swaps
# centrally in CSave::BufferData() via a new `typesize` parameter instead of at
# every call site, and dlls/nodes.cpp + dlls/nodes_compat.h are fully handled.
# Verified on the `bshift` branch: pristine HEAD already has 6 ULittleToHostSW in
# dlls/util.cpp and 56 endian ops in dlls/nodes.cpp.
#
# Blindly applying the old fork diff to such a branch produces conflicts in 4 of
# 6 files - not because the MOD touched them, but because mainline moved. So we
# detect what the branch already has:
#
#   MODERN branch (has upstream endian support)
#     -> only cl_dll/StudioModelRenderer.cpp still needs fixing, and it needs it
#        in two separate places. patch-hlsdk-studio-endian.py does both:
#          - animation VALUES are read with Unaligned(), which corrects alignment
#            but does not byteswap; those become ULittleToHost().
#          - animation OFFSETS from an EXTERNAL sequence group are never swapped
#            by anyone, because the client reimplements StudioGetAnim and so never
#            reaches the engine's swapping copy. That one segfaults rather than
#            just animating badly. Offsets from sequence group 0 must be left
#            alone: the engine already swapped those in R_StudioLoadHeader.
#
#   LEGACY branch (predates upstream's endian work)
#     -> apply the full 6-file fork graft, plus the Little* helpers the fork's
#        code expects (its own common/byteswap.h, which mainline later replaced
#        with an incompatible API, hence the separate compat header).
#
# Idempotent: re-running on an already-grafted tree is a no-op.
set -euo pipefail

TREE="${1:?usage: graft-ppc-endian.sh <hlsdk-tree>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEGACY_DIFF="$ROOT/patches/ppc-hlsdk-big-endian-legacy.diff"
COMPAT="$ROOT/patches/ppc-hlsdk-byteswap-compat.h"

[ -d "$TREE/.git" ] || { echo "ERROR: not a git checkout: $TREE" >&2; exit 1; }
TREE="$(cd "$TREE" && pwd)"
BSWAP="$TREE/common/byteswap.h"

# The Lion build minis have python 2.7 as `python` and no `python3`; a modern Mac
# (where this is often dry-run) has only `python3`. Support both.
if command -v python >/dev/null 2>&1; then
	PY=python
elif command -v python3 >/dev/null 2>&1; then
	PY=python3
else
	echo "ERROR: no python interpreter found" >&2
	exit 1
fi

# --- which vintage is this branch? -------------------------------------------
# ULittleToHostSW in dlls/util.cpp is upstream's save/restore swap; its presence
# means mainline's endian work is in this branch.
if grep -q 'ULittleToHostSW' "$TREE/dlls/util.cpp" 2>/dev/null; then
	VINTAGE=modern
else
	VINTAGE=legacy
fi
echo "==> $TREE"
echo "    endian vintage: $VINTAGE"

if [ "$VINTAGE" = modern ]; then
	# ---- modern: only the studio renderer is missing a swap -----------------
	"$PY" "$ROOT/scripts/patch-hlsdk-studio-endian.py" "$TREE" | sed 's/^/    /'
else
	# ---- legacy: full fork graft --------------------------------------------
	[ -f "$LEGACY_DIFF" ] || { echo "ERROR: missing $LEGACY_DIFF" >&2; exit 1; }
	[ -f "$COMPAT" ]      || { echo "ERROR: missing $COMPAT" >&2; exit 1; }

	if grep -q 'LittleLongSW' "$TREE/dlls/util.cpp" 2>/dev/null; then
		echo "    legacy graft already applied"
	else
		# The fork's code calls LittleLong/LittleShort/LittleFloat, which live in a
		# common/byteswap.h it CREATED. Mainline later added its own byteswap.h with a
		# different API and none of those helpers, so we extend rather than create.
		if [ ! -f "$BSWAP" ]; then
			echo "    common/byteswap.h absent - creating it"
			mkdir -p "$TREE/common"
			{
				echo '#ifndef BYTESWAP_H'
				echo '#define BYTESWAP_H'
				echo ''
				cat "$COMPAT"
				echo ''
				echo '#endif // BYTESWAP_H'
			} > "$BSWAP"
		elif grep -q 'define LittleLong' "$BSWAP"; then
			echo "    common/byteswap.h already provides the Little* helpers"
		else
			echo "    extending common/byteswap.h with the Little* helpers"
			printf '\n' >> "$BSWAP"
			cat "$COMPAT" >> "$BSWAP"
		fi

		echo "    applying $(basename "$LEGACY_DIFF") (3-way)"
		if ( cd "$TREE" && git apply --3way --whitespace=nowarn "$LEGACY_DIFF" ); then
			echo "    legacy graft applied cleanly"
		else
			echo >&2
			echo "!! LEGACY GRAFT CONFLICTED in $TREE" >&2
			echo "   Resolve the conflict markers by hand, then capture the result so the" >&2
			echo "   tree stays reproducible:" >&2
			echo >&2
			echo "     ( cd '$TREE' && git diff ) > $ROOT/patches/mods/<branch>.endian.diff" >&2
			echo >&2
			echo "   Conflicted files:" >&2
			( cd "$TREE" && git diff --name-only --diff-filter=U ) | sed 's/^/     /' >&2
			exit 1
		fi
	fi
fi

# --- verify, do not trust ------------------------------------------------------
# A silently no-op graft yields a PPC dylib that loads and then mangles every save
# game and animation, so check the markers are really there.
# Each pattern must match BOTH vintages: modern uses LittleToHost/ULittleToHost/
# Byteswap*, legacy uses LittleShort/LittleLong. Note 'LittleToHost' also matches
# 'ULittleToHost' as a substring, which is intended.
fail=0
grep -q 'LittleToHost\|LittleShort' "$TREE/cl_dll/StudioModelRenderer.cpp" \
	|| { echo "ERROR: no endian swap in cl_dll/StudioModelRenderer.cpp" >&2; fail=1; }
grep -q 'LittleToHostSW\|LittleLongSW' "$TREE/dlls/util.cpp" \
	|| { echo "ERROR: no save/restore endian swap in dlls/util.cpp" >&2; fail=1; }
grep -q 'LittleToHost\|Byteswap\|LittleLong' "$TREE/dlls/nodes.cpp" \
	|| { echo "ERROR: no node-graph endian swap in dlls/nodes.cpp" >&2; fail=1; }
[ "$fail" -eq 0 ] || exit 1

echo "    endian support verified"
