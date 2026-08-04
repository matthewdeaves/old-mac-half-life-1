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
cd "$ROOT"

LOGDIR="${OLDMAC_LOGDIR:-/tmp/oldmac-build}"
mkdir -p "$LOGDIR"

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
run ppc-tiger scripts/build-ppc-tiger.sh
run ppc-panther scripts/build-ppc-panther.sh
run universal scripts/make-universal.sh
run app       scripts/make-app.sh dist/universal dist/universal-app/Half-Life.app

summary
echo "All steps completed. This says the drivers succeeded, NOT that the result is"
echo "correct: verify slices and strings on the dev box, never on Lion."
echo ".claude/rules/build-verification.md"
