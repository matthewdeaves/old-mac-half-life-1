#!/bin/bash
# build-mod.sh - build one Half-Life mod's game dylibs as a single FAT (ppc +
# x86_64) pair that our universal app can load on every machine in the fleet.
#
#   ./build-mod.sh <hlsdk-branch> [<hlsdk-branch> ...]
#   ./build-mod.sh --all
#
# RUN THIS ON AN INTEL LION MINI (mini-intel or mini-intel2). Ask which is free
# with `scripts/pick-build-host.sh --status`, claim it with `--acquire mods`.
# Never build on the PPC boxes - they are bench/test targets.
#
# WHAT IT PRODUCES
#   dist/mods/<branch>/server.dylib   fat: ppc + x86_64
#   dist/mods/<branch>/client.dylib   fat: ppc + x86_64
#   dist/mods/<branch>/mod.info       branch, declared gamedir, declared dll name
#
# WHY GENERIC NAMES, KEYED BY BRANCH (do not "fix" this to use GAMEDIR)
# ---------------------------------------------------------------------
# It is tempting to write straight to <GAMEDIR>/dlls/<SERVER_LIBRARY_NAME>.dylib
# from mod_options.txt. That is WRONG: the branch's build config does not always
# match what the mod actually ships. Surveyed against the real release bundle:
#   residual_point  branch says rp_pub / rp.dylib   ships as  rp/ + survivor.dylib
#   caseclosed      branch says caseclosed          ships as  cc/
#   CAd             branch says CAd                 ships as  cad/
# A dylib at the branch's name is a dylib the engine never looks for. The only
# authoritative source for the runtime name is the mod's OWN liblist.gam
# (`gamedll`), which lives with the content - so the installer, which has both
# halves in front of it, does the final naming. See installer/mods.map.
#
# WHY THE NAMES ARE UNSUFFIXED
# ------------------------------------------------------
# Xash normally loads game code by ARCH-SUFFIXED name (dlls/bshift_amd64.dylib),
# which would need one file per architecture. But the engine also falls back to
# the plain name written in the mod's own liblist.gam - server-side in
# SV_InitGame() via COM_GetGameDllPathFromGameInfo(), and client-side via our
# patch-gamedll-plain-name.py. That is also the exact filename every existing Mac
# mod release already uses. So we lipo the two slices into ONE fat dylib per role
# and drop it in at the plain name: one file, whole fleet, and installing a mod
# becomes a straight overwrite of what shipped in it.
#
# WHY ONE ppc SLICE COVERS G3 + G4 + G5
#   The game dylibs are loaded with dlopen(), which grades a generic `ppc (ALL)`
#   slice correctly on a 750 host. Only the ENGINE EXECUTABLE needs an exact
#   cpusubtype (see the ppc750 re-stamp in build-ppc-panther.sh). Proven by the
#   shipping build: make-universal.sh already serves all three PPC machines from
#   one generic-ppc game-dylib pair.
#
# VERIFICATION IS NOT OPTIONAL
#   waf can exit 0 with a FAILED compile task and then install STALE objects from
#   a previous run - a fake-success build. Every build here is checked three ways:
#   log grepped for failures, artifacts confirmed newer than the build start, and
#   lipo asked what is actually inside. See .claude/rules/build-verification.md.
set -euo pipefail

# --- where things live -------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODSRC="$ROOT/vendor/hlsdk-mods"          # git-ignored per-branch checkouts
DIST="$ROOT/dist/mods"                    # finished fat dylibs
LOGS="$ROOT/dist/mods/_logs"

