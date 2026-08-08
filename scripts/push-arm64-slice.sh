#!/bin/sh
# push-arm64-slice.sh - carry the arm64 slice from this Apple Silicon box to a
# build mini, and PROVE it arrived, so make-universal.sh can fuse it.
#
#   scripts/push-arm64-slice.sh HOST [--check]
#
# WHY THIS EXISTS
#
# Four of the five slices are built on the Lion mini. arm64 cannot be: Xcode 4.6
# predates it by seven years. So arm64 is the one slice built on a different
# machine, and it has to be carried to the machine that does the fuse.
#
# That makes it the single most likely slice to go stale, for exactly the reason
# recorded at the top of sync-build-host.sh: nothing pulls, so the two ends drift
# silently and the drift is invisible in the build output. Worse here, because
# make-universal.sh treats dist/arm64 as OPTIONAL: a slice that failed to arrive
# does not stop a release, it just quietly is not in it.
#
# So: copy, then verify by checksum, and refuse to report success otherwise.
set -u

HOST="${1:-}"
MODE="${2:-}"
if [ -z "$HOST" ]; then
	echo "usage: push-arm64-slice.sh HOST [--check]" >&2
	exit 2
fi

OLDMAC="${OLDMAC:-$HOME/oldmac}"
SRC="$OLDMAC/dist/arm64"

if [ ! -d "$SRC" ]; then
	echo "!! no arm64 slice at $SRC" >&2
	echo "   run scripts/build-arm64.sh on this box first" >&2
	exit 1
fi
if [ ! -f "$SRC/BUILD-STAMP" ]; then
	echo "!! $SRC has no BUILD-STAMP, so make-universal.sh would refuse it anyway" >&2
	exit 1
fi

# Content fingerprint over names AND contents. LC_ALL=C because sort's collation
# is locale-dependent and this box and the minis disagree, which otherwise makes
# identical trees hash differently and report drift for ever.
fp_local () {
	( cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do
		echo "$f $(md5 -q "$f")"; done ) | md5 -q
}
fp_remote () {
	ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" \
		'cd oldmac/dist/arm64 2>/dev/null && find . -type f | LC_ALL=C sort | while read -r f; do
			echo "$f $(md5 -q "$f")"; done | md5 -q' 2>/dev/null
}

l="$( fp_local "$SRC" )"
r="$( fp_remote )"
n="$( find "$SRC" -type f | wc -l | tr -d ' ' )"
stamp="$( cat "$SRC/BUILD-STAMP" )"

if [ "$l" = "$r" ]; then
	echo "arm64 slice on $HOST is current ($n files, stamp ${stamp%${stamp#??????? }})"
	exit 0
fi

if [ "$MODE" = "--check" ]; then
	echo "arm64 slice on $HOST DIFFERS or is missing, run without --check" >&2
	exit 1
fi

echo "==> copying the arm64 slice ($n files) to $HOST"
# tar, not scp: one connection, it creates the directory, and it preserves the
# executable bits that a Mach-O needs. Nothing is deleted at the far end.
if ! ( cd "$OLDMAC/dist" && tar cf - arm64 ) | \
     ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" 'mkdir -p oldmac/dist && tar xf - -C oldmac/dist'; then
	echo "!! transfer failed" >&2
	exit 1
fi

r2="$( fp_remote )"
if [ "$l" != "$r2" ]; then
	echo "!! the copy did not take: $HOST still differs" >&2
	exit 1
fi
echo "== $HOST now has this box's arm64 slice ($n files) =="
echo "   stamp: $stamp"
