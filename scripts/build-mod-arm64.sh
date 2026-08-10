#!/bin/bash
# build-mod-arm64.sh - the ONE mod slice no build mini can produce.
#
#   scripts/build-mod-arm64.sh <hlsdk-branch> [<hlsdk-branch> ...]
#   scripts/build-mod-arm64.sh --all
#
# RUN THIS ON THE APPLE SILICON BOX, not on a mini. Xcode 4.6 on Lion predates
# arm64 by seven years; there is no flag, no SDK and no toolchain that makes a
# 2011 machine emit ARM64 code. Exactly the same reason scripts/build-arm64.sh
# exists for the engine, and this is its counterpart for the 25 mod dylib pairs.
#
# WHAT IT PRODUCES
#   dist/mods-arm64/<branch>/server.dylib   THIN arm64
#   dist/mods-arm64/<branch>/client.dylib   THIN arm64
#
# Thin, deliberately. The fuse belongs in ONE place, and that place is
# build-mod.sh on the mini, which already lipos x86_64 + i386 + ppc and can
# fuse an arm64 slice perfectly well (Lion's lipo copies slices without reading
# their load commands, which is why it survives an architecture from 2020; it
# only fails to NAME it). Carry these over with scripts/push-mod-arm64.sh.
#
# WHICH PATCHES APPLY HERE, AND WHICH MUST NOT
#   The two audit patch scripts DO run: patch-hlsdk-shared-clientbugs.py and
#   patch-hlsdk-mod-bugs.py fix arch-neutral bugs (unbounded sprintf, missing
#   null checks, wrong save-field types), so an arm64 slice built without them
#   would carry faults every other slice of the same mod has had fixed.
#   The three ppc scripts do NOT run: xcompile/darwin/gcc4 exist to make gcc-4.0
#   and Apple's ld agree about a cross build, and none of that applies to clang
#   on Apple Silicon. See docs/MOD-AUDIT.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODSRC="$ROOT/vendor/hlsdk-mods"
DIST="$ROOT/dist/mods-arm64"
LOGS="$DIST/_logs"
# shellcheck disable=SC2034 # never passed to the compiler, and that is the
# point: the comment at the -isystem site below explains why this slice must
# NOT see compat-include. The variable stays so that comment names a real path.
SHIM="$ROOT/compat-include"

ARCH=arm64
# 11.0 is not a choice so much as a fact: Apple Silicon shipped with Big Sur, so
# there is no older macOS for an arm64 slice to run on. Same floor as the engine.
ARM64_MIN="${OLDMAC_ARM64_MIN:-11.0}"

[ "$(uname -m)" = "arm64" ] || {
	echo "!! this must run on an Apple Silicon Mac; uname -m says $(uname -m)" >&2
	exit 1
}

# Same single source of truth as build-mod.sh: a mod listed in one and not the
# other is a build nothing installs, or an install with no build.
MODMAP="$ROOT/installer/mods.map"
all_branches() {
	[ -f "$MODMAP" ] || { echo "ERROR: missing $MODMAP" >&2; return 1; }
	awk '!/^[[:space:]]*#/ && NF >= 3 { print $2 }' "$MODMAP"
}

MIRROR="${HLSDK_MIRROR:-$ROOT/vendor/hlsdk-portable-mirror.git}"
if [ -d "$MIRROR" ]; then
	UPSTREAM="$MIRROR"; echo "source: local mirror $MIRROR"
else
	UPSTREAM="https://github.com/FWGS/hlsdk-portable.git"; echo "source: $UPSTREAM"
fi

PY=python3

usage() { sed -n '2,6p' "$0"; exit 2; }
[ $# -gt 0 ] || usage
if [ "$1" = "--all" ]; then
	# Capture first, then check. `set -- $(f) || exit` binds the || to `set`,
	# whose status is always 0, so a failure is discarded and $@ silently empties.
	branches="$( all_branches )" || exit 1
	[ -n "$branches" ] || { echo "ERROR: no branches read from $MODMAP" >&2; exit 1; }
	set -- $branches
fi

mkdir -p "$MODSRC" "$DIST" "$LOGS"

mod_option() {
	local tree="$1" key="$2" val
	val="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\([^#]*\).*/\1/p" \
		"$tree/mod_options.txt" 2>/dev/null | head -1)"
	printf '%s' "$val" | sed 's/[[:space:]]*$//'
}

