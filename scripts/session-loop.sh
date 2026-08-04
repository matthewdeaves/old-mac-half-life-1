#!/usr/bin/env bash
# session-loop.sh - keep working the Half-Life port across session limits.
#
# WHY THIS EXISTS. A long session ends in one of two ways: the work finishes, or
# the usage limit lands mid-thought and every running subagent dies with it. The
# second happened twice in one night, and each time the cost was not the tokens,
# it was the findings that had been measured but never written down. This script
# makes the handover document the unit of progress instead of the session: every
# iteration must leave the doc correct before it stops, and the loop then waits
# out the limit and starts a fresh session from that doc.
#
# The loop is deliberately dumb. It does not decide what to work on. The handover
# document decides, and the previous iteration wrote it. If an iteration crashes
# without updating the doc, the next one repeats the same work rather than
# skipping it, which is the safe direction to fail in.
#
# usage:
#   scripts/session-loop.sh                 # run until the handover says DONE
#   scripts/session-loop.sh -n 3            # at most 3 iterations
#   scripts/session-loop.sh --safe          # ask before edits, no bypass
#   scripts/session-loop.sh --dry-run       # print the command, run nothing
#
# To stop it: create the stop file, or Ctrl-C.
#   touch ~/Desktop/STOP-HALFLIFE-LOOP
# The stop file is checked between iterations, so a running iteration finishes
# its thought and writes its handover first. That is intentional: killing an
# iteration mid-flight is how you lose the findings.
#
# Everything it does is logged under logs/session-loop/ in this repo.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDOFF="${HANDOFF:-$HOME/Desktop/half-life-handoff.md}"
STOPFILE="${STOPFILE:-$HOME/Desktop/STOP-HALFLIFE-LOOP}"
LOGDIR="$ROOT/logs/session-loop"

MAXITER=0                 # 0 means no limit
PERMS="--dangerously-skip-permissions"
DRYRUN=0
CONFIRM=1

while [ $# -gt 0 ]; do
	case "$1" in
		-n)        MAXITER="$2"; shift 2 ;;
		--safe)    PERMS="--permission-mode acceptEdits"; shift ;;
		--dry-run) DRYRUN=1; shift ;;
		-y)        CONFIRM=0; shift ;;
		-h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*)         echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

[ -f "$HANDOFF" ] || { echo "no handover document at $HANDOFF" >&2; exit 1; }
mkdir -p "$LOGDIR"

# The loop runs unattended, so by default it bypasses the permission prompt.
# That is a real decision and it gets a real warning, once, with a way out.
# --safe trades unattended operation for prompts: useful for a first run you
# intend to watch, useless for the case this script exists to solve.
if [ "$PERMS" = "--dangerously-skip-permissions" ] && [ "$CONFIRM" = 1 ] && [ "$DRYRUN" = 0 ]; then
	cat <<-BANNER

	  This loop runs Claude Code with permission checks BYPASSED, because an
	  unattended session cannot answer a prompt. It will edit this repo, run
	  builds, and ssh to the fleet on its own.

	  It is told not to push, not to open pull requests, not to touch anyone's
	  valve folder or installed mods, and not to cut a release. Those are
	  instructions, not a sandbox.

	  Ctrl-C now to abort, or wait ten seconds.

	BANNER
	sleep 10 || exit 130
fi

# Read "resets 3:30am" out of Claude's own limit message and wait for it, rather
# than guessing a backoff. Falls back to 20 minutes when the message does not
# name a time, which costs one wasted attempt at worst.
seconds_until_reset() {
	local text="$1" when secs now
	when="$(printf '%s' "$text" | sed -n 's/.*resets \([0-9][0-9]*:[0-9][0-9]*[ap]m\).*/\1/p' | head -1)"
	[ -n "$when" ] || { echo 1200; return; }
	secs="$(date -j -f '%I:%M%p' "$when" '+%s' 2>/dev/null)" || { echo 1200; return; }
	now="$(date '+%s')"
	# A reset time earlier in the day than now means tomorrow.
	[ "$secs" -le "$now" ] && secs=$(( secs + 86400 ))
	echo $(( secs - now + 120 ))
}

PROMPT="Read $HANDOFF in full. It is the handover from the previous session and
it is authoritative about what is done, what is in flight, and what is next.

Then do the next block of work it names. Follow CLAUDE.md exactly, in particular:
never push or open a pull request upstream, never touch a valve folder or an
installed mod, never trust a build's exit 0, no em dashes, and hand anything
tricky to a fresh adversarial agent told to refute it rather than approve it.

Work for as long as you usefully can. Prefer finishing one thing completely over
starting three. Commit what is finished.

BEFORE YOU STOP, for any reason, rewrite $HANDOFF so that a session with no
memory of this one can carry on without losing anything. It must state: what you
finished and how it was verified, what you measured versus what you inferred,
what is half-done and exactly where you left it, which machines are in what
state and whether any build lock is held, and the single next action. Delete
anything in it that is no longer true. A handover that is stale is worse than no
handover.

If every task in the handover is genuinely finished and verified, write the
single line ALL WORK COMPLETE at the very top of $HANDOFF and stop."

iter=0
while : ; do
	if [ -f "$STOPFILE" ]; then
		echo "[loop] stop file present at $STOPFILE, stopping."
		rm -f "$STOPFILE"
		exit 0
	fi
	if head -5 "$HANDOFF" | grep -q "ALL WORK COMPLETE"; then
		echo "[loop] handover says ALL WORK COMPLETE, stopping."
		exit 0
	fi

	iter=$(( iter + 1 ))
	if [ "$MAXITER" != 0 ] && [ "$iter" -gt "$MAXITER" ]; then
		echo "[loop] reached the $MAXITER iteration limit, stopping."
		exit 0
	fi

	stamp="$(date '+%Y%m%d-%H%M%S')"
	log="$LOGDIR/$stamp.log"
	echo "[loop] iteration $iter starting $(date '+%H:%M:%S'), log $log"

	if [ "$DRYRUN" = 1 ]; then
		echo "would run: claude -p <prompt> $PERMS --output-format text"
		exit 0
	fi

	# Record the handover's checksum so we can tell whether the iteration
	# actually left one behind, which is the whole contract.
	before="$(shasum "$HANDOFF" | awk '{print $1}')"

	( cd "$ROOT" && claude -p "$PROMPT" $PERMS --output-format text ) 2>&1 | tee "$log"
	rc="${PIPESTATUS[0]}"

	after="$(shasum "$HANDOFF" | awk '{print $1}')"
	if [ "$before" = "$after" ]; then
		echo "[loop] WARNING: the handover was not updated this iteration."
		echo "[loop] the next iteration will repeat this work rather than skip it."
	fi

	# Distinguish "out of budget, wait" from "something else went wrong".
	if grep -qiE "session limit|usage limit|rate.?limit" "$log"; then
		wait_for="$(seconds_until_reset "$(grep -iE 'session limit|usage limit|resets' "$log" | head -1)")"
		echo "[loop] limit reached. Sleeping $(( wait_for / 60 )) minutes, until about $(date -v +"${wait_for}"S '+%H:%M' 2>/dev/null)."
		sleep "$wait_for"
		continue
	fi

	if [ "$rc" != 0 ]; then
		echo "[loop] iteration exited $rc. Backing off 5 minutes and retrying."
		sleep 300
		continue
	fi

	echo "[loop] iteration $iter finished cleanly. Next one in 30 seconds."
	sleep 30
done