# WHERE THE SOURCE COMES FROM - and why not straight from GitHub.
#
# Historically the Lion minis could not clone from github.com at all: Xcode 4's git
# links an OpenSSL far too old for TLS 1.2, so every fetch died with
#   "SSL23_GET_SERVER_HELLO:tlsv1 alert protocol version".
#
# As of 2026-07-26 that is FIXED - the minis carry OpenSSL 3.5.7 + curl 8.21 + git
# 2.55 under ~/local, first on PATH, and `git clone https://github.com/...` works
# on them directly (OpenSSL 3.5.7 / curl 8.21 / git 2.55, built from source into
# ~/local on each mini).
#
# The mirror is kept anyway, deliberately. It is not a workaround any more, it is
# the better design:
#   - the build is pinned to exact commits in vendor/MANIFEST.md, so fetching from
#     a moving upstream mid-build is a liability, not a feature
#   - 57 branches clone from a local path in seconds, over wifi in minutes
#   - it still builds with no internet at all, which is the point of a machine
#     whose job is to be reproducible in ten years
#   - the PPC bench boxes genuinely still have no TLS; only the Intel minis were fixed
#
# So: keep a local --mirror clone (all 57 branches, ~29 MB) made on a machine with
# modern TLS, rsync it to the build host once, and clone every mod branch from that
# path. Refresh it from a modern Mac with:  git -C <mirror> remote update
UPSTREAM_URL="https://github.com/FWGS/hlsdk-portable.git"
MIRROR="${HLSDK_MIRROR:-$ROOT/vendor/hlsdk-portable-mirror.git}"
if [ -d "$MIRROR" ]; then
	UPSTREAM="$MIRROR"
	echo "source: local mirror $MIRROR"
else
	UPSTREAM="$UPSTREAM_URL"
	echo "source: $UPSTREAM_URL (no local mirror; this fails on Lion - see comment)"
fi

# The mod list has ONE source of truth: installer/mods.map, which the installer
# also reads. Keeping a second copy here would let the two drift, and a mod present
# in one but not the other fails in a confusing way - either a build nothing
# installs, or an install with no build. Column 2 of that file is the branch.
# (Excluded there, with reasons: `tfc`, no upstream branch; `xenwar`, broken at
# source.)
MODMAP="$ROOT/installer/mods.map"
all_branches() {
	[ -f "$MODMAP" ] || { echo "ERROR: missing $MODMAP" >&2; return 1; }
	awk '!/^[[:space:]]*#/ && NF >= 3 { print $2 }' "$MODMAP"
}

# --- toolchains --------------------------------------------------------------
# x86_64: Xcode clang + the 10.7 SDK (same as build-lion.sh).
XC_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SDK_INTEL="$XC_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.7.sdk"
TCXX="$XC_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/c++/v1"

# ppc: gcc-4.0 + the 10.3.9 SDK (same as build-ppc-panther.sh). --disable-altivec
# keeps the slice generic ppc, which is what dlopen wants on a 750.
SDK_PPC=/Developer/SDKs/MacOSX10.3.9.sdk
GCCINC=/usr/lib/gcc/powerpc-apple-darwin10/4.0.1/include
CXXINC_PPC="-isystem $SDK_PPC/usr/include/c++/4.0.0/powerpc-apple-darwin7"
SHIM="$ROOT/compat-include"

# Lion has no git in /usr/bin - it ships inside Xcode, and a non-interactive ssh
# shell won't have it on PATH. Needed globally here (not just in the build
# subshells) because the checkout step runs git directly.
if [ -d "$XC_DEVELOPER_DIR/usr/bin" ]; then
	export PATH="$XC_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$XC_DEVELOPER_DIR/usr/bin:$PATH"
fi
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found on PATH" >&2; exit 1; }

if command -v python >/dev/null 2>&1; then PY=python
elif command -v python3 >/dev/null 2>&1; then PY=python3
else echo "ERROR: no python interpreter found" >&2; exit 1; fi

usage() { sed -n '2,12p' "$0"; exit 2; }
[ $# -gt 0 ] || usage
if [ "$1" = "--all" ]; then set -- $(all_branches) || exit 1; fi

mkdir -p "$MODSRC" "$DIST" "$LOGS" "$SHIM"

# C++03 shims the 10.3.9 SDK lacks (mirrors build-ppc-panther.sh; idempotent).
printf '#pragma once\n#ifndef __STDC_FORMAT_MACROS\n#define __STDC_FORMAT_MACROS 1\n#endif\n#include <inttypes.h>\n' > "$SHIM/cinttypes"
printf '#pragma once\n#include <stdint.h>\n' > "$SHIM/cstdint"

# --- helpers -----------------------------------------------------------------

# Read a KEY=value line out of a branch's mod_options.txt, stripping the trailing
# "# comment" and surrounding whitespace. Each mod branch declares its own GAMEDIR
# and dll name there, which is why one driver can build all of them.
mod_option() {
	local tree="$1" key="$2" val
	val="$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\([^#]*\).*/\1/p" \
		"$tree/mod_options.txt" 2>/dev/null | head -1)"
	# strip trailing whitespace
	printf '%s' "$val" | sed 's/[[:space:]]*$//'
}

