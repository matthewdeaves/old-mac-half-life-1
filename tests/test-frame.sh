#!/bin/bash
# test-frame.sh - does the game still DRAW correctly on a machine?
#
#   tests/test-frame.sh HOST [map]
#
# Everything else in this repo checks that the game builds, installs, launches
# and how fast it runs. Nothing looked at the picture. A renderer fault that
# costs no frames was invisible: old-mac-quake3 found world surfaces rendering
# untextured with every number sound, and old-mac-quake2 shipped warped vertex
# maths its own benchmark scored as 4.3% FASTER. Issue #14.
#
# It captures one frame from a fixed spawn on a real machine and hands it to
# tests/frame-check.py, which asserts properties every correct frame has. There
# is no reference image and there cannot be one: a screenshot of a Half-Life map
# is Valve's content, and this repo ships code, not content. What that trades
# away is written down at the top of frame-check.py.
#
# The capture goes through scripts/bench.sh rather than a launcher of its own,
# because that script already refuses a run that is not the run you asked for:
# software GL instead of hardware, the bundled game root missing, no game dylib
# loaded. A frame captured from a wrong run would be checked just as happily.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:?usage: tests/test-frame.sh HOST [map]}"
MAP="${2:-crossfire}"

# Claim the machine. The guard names the host rather than testing that the
# variable is empty: --run exports it, so a bare test would skip claiming this
# machine whenever we are called from inside a claim on another one (issue #13).
_PICK="$ROOT/scripts/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" --run "$HOST" "test-frame" -- "$0" "$@"
fi

SSH="ssh -o ConnectTimeout=8 -o BatchMode=yes"
SCP="scp -o ConnectTimeout=8 -o BatchMode=yes"
SHOTS='~/Desktop/Half-Life/valve/scrshots'

echo "== capturing a frame on $HOST, map $MAP =="
$SCP "$ROOT/scripts/bench.sh" "$HOST:/tmp/bench.sh" >/dev/null || {
	echo "!! could not copy bench.sh to $HOST" >&2; exit 1; }
$SSH "$HOST" "rm -f $SHOTS/*.png $SHOTS/*.bmp $SHOTS/*.tga 2>/dev/null; true"

# 30 frames, one run, no warmup: this is a capture, not a measurement. The row
# bench.sh prints is discarded rather than appended to benchmarks/results.csv,
# which is for numbers that mean something.
row=$($SSH "$HOST" "/tmp/bench.sh -N $HOST -r gl -W 800 -H 600 -f 30 -n 1 -w 0 -m $MAP -x 'screenshot'" 2>/tmp/frame_${HOST}.err)
case "$row" in
	*,ERR,ERR,ERR,*)
		echo "!! the run itself failed, so there is no frame to check:" >&2
		sed 's/^/   /' "/tmp/frame_${HOST}.err" >&2
		exit 1 ;;
esac

TMP=$(mktemp -d -t hlframe)
trap 'rm -rf "$TMP"' EXIT
if ! $SCP "$HOST:$SHOTS/*.png" "$TMP/" >/dev/null 2>&1; then
	echo "!! $HOST wrote no screenshot; the engine's screenshot command failed" >&2
	exit 1
fi

shot=$(ls "$TMP"/*.png 2>/dev/null | head -1)
[ -n "$shot" ] || { echo "!! nothing came back from $HOST" >&2; exit 1; }
cp "$shot" "$TMP/$HOST-$MAP.png"

echo
python3 "$ROOT/tests/frame-check.py" "$TMP/$HOST-$MAP.png"
rc=$?
if [ "$rc" != 0 ]; then
	keep="/tmp/frame-$HOST-$MAP.png"
	cp "$shot" "$keep"
	echo
	echo "The frame that failed is at $keep. Look at it: this test says the picture"
	echo "is wrong, not what is wrong with it."
fi
exit $rc
