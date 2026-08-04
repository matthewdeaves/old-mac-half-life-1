#!/bin/sh
# bench.sh - deterministic Half-Life FPS benchmark for the old-Mac fleet.
#
# Runs the engine's demo-free `timerefresh` command (added by
# scripts/patch-timerefresh.py) against the deployed Half-Life.app on THIS
# machine, forcing a fixed renderer + resolution + windowed mode + map + frame
# count so results are reproducible and comparable across the whole fleet.
#
# `timerefresh` renders N frames flat-out (no host-loop pacing) while spinning
# the view 360 degrees from the map spawn, then prints:
#     timerefresh: <N> frames <T> seconds <F> fps
# It uses no demo file, so it is immune to the big-endian demo bugs on PPC and
# behaves identically on Intel and PPC, GL and soft.
#
# POSIX sh (works on 10.3 Panther through modern macOS). No bashisms.
#
# Usage:
#   bench.sh [-r gl|soft] [-W width] [-H height] [-f frames] [-n runs]
#            [-w warmups] [-m map] [-a /path/to/Half-Life.app] [-t timeout_s]
#            [-s fullscreen|borderless|windowed]
#
# Output (stdout): one CSV line per invocation:
#   host,renderer,WxH,screenmode,map,frames,fps_min,fps_med,fps_max,fps_runs
# `screenmode` is the mode this run was asked for and launched with, so a caller
# can check it got the mode it requested. `WxH` is likewise the requested size:
# in exclusive fullscreen the driver may snap to a native mode instead, and only
# the engine's `MODE:` line (echoed in the stderr note) shows what it settled on.
# plus human-readable notes on stderr.
set -u

# ---- defaults ---------------------------------------------------------------
REND=gl
W=800
H=600
FRAMES=300
RUNS=3
WARMUPS=1
MAP=c0a0
APP=""
TIMEOUT=240
SCREENMODE=fullscreen   # fullscreen | borderless | windowed

while getopts "r:W:H:f:n:w:m:a:t:s:" opt 2>/dev/null; do
	case "$opt" in
		r) REND=$OPTARG ;;
		W) W=$OPTARG ;;
		H) H=$OPTARG ;;
		f) FRAMES=$OPTARG ;;
		n) RUNS=$OPTARG ;;
		w) WARMUPS=$OPTARG ;;
		m) MAP=$OPTARG ;;
		a) APP=$OPTARG ;;
		t) TIMEOUT=$OPTARG ;;
		s) SCREENMODE=$OPTARG ;;
		*) echo "bench.sh: bad option" >&2; exit 2 ;;
	esac
done

# resolve the screen-mode dash parm (overrides config.cfg at video init).
# fullscreen (exclusive, sets a real 800x600 mode, no compositor) is the default
# because it matches how the game is actually played and avoids the macOS
# WindowServer compositing overhead that windowed mode incurs.
case "$SCREENMODE" in
	full|fullscreen) MODEPARM="-fullscreen" ;;
	border|borderless) MODEPARM="-borderless" ;;
	window|windowed) MODEPARM="-windowed" ;;
	*) echo "bench.sh: bad -s mode '$SCREENMODE' (fullscreen|borderless|windowed)" >&2; exit 2 ;;
esac

# ---- locate the app bundle --------------------------------------------------
if [ -z "$APP" ]; then
	for cand in \
		"$HOME/Desktop/Half-Life/Half-Life.app" \
		"$HOME/Desktop/Half-Life-Universal/Half-Life.app" \
		/Applications/Half-Life.app; do
		[ -d "$cand" ] && APP="$cand" && break
	done
fi
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
	echo "bench.sh: could not find Half-Life.app (use -a)" >&2
	exit 1
fi

MACOS="$APP/Contents/MacOS"
BIN="$MACOS/xash3d.bin"
[ -x "$BIN" ] || BIN="$MACOS/xash3d"
# basedir: the dir that contains valve/ (bundle's parent on our deployments)
BASE="$APP/.."
if [ ! -d "$BASE/valve" ]; then
	# fall back to bundled Resources copy
	if [ -d "$APP/Contents/Resources/Half-Life/valve" ]; then
		BASE="$APP/Contents/Resources/Half-Life"
	fi
fi
BASE=$(cd "$BASE" && pwd)
VALVE="$BASE/valve"
if [ ! -d "$VALVE" ]; then
	echo "bench.sh: no valve/ under $BASE" >&2
	exit 1
fi

HOSTN=$(hostname -s 2>/dev/null || hostname)
CFG="$VALVE/bench_tr.cfg"
LOG="/tmp/bench_${HOSTN}_${REND}_${W}x${H}.log"
rm -f "$LOG"

# ---- build the self-sequencing benchmark cfg --------------------------------
# Resolution is pinned by the -width/-height DASH parms at launch (they take
# priority over config.cfg; the `width`/`height` cvars do NOT - config overrides
# them, and a vid_restart in windowed mode lets SDL refit the window to the
# screen). So the cfg only: 1) settles after map load, 2) disables vsync,
# 3) runs warmup timerefresh(es), 4) runs the measured timerefresh(es).
{
	i=0; while [ $i -lt 120 ]; do echo wait; i=$((i+1)); done
	echo "gl_vsync 0"
	echo wait
	r=0; while [ $r -lt "$WARMUPS" ]; do echo "timerefresh $FRAMES"; echo wait; r=$((r+1)); done
	r=0; while [ $r -lt "$RUNS" ];    do echo "timerefresh $FRAMES"; echo wait; r=$((r+1)); done
	echo quit
} > "$CFG"