# Clone at <branch> or fetch it if the checkout already exists. Always leaves the
# tree on a clean, pristine branch tip so patches apply predictably.
prepare_tree() {
	local tree="$1" branch="$2"
	if [ -d "$tree/.git" ]; then
		echo "    refreshing $(basename "$tree")"
		# NB: subshell + cd, not `git -C`. -C arrived in git 1.8.5, and the git that
		# runs HERE is 1.7.12.4, which fails with "Unknown option: -C".
		#
		# Do not "fix" this on the grounds that the minis now have git 2.55: they do,
		# at ~/local/bin/git, and it is first on PATH for an ordinary ssh login - but
		# NOT inside this script. Line ~122 deliberately puts the Xcode toolchain
		# ahead of everything, and Xcode 4.6.3 ships its own git 1.7.12.4 at
		# $XC_DEVELOPER_DIR/usr/bin/git, which therefore wins:
		#
		#   ssh mini git --version                  -> 2.55.0        (~/local/bin)
		#   PATH=$XCODE/usr/bin:$PATH git --version -> 1.7.12.4      (what runs here)
		#
		# That PATH ordering is not incidental and must not be reversed: Lion's
		# /usr/bin/{install_name_tool,lipo,strings} are stale stubs that choke on
		# modern Mach-O load commands, so the Xcode copies have to win. Old git is
		# the price of correct binary tooling. The subshell costs nothing and works
		# under either git, which is why it stays.
		(
			cd "$tree" &&
			git fetch --quiet origin "$branch" &&
			git checkout --quiet -B "$branch" FETCH_HEAD &&
			git reset --hard --quiet FETCH_HEAD &&
			git clean -qfdx
		)
	else
		echo "    cloning $branch -> $(basename "$tree")"
		# Deliberately NOT --recursive. hlsdk's only submodule is vgui_support, which
		# is opt-in via --enable-vgui (default False) and which we never enable - and
		# its URL is an absolute https://github.com one, so on Lion the submodule fetch
		# dies on TLS even when the branch itself came from the local mirror. The
		# "always clone --recursive" rule in CLAUDE.md is about the ENGINE, whose
		# 3rdparty/mainui submodule genuinely is required.
		git clone --quiet --branch "$branch" --single-branch "$UPSTREAM" "$tree"
	fi
}