prepare_tree() {
	local tree="$1" branch="$2"
	if [ -d "$tree/.git" ]; then
		echo "    refreshing $(basename "$tree")"
		git -C "$tree" fetch --quiet origin "$branch"
		git -C "$tree" checkout --quiet -B "$branch" FETCH_HEAD
		git -C "$tree" reset --hard --quiet FETCH_HEAD
		git -C "$tree" clean -qfdx
	else
		echo "    cloning $branch -> $(basename "$tree")"
		# Not --recursive: hlsdk's only submodule is vgui_support, opt-in via
		# --enable-vgui, which we never enable.
		git clone --quiet --branch "$branch" --single-branch "$UPSTREAM" "$tree"
	fi
}

# waf exits 0 on a FAILED task and then installs STALE objects from a previous
# run. The log, the mtimes and lipo are the only evidence. Same three checks as
# build-mod.sh; see .claude/rules/build-verification.md.
verify_build() {
	local dest="$1" gamedir="$2" started="$3" label="$4" log="$5"
	local bad=0 f mt found=0

	if grep -qE 'Build failed|task in .* failed' "$log"; then
		echo "    !! '$label': waf reported a FAILED task (grep 'Build failed' $log)" >&2
		bad=1
	fi
	if grep -q ' error: ' "$log"; then
		echo "    !! '$label': compiler errors in $log" >&2
		bad=1
	fi
	for f in "$dest/$gamedir"/dlls/*.dylib "$dest/$gamedir"/cl_dlls/*.dylib; do
		[ -e "$f" ] || continue
		found=$((found + 1))
		mt=$(stat -f %m "$f")
		if [ "$mt" -lt "$started" ]; then
			echo "    !! '$label': STALE artifact (older than this build): $f" >&2
			bad=1
		fi
	done
	if [ "$found" -lt 2 ]; then
		echo "    !! '$label': expected a server + client dylib, found $found" >&2
		bad=1
	fi
	[ "$bad" -eq 0 ] || return 1
	return 0
}

# -arch goes in CC and CXX, not only in CFLAGS. waf probes the target CPU by
# compiling with the BARE compiler and never sees CFLAGS, and DEST_CPU is what
# names the output dylib. Get this wrong and the file lands as hl_amd64.dylib on
# an ARM machine, which the engine will never dlopen.
build_arm64() {
	local tree="$1" dest="$2" log="$3"
	(
		export CC="clang -arch $ARCH"
		export CXX="clang++ -arch $ARCH"
		local af="-arch $ARCH -mmacosx-version-min=$ARM64_MIN"
		export CFLAGS="$af"
		# NO -isystem $SHIM here, unlike every other slice, and this is load-bearing.
		# compat-include/ supplies <cstdint> and <cinttypes> to header sets that
		# predate C++11 and genuinely lack them. Current libc++ has both, and
		# -isystem puts our copies AHEAD of it, so the shim shadows the real header
		# rather than filling a gap: ours declares the fixed-width types in the
		# global namespace only, libc++ internals want std::intmax_t, and
		# <__type_traits/is_trivially_copyable.h> fails to compile. Measured, not
		# reasoned: adding the path was the whole difference between this branch
		# building and not.
		export CXXFLAGS="$af -stdlib=libc++"
		export LINKFLAGS="$af -stdlib=libc++"
		export LDFLAGS="$af -stdlib=libc++"
		export MACOSX_DEPLOYMENT_TARGET="$ARM64_MIN"
		cd "$tree"
		rm -rf build-arm64
		"$PY" waf --out=build-arm64 configure --disable-werror
		"$PY" waf --out=build-arm64 build -j"$(sysctl -n hw.ncpu)"
		rm -rf "$dest"
		"$PY" waf --out=build-arm64 install --destdir="$dest"
	) >"$log" 2>&1
}

failed=""
built=""

for branch in "$@"; do
	echo "================================================================"
	echo "== $branch"
	echo "================================================================"

	tree="$MODSRC/$branch-arm64"
	dest="$MODSRC/_install/$branch-arm64"
	log="$LOGS/$branch-arm64.log"

	if ! prepare_tree "$tree" "$branch"; then
		echo "  !! checkout failed" >&2; failed="$failed $branch"; continue
	fi

	gamedir="$(mod_option "$tree" GAMEDIR)"
	svname="$(mod_option "$tree" SERVER_LIBRARY_NAME)"
	svdir="$(mod_option "$tree" SERVER_INSTALL_DIR)";  svdir="${svdir:-dlls}"
	cldir="$(mod_option "$tree" CLIENT_INSTALL_DIR)";  cldir="${cldir:-cl_dlls}"
	if [ -z "$gamedir" ] || [ -z "$svname" ]; then
		echo "  !! cannot read GAMEDIR/SERVER_LIBRARY_NAME from mod_options.txt" >&2
		failed="$failed $branch"; continue
	fi
	echo "  gamedir=$gamedir  server=$svname  ($svdir/, $cldir/)"

	if ! "$PY" "$ROOT/scripts/patch-hlsdk-shared-clientbugs.py" "$tree" | sed 's/^/  /'; then
		echo "  !! shared client fixes failed" >&2; failed="$failed $branch"; continue
	fi
	if ! "$PY" "$ROOT/scripts/patch-hlsdk-mod-bugs.py" "$branch" "$tree" | sed 's/^/  /'; then
		echo "  !! per-mod audit fixes failed" >&2; failed="$failed $branch"; continue
	fi

	started=$(date +%s)
	echo "  [arm64] building ..."
	if ! build_arm64 "$tree" "$dest" "$log"; then
		echo "  !! arm64 build failed - see $log" >&2; failed="$failed $branch"; continue
	fi
	if ! verify_build "$dest" "$gamedir" "$started" "$branch/arm64" "$log"; then
		failed="$failed $branch"; continue
	fi

	# Glob rather than assume the suffix. waf derives it from library_naming.py,
	# and hardcoding it would break silently if that changes.
	f_sv=$(ls "$dest/$gamedir/$svdir"/*.dylib 2>/dev/null | head -1)
	f_cl=$(ls "$dest/$gamedir/$cldir"/*.dylib 2>/dev/null | head -1)
	if [ -z "$f_sv" ] || [ -z "$f_cl" ]; then
		echo "  !! missing a dylib (server='$f_sv' client='$f_cl')" >&2
		failed="$failed $branch"; continue
	fi

	out="$DIST/$branch"
	rm -rf "$out"; mkdir -p "$out"
	cp "$f_sv" "$out/server.dylib"
	cp "$f_cl" "$out/client.dylib"

	# Prove it, rather than trusting the flags. Both the architecture and the
	# floor: a slice that came out at the wrong floor still lipos happily and
	# only fails on the machine that cannot run it.
	bad=0
	for f in "$out/server.dylib" "$out/client.dylib"; do
		info=$(lipo -info "$f" | sed 's/.*: //')
		[ "$info" = "$ARCH" ] || { echo "    !! ${f#$DIST/}: expected $ARCH, got '$info'" >&2; bad=1; }
		vm=$(otool -l "$f" | awk '/LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX/{v=1} v&&/minos|version/{print $2; exit}')
		[ "$vm" = "$ARM64_MIN" ] || { echo "    !! ${f#$DIST/}: floor '${vm:-none}', wanted $ARM64_MIN" >&2; bad=1; }
		[ "$bad" -eq 0 ] && echo "    ok: ${f#$DIST/} - $ARCH, floor macOS $vm"
	done
	if [ "$bad" -ne 0 ]; then failed="$failed $branch"; continue; fi

	{
		echo "branch=$branch"
		echo "gamedir=$gamedir"
		echo "arch=$ARCH"
		echo "min=$ARM64_MIN"
		echo "built=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "commit=$( git -C "$tree" rev-parse HEAD )"
	} > "$out/arm64.info"

	built="$built $branch"
done

echo
echo "================================================================"
echo "built:  ${built:-<none>}"
echo "FAILED: ${failed:-<none>}"
echo "================================================================"
[ -z "$failed" ]
