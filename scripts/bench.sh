#!/bin/sh
# bench.sh - deterministic Half-Life FPS benchmark for the old-Mac fleet.
#
# Runs the engine's demo-free `timerefresh` command (added by
# our engine branch) against the deployed Half-Life.app on THIS
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
#            [-s fullscreen|borderless|windowed] [-x "cvar val; cvar val"] [-S]
#
#   -S  accept Apple's SOFTWARE GL for a `-r gl` run. Off by default: a software
#       GL run asserts clean on every other count and returns a number 5-10x too
#       low, which reads exactly like a renderer regression.
#
# It launches through the app's LAUNCHER and then ASSERTS that the run it got is
# the run it asked for: bundled game root in the search path, game dylibs loaded,
# requested renderer actually loaded, no host error, and every requested sample
# present. Any of those failing prints the reason plus the tail of the engine log
# and exits non-zero with an ERR row, rather than reporting a number.
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
# Console commands run AFTER the map has settled and BEFORE the warmup, so an
# A/B of a render cvar is a first-class benchmark rather than a hand-rolled cfg
# in /tmp. Semicolon-separated, e.g. -x "gl_singlepass 0; gl_overbright 1".
EXTRA=""
# -r gl landing on Apple's software GL is a FAILURE by default, see assertion 5.
# -S says you meant it, for the rare case of deliberately measuring software GL.
ALLOW_SOFTGL=0
# Identity for the CSV row. Defaults to the machine's own hostname, which is not
# good enough on this fleet, see the note where HOSTN is set.
NAME=""

while getopts "r:W:H:f:n:w:m:a:t:s:x:N:S" opt 2>/dev/null; do
	case "$opt" in
		r) REND=$OPTARG ;;
		N) NAME=$OPTARG ;;
		S) ALLOW_SOFTGL=1 ;;
		W) W=$OPTARG ;;
		H) H=$OPTARG ;;
		f) FRAMES=$OPTARG ;;
		n) RUNS=$OPTARG ;;
		w) WARMUPS=$OPTARG ;;
		m) MAP=$OPTARG ;;
		a) APP=$OPTARG ;;
		t) TIMEOUT=$OPTARG ;;
		s) SCREENMODE=$OPTARG ;;
		x) EXTRA=$OPTARG ;;
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
# ALWAYS launch through the LAUNCHER (Contents/MacOS/xash3d), never the Mach-O
# (xash3d.bin) directly.
#
# This is not a style preference, it is the difference between a benchmark and a
# crash. Launching the Mach-O directly skips the launcher's environment setup, and
# the engine then never adds the bundled read-only root, so no game dylib is found:
#
#   via launcher : Adding directory: <app>/Contents/Resources/Half-Life/
#                  Dll loaded for game "Half-Life"
#   via .bin     : (no rodir line at all)
#                  Host_ErrorInit: can't initialize cl_dlls/client_ppc.dylib
#
# Measured on the G3 on 2026-08-04, both logs side by side. The failure mode is
# nasty because the engine still opens a window, still prints GL_RENDERER and
# still reaches video init, so it looks like a working run right up until the map
# never loads. Verified below by ASSERTing the rodir line rather than trusting it.
LAUNCHER="$MACOS/xash3d"
if [ ! -x "$LAUNCHER" ]; then
	echo "bench.sh: no launcher at $LAUNCHER" >&2
	exit 1
fi
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

# Identity of the row. `hostname -s` is the wrong answer on this fleet and was
# quietly producing misleading history: the G3 calls itself "macs-computer",
# which names neither the machine nor, far worse, WHICH OS it booted. Two of
# these machines multi-boot from one IP (the G3 does Panther and Tiger, the G5
# does Panther, Tiger and Leopard) and both partitions answer `hostname` the
# same way, so identical labels in benchmarks/results.csv can be different
# operating systems. The ssh alias IS the unique name (yosemite vs
# yosemite-tiger), so fleet-bench.sh passes it with -N and this is only the
# fallback for a hand-run bench on the machine itself.
if [ -n "$NAME" ]; then
	HOSTN=$NAME
