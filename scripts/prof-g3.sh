#!/bin/sh
# prof-g3.sh - statistical profile of the Half-Life renderer on a PPC Mac using
# the Panther/Tiger built-in `/usr/bin/sample` (no Xcode, no CHUD kext needed).
#
# It launches the deployed Half-Life.app headless, loads a map, runs a short
# warmup `timerefresh` (a commit on our engine branch), and the moment that
# warmup's result line appears - i.e. the map is loaded and we are about to
# enter a long flat-out render - it fires `sample` at the live process for a
# fixed window. The resulting symbol-level call tree lands in $OUT.
#
# `sample` symbolicates by full path, and xash3d.bin (plus libxash/libref_*.dylib)
# are launched by full path here, so the tree resolves to real engine symbols
# provided the deployed dylibs carry symbols (the -g timerefresh build does).
#
# POSIX sh (runs on 10.3 Panther). No bashisms.
#
# Usage:
#   prof-g3.sh [-r gl|soft] [-W w] [-H h] [-s fullscreen|windowed]
#              [-m map] [-D sample_seconds] [-i sample_msec]
#              [-a /path/Half-Life.app] [-o /tmp/prof.txt]
set -u

REND=gl; W=800; H=600; SCREENMODE=fullscreen; MAP=c0a0
DUR=30; INTERVAL=10; APP=""; OUT=""
WARM=120        # warmup frames (short - just a trigger)
LONG=100000     # long render frames (huge: outlives the sample window)

while getopts "r:W:H:s:m:D:i:a:o:" opt 2>/dev/null; do
	case "$opt" in
		r) REND=$OPTARG ;; W) W=$OPTARG ;; H) H=$OPTARG ;;
		s) SCREENMODE=$OPTARG ;; m) MAP=$OPTARG ;;
		D) DUR=$OPTARG ;; i) INTERVAL=$OPTARG ;;
		a) APP=$OPTARG ;; o) OUT=$OPTARG ;;
		*) echo "prof-g3.sh: bad option" >&2; exit 2 ;;
	esac
done

case "$SCREENMODE" in
	full|fullscreen) MODEPARM="-fullscreen" ;;
	border|borderless) MODEPARM="-borderless" ;;
	window|windowed) MODEPARM="-windowed" ;;
	*) echo "prof-g3.sh: bad -s '$SCREENMODE'" >&2; exit 2 ;;
esac

if [ -z "$APP" ]; then
	for cand in "$HOME/Desktop/Half-Life/Half-Life.app" \
		"$HOME/Desktop/Half-Life-Universal/Half-Life.app" \
		/Applications/Half-Life.app; do
		[ -d "$cand" ] && APP="$cand" && break
	done
fi
[ -d "$APP" ] || { echo "prof-g3.sh: no Half-Life.app (use -a)" >&2; exit 1; }

MACOS="$APP/Contents/MacOS"
BIN="$MACOS/xash3d.bin"; [ -x "$BIN" ] || BIN="$MACOS/xash3d"
BASE="$APP/.."
[ -d "$BASE/valve" ] || { [ -d "$APP/Contents/Resources/Half-Life/valve" ] && BASE="$APP/Contents/Resources/Half-Life"; }
BASE=$(cd "$BASE" && pwd)
VALVE="$BASE/valve"
[ -d "$VALVE" ] || { echo "prof-g3.sh: no valve/ under $BASE" >&2; exit 1; }

HOSTN=$(hostname -s 2>/dev/null || hostname)
[ -z "$OUT" ] && OUT="/tmp/prof_${HOSTN}_${REND}_${W}x${H}.txt"
CFG="$VALVE/prof_tr.cfg"
LOG="/tmp/prof_${HOSTN}_${REND}.log"
rm -f "$LOG" "$OUT"

# cfg: settle, kill vsync, short warmup timerefresh (the trigger), then a huge
# flat-out timerefresh we profile through, then quit.
{
	i=0; while [ $i -lt 120 ]; do echo wait; i=$((i+1)); done
	echo "gl_vsync 0"
	echo wait
	echo "timerefresh $WARM"
	echo wait
	echo "timerefresh $LONG"
	echo wait
	echo quit
} > "$CFG"

export XASH3D_BASEDIR="$BASE"
export DYLD_LIBRARY_PATH="$MACOS"
cd "$MACOS" || exit 1

echo "prof-g3: launching $BIN ($REND ${W}x${H} $SCREENMODE map=$MAP)" >&2
"$BIN" -console -nosound -ref "$REND" -width "$W" -height "$H" $MODEPARM \
	+map "$MAP" +exec prof_tr.cfg > "$LOG" 2>&1 &
PID=$!

# wait for the warmup timerefresh result line = long render is about to start
i=0
while [ $i -lt 120 ]; do
	grep -q "timerefresh:" "$LOG" 2>/dev/null && break
	kill -0 $PID 2>/dev/null || { echo "prof-g3: engine died before warmup - see $LOG" >&2; exit 1; }
	sleep 1; i=$((i+1))
done
if ! grep -q "timerefresh:" "$LOG" 2>/dev/null; then
	echo "prof-g3: warmup never completed within 120s - see $LOG" >&2
	kill -9 $PID 2>/dev/null; exit 1
fi

echo "prof-g3: warmup done, long render running - sampling PID $PID for ${DUR}s @ ${INTERVAL}ms" >&2
/usr/bin/sample "$PID" "$DUR" "$INTERVAL" -file "$OUT" >/dev/null 2>&1

kill -9 $PID 2>/dev/null
killall -9 xash3d.bin xash3d 2>/dev/null

if [ ! -s "$OUT" ]; then
	echo "prof-g3: sample produced no output ($OUT) - see $LOG" >&2
	exit 1
fi
echo "prof-g3: wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)" >&2
echo "$OUT"