TOTAL=$((WARMUPS + RUNS))

# ---- launch -----------------------------------------------------------------
export XASH3D_BASEDIR="$BASE"
export DYLD_LIBRARY_PATH="$MACOS"
cd "$MACOS" || exit 1
# -width/-height + the screen-mode dash parm are read at video init and take
# priority over config.cfg (unlike the width/height/fullscreen cvars).
"$BIN" -console -nosound -ref "$REND" -width "$W" -height "$H" $MODEPARM \
	+map "$MAP" +exec bench_tr.cfg > "$LOG" 2>&1 &
PID=$!

# If this script is interrupted (Ctrl-C, parent shell gone) the engine keeps
# running fullscreen with nobody watching it, and the next thing to use this Mac
# goes fullscreen on top of it - the Rage 128 / R300 wedge. TERM, wait, then KILL.
bench_cleanup () {
	kill -0 $PID 2>/dev/null || return 0
	kill -TERM $PID 2>/dev/null
	killall -TERM xash3d.bin xash3d 2>/dev/null
	g=0
	while [ $g -lt 15 ]; do
		kill -0 $PID 2>/dev/null || break
		sleep 1; g=$((g+1))
	done
	kill -9 $PID 2>/dev/null
	killall -9 xash3d.bin xash3d 2>/dev/null
}
trap bench_cleanup EXIT INT TERM

# ---- watchdog: wait until we have all timerefresh lines, or timeout ---------
i=0
while [ $i -lt "$TIMEOUT" ]; do
	got=$(grep -c "timerefresh:" "$LOG" 2>/dev/null | tr -d ' \n')
	[ -z "$got" ] && got=0
	if [ "$got" -ge "$TOTAL" ]; then break; fi
	kill -0 $PID 2>/dev/null || break
	sleep 2; i=$((i+2))
done
# Teardown: TERM first, WAIT, and only then KILL. A hard kill while the engine
# still holds a fullscreen GL context is what corrupts the Rage 128's display LUT
# on the G3 and hangs the G5's R300 driver - black screen, fans to full,
# power-button recovery. SIGTERM gives the engine a chance to restore the display
# first; the KILL stays because SDL/CoreAudio threads do not always answer TERM.
kill -TERM $PID 2>/dev/null
killall -TERM xash3d.bin xash3d 2>/dev/null
g=0
while [ $g -lt 15 ]; do
	kill -0 $PID 2>/dev/null || break
	sleep 1; g=$((g+1))
done
kill -9 $PID 2>/dev/null
killall -9 xash3d.bin xash3d 2>/dev/null
# Settle: the display driver needs a few seconds after a fullscreen exit before
# anything else goes fullscreen on this box.
sleep "${COOLDOWN:-3}"

# ---- parse results (skip warmups) -------------------------------------------
# strip ANSI, pull the fps field (6th token) from each timerefresh line
ALLFPS=$(sed -E 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null \
	| grep "timerefresh:" | awk '{print $(NF-1)}')
MODE=$(sed -E 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null | grep "MODE:" | tail -1 | awk '{print $NF}')
GLREND=$(sed -E 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null | grep "GL_RENDERER:" | tail -1 | sed 's/.*GL_RENDERER: //')

# drop the warmup samples
MEAS=$(echo "$ALLFPS" | awk -v skip="$WARMUPS" 'NR>skip')
NMEAS=$(echo "$MEAS" | grep -c . )

if [ -z "$MEAS" ] || [ "$NMEAS" -lt 1 ]; then
	echo "bench.sh: NO RESULT on $HOSTN ($REND ${W}x${H} $SCREENMODE) - see $LOG" >&2
	echo "$HOSTN,$REND,${W}x${H},$SCREENMODE,$MAP,$FRAMES,ERR,ERR,ERR,"
	sed -E 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -i "svc_bad\|Host_Error\|Crash\|couldn.t find\|GL_INVALID" | head -3 >&2
	exit 1
fi

# min / median / max
SORTED=$(echo "$MEAS" | sort -n)
FMIN=$(echo "$SORTED" | head -1)
FMAX=$(echo "$SORTED" | tail -1)
FMED=$(echo "$SORTED" | awk '{a[NR]=$1} END{ if(NR%2){print a[(NR+1)/2]} else {printf "%.3f", (a[NR/2]+a[NR/2+1])/2} }')
RUNSCSV=$(echo "$MEAS" | tr '\n' '|' | sed 's/|$//')

echo "[$HOSTN] $REND ${W}x${H} $SCREENMODE (actual ${MODE:-?}) map=$MAP frames=$FRAMES : median ${FMED} fps  (runs: $RUNSCSV)  GPU=${GLREND:-n/a}" >&2
echo "$HOSTN,$REND,${W}x${H},$SCREENMODE,$MAP,$FRAMES,$FMIN,$FMED,$FMAX,$RUNSCSV"