else
	HOSTN=$(hostname -s 2>/dev/null || hostname)
fi
CFG="$VALVE/bench_tr.cfg"
# The LAUNCHER owns the engine's stdout: it ends with
#   exec "$HERE/xash3d.bin" ... >> "$LOG" 2>&1
# writing to <basedir>/last-run.log. So redirecting the launcher's own stdout
# captures nothing useful and the results must be parsed out of that file. Keep a
# copy under /tmp afterwards so consecutive runs do not overwrite each other's
# evidence.
LOG="$BASE/last-run.log"
KEEP="/tmp/bench_${HOSTN}_${REND}_${W}x${H}.log"
rm -f "$LOG" "$KEEP"

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
	# Caller-supplied cvars go in BEFORE the warmup, so the warmup frames are
	# drawn in the same state as the measured ones. Split on ';' with the field
	# separator rather than a bashism, this has to run on 10.3's sh.
	if [ -n "$EXTRA" ]; then
		echo "$EXTRA" | tr ';' '\n' | while read -r cmd; do
			[ -n "$cmd" ] && { echo "$cmd"; echo wait; }
		done
	fi
	r=0; while [ $r -lt "$WARMUPS" ]; do echo "timerefresh $FRAMES"; echo wait; r=$((r+1)); done
	r=0; while [ $r -lt "$RUNS" ];    do echo "timerefresh $FRAMES"; echo wait; r=$((r+1)); done
	echo quit
} > "$CFG"

TOTAL=$((WARMUPS + RUNS))

# ---- protect the machine's archived config ----------------------------------
# Anything -x sets that carries FCVAR_ARCHIVE or FCVAR_GLCONFIG is WRITTEN BACK to
# valve/*.cfg when the engine exits, so a one-off A/B silently becomes that
# machine's new permanent default.
#
# That is not hypothetical. Benchmarking `-x "gl_singlepass_bmodels 0"` on the G3
# archived the 0, and every later run on that machine, including runs with no -x
# at all, then measured 27.4 fps instead of 30.0 and looked exactly like a
# performance regression in the build. It cost a rebuild and a fleet redeploy to
# chase. A measurement tool must not mutate the thing it measures.
#
# So snapshot the archived configs and put them back afterwards, whatever happens.
SAVED_CFG_DIR=$(mktemp -d /tmp/benchcfg.XXXXXX 2>/dev/null || echo /tmp/benchcfg.$$)
mkdir -p "$SAVED_CFG_DIR"
for f in opengl.cfg video.cfg config.cfg; do
	[ -f "$VALVE/$f" ] && cp -p "$VALVE/$f" "$SAVED_CFG_DIR/$f" 2>/dev/null
done
restore_cfg () {
	for f in opengl.cfg video.cfg config.cfg; do
		[ -f "$SAVED_CFG_DIR/$f" ] && cp -p "$SAVED_CFG_DIR/$f" "$VALVE/$f" 2>/dev/null
	done
	rm -rf "$SAVED_CFG_DIR" 2>/dev/null
}

# ---- launch -----------------------------------------------------------------
# cd to the BASEDIR, not to Contents/MacOS: the launcher derives everything from
# its own location, and the engine's working directory should be the folder that
# holds valve/, which is how a player's double-click launch sees it.
cd "$BASE" || exit 1
# -nomsgbox is NOT optional on a machine being driven remotely. Without it any
# engine warning becomes a modal dialog on the bench machine's screen, and the
# engine BLOCKS until somebody physically walks over and clicks OK. On 2026-08-04
# that stalled a G3 run for 85 seconds and put an alert in front of the user.
#
# -width/-height + the screen-mode dash parm are read at video init and take
# priority over config.cfg (unlike the width/height/fullscreen cvars). They also
# override the launcher's built-in per-machine profile, which is what the
# launcher's caller-wins argument handling exists for.
"$LAUNCHER" -nomsgbox -nosound -ref "$REND" -width "$W" -height "$H" $MODEPARM \
	+map "$MAP" +exec bench_tr.cfg >/dev/null 2>&1 &