# The three checks from CLAUDE.md. $1 install root, $2 gamedir, $3 build-start
# epoch, $4 label. Echoes nothing on success; exits non-zero on any doubt.
verify_build() {
	local dest="$1" gamedir="$2" started="$3" label="$4" log="$5"
	local bad=0 f mt

	if grep -qE 'Build failed|task in .* failed' "$log"; then
		echo "    !! '$label': waf reported a FAILED task (grep 'Build failed' $log)" >&2
		bad=1
	fi
	# --disable-werror means warnings are fine; real compiler errors are not.
	if grep -q ' error: ' "$log"; then
		echo "    !! '$label': compiler errors in $log" >&2
		bad=1
	fi

	local found=0
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

# --- per-arch builds ---------------------------------------------------------

build_intel() {
	local tree="$1" dest="$2" log="$3"
	(
		export DEVELOPER_DIR="$XC_DEVELOPER_DIR"
		export PATH="$XC_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$XC_DEVELOPER_DIR/usr/bin:$PATH"
		export MACOSX_DEPLOYMENT_TARGET=10.7
		export CFLAGS="-isysroot $SDK_INTEL"
		export CXXFLAGS="-isysroot $SDK_INTEL -stdlib=libc++ -isystem $TCXX"
		export LINKFLAGS="-isysroot $SDK_INTEL -stdlib=libc++"
		export LDFLAGS="-isysroot $SDK_INTEL -stdlib=libc++"
		cd "$tree"
		rm -rf build-intel
		"$PY" waf --out=build-intel configure --disable-werror
		"$PY" waf --out=build-intel build -j"$(sysctl -n hw.ncpu)"
		rm -rf "$dest"
		"$PY" waf --out=build-intel install --destdir="$dest"
	) >"$log" 2>&1
}

build_ppc() {
	local tree="$1" dest="$2" log="$3"
	(
		export DEVELOPER_DIR="$XC_DEVELOPER_DIR"   # for git only
		export CC="gcc-4.0" CXX="g++-4.0"
		export MACOSX_DEPLOYMENT_TARGET=10.3
		local archflags="-arch ppc -isysroot $SDK_PPC -mmacosx-version-min=10.3"
		export CFLAGS="$archflags"
		export CXXFLAGS="$archflags -isystem $SHIM -isystem $GCCINC $CXXINC_PPC"
		export LINKFLAGS="$archflags"
		export LDFLAGS="$archflags"
		cd "$tree"
		rm -rf build-ppc
		# Only --disable-werror here. --disable-altivec is an ENGINE waf option and
		# hlsdk's configure rejects it (it prints help and leaves the project
		# unconfigured). The slice comes out generic ppc from -arch ppc alone, which
		# is what dlopen wants on a 750 - same as build-ppc-panther.sh's hlsdk step.
		"$PY" waf --out=build-ppc configure --disable-werror
		"$PY" waf --out=build-ppc build -j"$(sysctl -n hw.ncpu)"
		rm -rf "$dest"
		"$PY" waf --out=build-ppc install --destdir="$dest"
	) >"$log" 2>&1
}

# --- main --------------------------------------------------------------------

failed=""
built=""

for branch in "$@"; do
	echo "================================================================"
	echo "== $branch"
	echo "================================================================"

	tree_i="$MODSRC/$branch-intel"
	tree_p="$MODSRC/$branch-ppc"
	dest_i="$MODSRC/_install/$branch-intel"
	dest_p="$MODSRC/_install/$branch-ppc"
	log_i="$LOGS/$branch-intel.log"
	log_p="$LOGS/$branch-ppc.log"

	if ! ( prepare_tree "$tree_i" "$branch" && prepare_tree "$tree_p" "$branch" ); then
		echo "  !! checkout failed" >&2; failed="$failed $branch"; continue
	fi

	gamedir="$(mod_option "$tree_i" GAMEDIR)"
	svname="$(mod_option "$tree_i" SERVER_LIBRARY_NAME)"
	svdir="$(mod_option "$tree_i" SERVER_INSTALL_DIR)";  svdir="${svdir:-dlls}"
	cldir="$(mod_option "$tree_i" CLIENT_INSTALL_DIR)";  cldir="${cldir:-cl_dlls}"
	if [ -z "$gamedir" ] || [ -z "$svname" ]; then
		echo "  !! cannot read GAMEDIR/SERVER_LIBRARY_NAME from mod_options.txt" >&2
		failed="$failed $branch"; continue
	fi
	echo "  gamedir=$gamedir  server=$svname  ($svdir/, $cldir/)"

	# PPC needs the big-endian game-code fixes; the script picks modern vs legacy.
	if ! "$ROOT/scripts/graft-ppc-endian.sh" "$tree_p" | sed 's/^/  /'; then
		echo "  !! endian graft failed" >&2; failed="$failed $branch"; continue
	fi
	"$PY" "$ROOT/scripts/patch-hlsdk-xcompile-ppc.py" "$tree_p/scripts/waifulib/xcompile.py" | sed 's/^/  /'
	# hlsdk assumes "darwin implies clang"; we build darwin/ppc with gcc, which needs
	# the GNU-only -Wl,--no-undefined dropped and build.h taught Apple's PPC macros.
	"$PY" "$ROOT/scripts/patch-hlsdk-ppc-darwin.py" "$tree_p" | sed 's/^/  /'
	# Mod source that only compiles under a modern C++ compiler; gcc-4.0 is stricter.
	# No-op for mods that don't need it.
	"$PY" "$ROOT/scripts/patch-hlsdk-mod-gcc4.py" "$tree_p" | sed 's/^/  /'

	# Audit fixes. BOTH trees, not just ppc: apart from the DMC byteswap these are
	# arch-neutral bugs (unbounded sprintf, missing null checks, wrong save field
	# types), so patching only the ppc tree would ship an Intel slice of the same
	# mod that still carries them. See docs/MOD-AUDIT.md.
	for t in "$tree_i" "$tree_p"; do
		if ! "$PY" "$ROOT/scripts/patch-hlsdk-shared-clientbugs.py" "$t" | sed 's/^/  /'; then
			echo "  !! shared client fixes failed" >&2; failed="$failed $branch"; continue 2
		fi
		if ! "$PY" "$ROOT/scripts/patch-hlsdk-mod-bugs.py" "$branch" "$t" | sed 's/^/  /'; then
			echo "  !! per-mod audit fixes failed" >&2; failed="$failed $branch"; continue 2
		fi
	done

	started=$(date +%s)

	echo "  [1/3] building x86_64 ..."
	if ! build_intel "$tree_i" "$dest_i" "$log_i"; then
		echo "  !! x86_64 build failed - see $log_i" >&2; failed="$failed $branch"; continue
	fi
	if ! verify_build "$dest_i" "$gamedir" "$started" "$branch/x86_64" "$log_i"; then
		failed="$failed $branch"; continue
	fi

	echo "  [2/3] building ppc ..."
	if ! build_ppc "$tree_p" "$dest_p" "$log_p"; then
		echo "  !! ppc build failed - see $log_p" >&2; failed="$failed $branch"; continue
	fi
	if ! verify_build "$dest_p" "$gamedir" "$started" "$branch/ppc" "$log_p"; then
		failed="$failed $branch"; continue
	fi

	echo "  [3/3] lipo -> fat"
	out="$DIST/$branch"
	rm -rf "$out"; mkdir -p "$out"

	# Glob rather than assume the arch suffix: waf derives it from library_naming.py
	# (_amd64 / _ppc today), and hardcoding it would break silently if that changes.
	sv_i=$(ls "$dest_i/$gamedir/$svdir"/*.dylib 2>/dev/null | head -1)
	sv_p=$(ls "$dest_p/$gamedir/$svdir"/*.dylib 2>/dev/null | head -1)
	cl_i=$(ls "$dest_i/$gamedir/$cldir"/*.dylib 2>/dev/null | head -1)
	cl_p=$(ls "$dest_p/$gamedir/$cldir"/*.dylib 2>/dev/null | head -1)
	if [ -z "$sv_i" ] || [ -z "$sv_p" ] || [ -z "$cl_i" ] || [ -z "$cl_p" ]; then
		echo "  !! missing a slice: sv[$sv_i|$sv_p] cl[$cl_i|$cl_p]" >&2
		failed="$failed $branch"; continue
	fi

	lipo -create "$sv_i" "$sv_p" -output "$out/server.dylib"
	lipo -create "$cl_i" "$cl_p" -output "$out/client.dylib"

	# Record what the branch THINKS it is. The installer prefers the mod's own
	# liblist.gam, but falls back to these when a mod ships without one.
	{
		echo "branch=$branch"
		echo "gamedir=$gamedir"
		echo "server_dll=$svname"
		echo "server_dir=$svdir"
		echo "client_dir=$cldir"
		echo "built=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "commit=$( cd "$tree_i" && git rev-parse HEAD )"
	} > "$out/mod.info"

	# Final proof: the shipped files really are two-slice fat binaries.
	bad=0
	for f in "$out/server.dylib" "$out/client.dylib"; do
		info=$(lipo -info "$f")
		case "$info" in
			*ppc*x86_64*|*x86_64*ppc*) echo "    ok: ${f#$DIST/} - ${info#*: }" ;;
			*) echo "    !! not fat: $info" >&2; bad=1 ;;
		esac
	done
	if [ "$bad" -ne 0 ]; then failed="$failed $branch"; continue; fi

	built="$built $branch"
done

echo
echo "================================================================"
echo "built:  ${built:-<none>}"
echo "FAILED: ${failed:-<none>}"
echo "================================================================"
[ -z "$failed" ]
