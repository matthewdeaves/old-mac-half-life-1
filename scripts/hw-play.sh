#!/bin/sh
# hw-play.sh - load a real map on a bench machine, capture a frame, and ALWAYS stop it.
#
#   ./hw-play.sh [map] [seconds] [extra engine args...]
#
# Run this ON the bench machine, from the folder holding Half-Life.app.
#
# WHY THIS EXISTS ALONGSIDE hw-shot.sh
#
# hw-shot.sh photographs the main menu, which proves the engine starts, finds its
# payload, creates a GL context and draws. It says almost nothing about the game:
# the menu is drawn by the menu dll and needs no map, no game dylib and no AI.
#
# This one loads a map. That is what exercises the parts a menu shot cannot reach:
# the server and client game dylibs, the BSP and model loaders, the lightmaps, and
# the AI node graph, which the game generates on first load of a map and caches to
# disk. Those are the pieces where a byte-order fault would show, and where a
# screenshot of a menu would happily report success while the game was unplayable.
#
# c1a0 is the default rather than c0a0. Both load, but c1a0 has scientists and
# guards walking a route, so it builds and then uses the node graph, and a frame
# taken there shows whether they are actually pathing.
#
# The watchdog is the same as hw-shot.sh, for the same reason: see that file.
set -u

MAP="${1:-c1a0}"
[ $# -gt 0 ] && shift
SECS="${1:-180}"
[ $# -gt 0 ] && shift

GAME="./Half-Life.app/Contents/MacOS/xash3d"
[ -x "$GAME" ] || { echo "no Half-Life.app here ($(pwd))"; exit 2; }
[ -f "valve/maps/$MAP.bsp" ] || echo "warning: valve/maps/$MAP.bsp not found, the engine will say so"

# Kill by PID out of `ps`, NOT with pkill: 10.3, 10.4 and 10.7 have no pkill.
engines() {
	ps ax | grep '[x]ash3d' | awk '{ print $1 }'
}

cleanup() {
	for p in $( engines ); do kill    "$p" 2>/dev/null; done
	killall xash3d.bin xash3d 2>/dev/null
	sleep 2
	for p in $( engines ); do kill -9 "$p" 2>/dev/null; done
	killall -9 xash3d.bin xash3d 2>/dev/null
	# macOS puts up a "quit unexpectedly" dialog when the engine crashes, and that
	# dialog outlives the process. Left alone it sits on the screen until somebody
	# walks over and clicks it, which is no good on a machine being driven remotely.
	# The reporter is ReportCrash on 10.5 and later and CrashReporter on 10.3 and
	# 10.4, so both names are covered, along with the dialog window itself.
	killall ReportCrash CrashReporter crashreporterd 2>/dev/null
	for p in $( ps ax | grep -E '[R]eportCrash|[C]rashReporter' | awk '{ print $1 }' ); do
		kill -9 "$p" 2>/dev/null
	done
	sleep 1
}
trap 'cleanup' EXIT INT TERM HUP

rm -f last-run.log
mkdir -p valve/scrshots
rm -f valve/scrshots/*.png valve/scrshots/*.bmp valve/scrshots/*.tga 2>/dev/null

# `wait` is one FRAME, not one second, so none of these tick while the map is
# loading. That is what makes the same counts work on a 450 MHz G3 and on a G5:
# the settle is measured in frames drawn, not in time passed.
{
	i=0; while [ $i -lt 120 ]; do echo wait; i=$((i+1)); done   # let the menu settle
	echo "map $MAP"
	i=0; while [ $i -lt 400 ]; do echo wait; i=$((i+1)); done   # let the level run a little
	echo "screenshot"
	i=0; while [ $i -lt 30 ]; do echo wait; i=$((i+1)); done
	echo "quit"
} > valve/hw-play.cfg

"$GAME" +exec hw-play.cfg "$@" >/dev/null 2>&1 &
sleep "$SECS"

cleanup

LEFT=$( engines | wc -l | tr -d ' ' )
echo "map: $MAP"
echo "engine processes left: $LEFT"
echo "screenshots:"
ls -1 valve/scrshots/ 2>/dev/null | head -5
echo "log tail:"
sed 's/\x1b\[[0-9;]*m//g' last-run.log 2>/dev/null | tail -8

[ "$LEFT" = "0" ] || { echo "!! ENGINE STILL RUNNING - INTERVENE"; exit 1; }
exit 0