PID=$!

# If this script is interrupted (Ctrl-C, parent shell gone) the engine keeps
# running fullscreen with nobody watching it, and the next thing to use this Mac
# goes fullscreen on top of it - the Rage 128 / R300 wedge. TERM, wait, then KILL.
bench_cleanup () {
	restore_cfg
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
	# Bail the moment the engine says it has failed, rather than sitting here
	# until the timeout. A run that cannot load its game dylibs will never print
	# a timerefresh line, and waiting 240s to discover that wastes the operator's
	# time and holds the machine.
	if grep -q "Host_ErrorInit\|Host_Error\|missing game library" "$LOG" 2>/dev/null; then
		break
	fi
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

PLAIN=/tmp/bench_plain_$$.log
sed -E 's/\x1b\[[0-9;]*m//g' "$LOG" > "$PLAIN" 2>/dev/null
cp "$PLAIN" "$KEEP" 2>/dev/null

# ---- assert the run was the run we asked for --------------------------------
# A benchmark that reports a number for a run that did something else is worse
# than no benchmark: it becomes a recorded fact and gets reasoned from. Every
# assertion here corresponds to a way a run has actually gone wrong on this
# fleet, so each one is cheap insurance against a fabricated result.
bench_fail () {
	restore_cfg
	echo "bench.sh: $1" >&2
	echo "---- last 20 lines of $LOG ----" >&2
	tail -20 "$PLAIN" >&2
	echo "$HOSTN,$REND,${W}x${H},$SCREENMODE,$MAP,$FRAMES,ERR,ERR,ERR,"
	rm -f "$PLAIN"
	exit 1
}

# 1. The bundled read-only root must be in the search path. Without it the engine
#    finds no client/server dylib and the map never loads, while still opening a
#    window and printing GL strings - i.e. it looks fine until it is not.
grep -q "Adding directory:.*Contents/Resources/Half-Life/" "$PLAIN" ||
	bench_fail "the bundled game root was never added to the search path (launched wrongly?)"

# 2. The game dylibs must actually have loaded.
grep -q "Dll loaded for game" "$PLAIN" ||
	bench_fail "no game dylib loaded"
grep -q "missing game library" "$PLAIN" &&
	bench_fail "engine reported a missing game library for this platform"

# 3. The renderer that ran must be the renderer that was asked for. The launcher
#    used to hardcode -ref gl ahead of caller arguments, which silently turned two
#    recorded software-renderer results into GL results.
GOTREF=$(grep "Loading renderer:" "$PLAIN" | tail -1 | sed 's/.*Loading renderer: *//; s/ .*//')
if [ -n "$GOTREF" ] && [ "$GOTREF" != "$REND" ]; then
	bench_fail "asked for -ref $REND but the engine loaded '$GOTREF'"
fi

# 4. Nothing fatal happened mid-run.
grep -q "Host_ErrorInit\|Host_Error:" "$PLAIN" &&
	bench_fail "the engine raised a host error during the run"

# ---- parse results (skip warmups) -------------------------------------------
# strip ANSI, pull the fps field (6th token) from each timerefresh line
ALLFPS=$(grep "timerefresh:" "$PLAIN" | awk '{print $(NF-1)}')
MODE=$(grep "MODE:" "$PLAIN" | tail -1 | awk '{print $NF}')
GLREND=$(grep "GL_RENDERER:" "$PLAIN" | tail -1 | sed 's/.*GL_RENDERER: //')

# 5. `gl` must mean HARDWARE gl. Assertion 3 only checks which renderer module
#    loaded, and ref_gl loads perfectly happily on top of Apple's software GL
#    implementation, so the run is labelled `gl`, asserts clean, and returns a
#    number 5 to 10 times too low. That is the exact shape of fault this block
#    exists to stop: a plausible recorded fact that later gets reasoned from as
#    a renderer regression.
#
#    Measured on mini-sl (10.6.8) on 2026-08-08: GL_RENDERER: Apple Software
#    Renderer, 4.46 fps, asserting clean on every other count.
#
#    The cause is NOT the ssh session. A console user was logged in, WindowServer
#    was running, and re-entering that bootstrap namespace with
#    `sudo launchctl bsexec <loginwindow-pid>` made no difference.
#
#    Nor is it simply "headless", which was the next guess and is also wrong.
#    Measured the same day, all three over the same ssh path:
#      mini-sl      NVIDIA GeForce 9400, no display  -> Apple Software Renderer
#      mini-intel2  GMA 950,             no display  -> Intel GMA 950 OpenGL Engine
#      mini-g4      ATY RV280,     1024x768 display  -> hardware
#    So it is driver-specific: the GMA 950 hands out an accelerated context with
#    nothing plugged in, the 9400 will not. Check the machine rather than
#    assuming, and if it is one that needs a screen, a DVI/HDMI dummy EDID plug
#    is enough. Either way it is not a fault in the build, which is the whole
#    point of failing here instead of printing the number.
case "$GLREND" in
	*"Software Renderer"*|*"Software Rasterizer"*|*softpipe*|*llvmpipe*)
		if [ "$REND" = "gl" ] && [ "$ALLOW_SOFTGL" -eq 0 ]; then
			bench_fail "asked for hardware gl but got '$GLREND'.
   This number would be 5-10x too low. It is NOT a renderer regression.
   Most likely this machine is headless: check
       system_profiler SPDisplaysDataType
   and if there is no 'Displays:' entry, attach a monitor or a DVI/HDMI dummy
   plug. A logged-in console session alone is not enough.
   Pass -S if software GL is genuinely what you are measuring."
		fi
		;;
