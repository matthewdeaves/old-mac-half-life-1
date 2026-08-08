#!/bin/sh
# push-mod-arm64.sh - carry the arm64 MOD slices from this Apple Silicon box to a
# build mini, and PROVE they arrived.
#
#   scripts/push-mod-arm64.sh HOST [--check]
#
# Companion to push-arm64-slice.sh, which does the same job for the engine. Same
# reason both exist: arm64 is the one architecture no mini can produce, so it is
# built here and carried, and a carried artifact is the single most likely thing
# to go stale. Nothing pulls, so the two ends drift silently and the drift does
# not show up in any build output.
#
# It carries two things, both optional at the far end and both therefore able to
# be missing without anything failing loudly:
#   dist/mods-arm64/       25 thin arm64 mod dylib pairs, fused by fuse-mod-arm64.sh
#   dist/installer-arm64/  the Mods app's own arm64 slice, fused by build-installer.sh
set -u

HOST="${1:-}"
MODE="${2:-}"
if [ -z "$HOST" ]; then
	echo "usage: push-mod-arm64.sh HOST [--check]" >&2
	exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Content fingerprint over names AND contents. LC_ALL=C because sort's collation
# is locale-dependent and this box and the minis disagree: with names like
# Hunger.tga and Zombie-X-DLE.tga the two orders differ, so identical trees hash
# differently and report drift for ever. A check that cries wolf teaches you to
# ignore it.
fp_local () {
	( cd "$1" && find . -type f ! -name '*.log' | LC_ALL=C sort | while read -r f; do
		echo "$f $(md5 -q "$f")"; done ) | md5 -q
}
fp_remote () {
	ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" \
		'cd oldmac/'"$1"' 2>/dev/null && find . -type f ! -name "*.log" | LC_ALL=C sort | while read -r f; do
			echo "$f $(md5 -q "$f")"; done | md5 -q' 2>/dev/null
}

rc=0
any=0

for rel in dist/mods-arm64 dist/installer-arm64; do
	src="$ROOT/$rel"
	if [ ! -d "$src" ]; then
		echo "-- $rel: not built on this box, skipping"
		continue
	fi
	any=1
	n="$( find "$src" -type f ! -name '*.log' | wc -l | tr -d ' ' )"
	l="$( fp_local "$src" )"
	r="$( fp_remote "$rel" )"

	if [ "$l" = "$r" ]; then
		echo "== $rel: $HOST already matches ($n files)"
		continue
	fi
	if [ "$MODE" = "--check" ]; then
		if [ -z "$r" ]; then echo "== $rel: MISSING on $HOST"
		else echo "== $rel: DIFFERS from $HOST"; fi
		rc=1
		continue
	fi

	echo "== $rel: copying $n files to $HOST"
	# rsync, not tar: this is ~60 MB over a wifi path measured at 0.55 MB/s to the
	# minis, and rsync can skip what is already identical on a retry. The transfer
	# HAS hung once at this size and had to be restarted, so resumability is not
	# theoretical. No --delete: a stale extra file is caught by the fingerprint
	# below, whereas a --delete pointed at the wrong path is not recoverable.
	if ! rsync -a --partial --exclude '_logs' "$src/" "$HOST:oldmac/$rel/"; then
		echo "!! $rel: rsync failed" >&2
		rc=1
		continue
	fi
	r2="$( fp_remote "$rel" )"
	if [ "$l" = "$r2" ]; then
		echo "== $rel: verified on $HOST ($n files)"
	else
		echo "!! $rel: COPY DID NOT TAKE (local $l, remote ${r2:-none})" >&2
		rc=1
	fi
done

if [ "$any" -eq 0 ]; then
	echo "!! nothing to push."
	echo "   Build the arm64 slices on this box first:"
	echo "     scripts/build-mod-arm64.sh --all"
	echo "     scripts/build-installer-arm64.sh"
	exit 1
fi

if [ "$rc" -eq 0 ] && [ "$MODE" != "--check" ]; then
	echo
	echo "Now, ON $HOST:"
	echo "  scripts/fuse-mod-arm64.sh    # adds arm64 to the mod dylibs in dist/mods"
	echo "  scripts/build-installer.sh   # picks up dist/installer-arm64 by itself"
fi
exit "$rc"
