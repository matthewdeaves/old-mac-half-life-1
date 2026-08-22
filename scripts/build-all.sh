#!/usr/bin/env bash
# build-all.sh - the whole build, as one command, with the exit codes checked.
#
# RUN THIS ON A BUILD MINI. It does no ssh of its own.
#
#     scripts/build-all.sh              # sources to their pins, then every slice
#     scripts/build-all.sh --no-fetch   # skip the fetch, trees are already right
#
# WHY THIS EXISTS
#
# The steps used to be run by hand, chained with && over ssh. That is unsafe in a
# way that is easy to miss and expensive when it lands: the exit status of
#
#     scripts/build-lion.sh 2>&1 | tail -25 && scripts/build-ppc-tiger.sh
#
# is tail's, not the driver's. tail always succeeds. So a driver that refused to
# build, printed its reason and exited non-zero was reported as success, the
# chain carried on, and the run finished with the reassuring word "done" while
# one slice had never been compiled at all. That happened here: the hlsdk tree
# was at the wrong pin, all three drivers correctly refused, and the chain still
# ran to the end.
#
# Every step below therefore runs on its own line, with its status captured into
# a variable before anything else touches $?, and with output going to a file
# rather than through a pipe. Nothing is chained. A failure stops the run and
# prints the tail of that step's log, because a build driver's reason for
# refusing is the useful part.
#
# This is the only supported way to run a full build. If a step needs running on
# its own, run that one script directly and read its exit code.
set -uo pipefail

ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
cd "$ROOT" || exit 1

LOGDIR="${OLDMAC_LOGDIR:-/tmp/oldmac-build}"
mkdir -p "$LOGDIR"

# --- refuse to build with drivers that are not the repo's ---------------------
#
# ~/oldmac on a build mini is a hand-managed tree, not a clone. Nothing pulls, so
# it drifts from the repo silently and every driver still reports ok.
#
# Measured on 2026-08-05: mini-intel had FIVE stale drivers and had just produced
# a full universal build with a build-lion.sh that never cleared its destdir, a
# make-universal.sh that swallowed an install_name_tool failure, and both PowerPC
# drivers writing BUILD-STAMP from the pin rather than from the tree, so the stamp
# that exists to catch a stale build was itself stale. mini-intel2 was missing
# build-all.sh and fetch-sources.sh outright. Which host the picker handed out
# decided which build you got.
#
# There is no git on these boxes, so the check is a checksum manifest carried in
# the repo. tests/test-repo.py asserts the manifest matches the files, so it
# cannot go stale unnoticed: edit a driver without running --update-manifest and
# the repo tests fail.
MANIFEST="$ROOT/scripts/driver-manifest.md5"

manifest_check() {
	local bad=0 sum name have
	[ -f "$MANIFEST" ] || { echo "!! $MANIFEST missing" >&2; return 1; }
	while read -r sum name; do
		[ -n "$name" ] || continue
		if [ ! -f "$ROOT/scripts/$name" ]; then
			echo "!! scripts/$name is MISSING on this host" >&2
			bad=1; continue
		fi
		have=$( md5 -q "$ROOT/scripts/$name" 2>/dev/null || md5sum "$ROOT/scripts/$name" 2>/dev/null | cut -d' ' -f1 )
		if [ "$have" != "$sum" ]; then
			echo "!! scripts/$name differs from the repo's version" >&2
			bad=1
		fi
	done < "$MANIFEST"
	return $bad
}

if [ "${1:-}" = "--update-manifest" ]; then
	# Everything a mini RUNS is listed, not only what build-all.sh calls
	# directly: a stale build-installer.sh or patch script produces the same
	# irreproducible build the manifest exists to refuse, it just does it one
	# step later. The 2026-08-05 incident was five stale drivers; the gap this
	# closes is the drivers the old list left unchecked.
	: > "$MANIFEST"
	for f in build-all.sh build-pins.sh fetch-sources.sh build-lion.sh \
	         build-ppc-tiger.sh build-ppc-panther.sh make-universal.sh make-app.sh \
	         build-installer.sh build-sysreport.sh build-mod.sh fuse-mod-arm64.sh \
	         arm64-stamp.sh \
	         patch-hlsdk-mod-bugs.py patch-hlsdk-mod-gcc4.py \
	         patch-hlsdk-ppc-darwin.py patch-hlsdk-shared-clientbugs.py \
	         patch-hlsdk-xcompile-ppc.py; do
		sum=$( md5 -q "$ROOT/scripts/$f" 2>/dev/null || md5sum "$ROOT/scripts/$f" | cut -d' ' -f1 )
		printf '%s  %s\n' "$sum" "$f" >> "$MANIFEST"
	done
	echo "wrote $MANIFEST"
	exit 0
fi