esac

# drop the warmup samples
MEAS=$(echo "$ALLFPS" | awk -v skip="$WARMUPS" 'NR>skip')
NMEAS=$(echo "$MEAS" | grep -c . )

if [ -z "$MEAS" ] || [ "$NMEAS" -lt 1 ]; then
	bench_fail "NO RESULT on $HOSTN ($REND ${W}x${H} $SCREENMODE): no timerefresh line"
fi
# Every requested sample must be present. A short run means the watchdog cut it
# off, and averaging whatever happened to land before that is how a slow run gets
# recorded as a fast one.
if [ "$NMEAS" -lt "$RUNS" ]; then
	bench_fail "only $NMEAS of $RUNS measured samples completed before the timeout"
fi

# min / median / max
SORTED=$(echo "$MEAS" | sort -n)
FMIN=$(echo "$SORTED" | head -1)
FMAX=$(echo "$SORTED" | tail -1)
FMED=$(echo "$SORTED" | awk '{a[NR]=$1} END{ if(NR%2){print a[(NR+1)/2]} else {printf "%.3f", (a[NR/2]+a[NR/2+1])/2} }')
RUNSCSV=$(echo "$MEAS" | tr '\n' '|' | sed 's/|$//')

restore_cfg
rm -f "$PLAIN"
echo "[$HOSTN] $REND ${W}x${H} $SCREENMODE (actual ${MODE:-?}) map=$MAP frames=$FRAMES${EXTRA:+ [$EXTRA]} : median ${FMED} fps  (runs: $RUNSCSV)  GPU=${GLREND:-n/a}" >&2
echo "$HOSTN,$REND,${W}x${H},$SCREENMODE,$MAP,$FRAMES,$FMIN,$FMED,$FMAX,$RUNSCSV"
