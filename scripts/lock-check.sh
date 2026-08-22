#!/bin/sh
# lock-check.sh - refuse to write into a build mini that somebody else has
# claimed, or is building on.
#
#   scripts/lock-check.sh HOST "what this is about to do"
#
# exit 0: the host is free, or the lock on it is ours. Go ahead.
# exit 1: somebody else holds it, or it is unreachable. Do not write.
#
# WHY A CHECK AND NOT A CLAIM
#
# The other repos gate their fleet scripts by re-execing under
# `pick-bench-host.sh --run`, which acquires and then releases. That is wrong for
# the three scripts here. The documented build flow in CLAUDE.md is
#
#     HOST=$(scripts/pick-build-host.sh --acquire LABEL)
#     scripts/sync-build-host.sh $HOST
#     ssh $HOST 'cd oldmac && scripts/build-all.sh'
#     scripts/pick-build-host.sh --release $HOST
#
# so the caller ALREADY holds the lock when the sync runs. try_acquire claims
# with a bare `mkdir` that fails when the directory exists even if we own it
# (pick-build-host.sh, try_acquire), so a claim here would fail on every
# legitimate build; and --run's release would free the mini out from under a
# build that is still going. A check has neither problem: it passes when the
# lock is ours, passes when there is no lock, and refuses only for somebody else.
#
# It reads the lock through the picker's own --status so there is one probe
# implementation. pick-build-host.sh is the canonical copy owned by
# old-mac-build-host and is not ours to edit.
set -u

HOST="${1:-}"
WHAT="${2:-write to $HOST}"
if [ -z "$HOST" ]; then
	echo "usage: lock-check.sh HOST [DESCRIPTION]" >&2
	exit 2
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PICKER="$ROOT/scripts/pick-build-host.sh"
if [ ! -x "$PICKER" ]; then
	echo "!! $PICKER is missing, so the build lock cannot be read" >&2
	exit 1
fi

# Same identity string the picker writes into the lock's owner file, built the
# same way (pick-build-host.sh, REPO_NAME/ME). Both run from this repo on this
# box, so they agree; if that ever drifts, the symptom is this check refusing our
# own claim, which is loud rather than silent.
REPO_NAME=$(basename "$ROOT")
ME="${USER:-unknown}@$(hostname -s 2>/dev/null || echo host):${REPO_NAME}"

# One row, no header. BUILD_HOSTS narrows --status to the host we care about.
row=$(BUILD_HOSTS="$HOST" "$PICKER" --status 2>/dev/null | tail -n +2)
if [ -z "$row" ]; then
	echo "!! could not read the build lock on $HOST" >&2
	echo "   scripts/pick-build-host.sh --status" >&2
	exit 1
fi

state=$(echo "$row" | awk '{print $2}')
age=$(echo "$row"   | awk '{print $4}')
procs=$(echo "$row" | awk '{print $5}')
owner=$(echo "$row" | awk '{ for (i=6; i<=NF; i++) printf "%s%s", $i, (i<NF ? " " : "") }')

if [ "$state" = unreachable ]; then
	echo "!! $HOST is unreachable, so $WHAT would fail anyway" >&2
	exit 1
fi

refuse () {
	echo "!! $HOST is in use: $1" >&2
	echo "   refusing to $WHAT. The far end's dist/ and scripts/ are what a" >&2
	echo "   running build reads, so writing into them now can corrupt it." >&2
	echo "   scripts/pick-build-host.sh --status" >&2
	echo "   The other mini is usually free: scripts/pick-build-host.sh --acquire LABEL" >&2
	exit 1
}

# LOCK-AGE is "-" when there is no lock directory at all.
if [ "$age" = "-" ]; then
	# No lock, but a compiler running means a build started by hand. Same danger.
	case "$procs" in
		''|*[!0-9]*) echo "!! could not read the process count on $HOST" >&2; exit 1 ;;
	esac
	[ "$procs" -gt 0 ] && refuse "$procs compiler processes running, with no lock held"
	exit 0
fi

case "$owner" in
	*"$ME"*) exit 0 ;;
esac

refuse "locked ${age}s ago by ${owner:--unknown-}"