if ! manifest_check; then
	echo "" >&2
	echo "This host's build scripts are NOT the repo's. Refusing to build, because" >&2
	echo "the result would not be reproducible and the stamps would assert a tree" >&2
	echo "that was never built. From the workstation run:" >&2
	echo "    scripts/sync-build-host.sh <host>" >&2
	echo "and then start this again." >&2
	exit 1
fi

FETCH=1
[ "${1:-}" = "--no-fetch" ] && FETCH=0

STEPS=()
STATUS=()

# run <label> <command...>
#
# The status is captured on its own line, immediately. Do not fold this into an
# `if`, a `&&` or a pipeline: that is the exact mistake this script exists to
# make impossible.
run() {
	local label="$1"; shift
	local log="$LOGDIR/$label.log"
	local rc

	printf '==> %-16s ' "$label"
	"$@" > "$log" 2>&1
	rc=$?

	# waf EXITS 0 ON A FAILED TASK and the install step then ships stale objects
	# from the previous build. The exit code is therefore not evidence, and this
	# script trusted it once: both PowerPC slices failed to compile, waf returned
	# 0, and the run reported every step ok while the artifacts were the previous
	# build's. Read the log as well, always. .claude/rules/build-verification.md
	if [ "$rc" -eq 0 ] && grep -q '^Build failed' "$log" 2>/dev/null; then
		echo "FAILED (waf said Build failed, then exited $rc)"
		rc=1
	fi

	STEPS+=( "$label" )
	STATUS+=( "$rc" )

	if [ "$rc" -eq 0 ]; then
		echo "ok    ($log)"
		return 0
	fi

	echo "FAILED rc=$rc"
	echo
	echo "--- last 40 lines of $log ---"
	tail -40 "$log"
	echo "--- end of $log ---"
	echo
	summary
	echo "!! build-all: '$label' failed. Nothing after it was run." >&2
	exit "$rc"
}

summary() {
	echo
	echo "STEP             RESULT"
	local i
	for i in "${!STEPS[@]}"; do
		if [ "${STATUS[$i]}" -eq 0 ]; then
			printf '%-16s ok\n' "${STEPS[$i]}"
		else
			printf '%-16s FAILED rc=%s\n' "${STEPS[$i]}" "${STATUS[$i]}"
		fi
	done
	echo
}

if [ "$FETCH" -eq 1 ]; then
	run fetch scripts/fetch-sources.sh
fi

# The gate. --status exits non-zero unless every tree is exactly at its pin, so
# this catches a tree moved by hand between the fetch and the build as well.
run pins scripts/fetch-sources.sh --status

run lion      scripts/build-lion.sh
# The i386 slice, for the 2006 Core Solo and Core Duo Macs, which have no 64-bit
# mode and so can never run the x86_64 slice. Same driver, same sources, one
# environment variable. It has to come BEFORE make-universal.sh, which fuses
# whatever slices it finds: run it after and the release quietly ships without it.
#
# Exported and then unset rather than written as `VAR=x run ...`, because `run`
# is a shell FUNCTION and bash's handling of an assignment prefixed to a function
# call is not consistent about whether the variable survives the call. An
# OLDMAC_INTEL_ARCH left set would make make-universal.sh and everything after it
# run in a mode nobody asked for.
export OLDMAC_INTEL_ARCH=i386
run lion-i386 scripts/build-lion.sh
unset OLDMAC_INTEL_ARCH
run ppc-tiger scripts/build-ppc-tiger.sh
run ppc-panther scripts/build-ppc-panther.sh
run universal scripts/make-universal.sh
run app       scripts/make-app.sh dist/universal dist/universal-app/Half-Life.app

# The other two shipped apps. These were left out for a long time on the grounds
# that they change rarely, and that turned out to be the wrong reason: a thing
# nobody rebuilds is a thing nobody re-checks. Both drifted, and one of them
# drifted into a real hole. When the game grew an i386 slice for the 2006 Core
# Solo and Core Duo Macs, and the mod dylibs followed, the Mods app did not: on
# one of those machines the game ran, every mod ran, and the app that installs
# them would not launch. Nothing in the release process was looking.
#
# Both are cheap. They compile a few Objective-C files and, in the installer's
# case, copy already-built mod dylibs; neither goes near hlsdk or the engine.
# Building the 25 MOD DYLIBS is the expensive part and stays out of here
# deliberately: it takes hours, it is driven per-branch by scripts/build-mod.sh,
# and its output is an input to the step below rather than part of it.
run installer scripts/build-installer.sh
run sysreport scripts/build-sysreport.sh

summary
echo "All steps completed. This says the drivers succeeded, NOT that the result is"
echo "correct: verify slices and strings on the dev box, never on Lion."
echo ".claude/rules/build-verification.md"
