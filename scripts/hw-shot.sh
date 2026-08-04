#!/bin/sh
# hw-shot.sh - launch the game on a bench machine, capture a frame, and ALWAYS stop it.
#
#   ./hw-shot.sh [seconds] [extra engine args...]
#
# Run this ON the bench machine, from the folder holding Half-Life.app.
#
# WHY A WATCHDOG AND NOT JUST `kill $!`
# ------------------------------------
# The bundle executable is a shell launcher (docs/adr/0007): it execs xash3d.bin,
# so the PID the shell hands back is not necessarily the one still drawing. A
# `kill $!` that misses leaves the engine rendering as fast as the GPU allows,
# with no frame limiter, on a machine whose fans then run flat out until somebody
# power-cycles it. That happened to the G5 once and must not happen again.
#
# So: kill by NAME, twice, then verify nothing is left and say so. The exit
# status is about whether the machine is clean, not whether the screenshot
# worked - a stuck engine is the serious outcome.
set -u

SECS="${1:-40}"
[ $# -gt 0 ] && shift

GAME="./Half-Life.app/Contents/MacOS/xash3d"
[ -x "$GAME" ] || { echo "no Half-Life.app here ($(pwd))"; exit 2; }

# Kill by PID out of `ps`, NOT with pkill.
#
# Mac OS X 10.7 has no /usr/bin/pkill at all, and neither do 10.3 and 10.4. The
# earlier version of this script called it three times and every call failed with
# "command not found", so the watchdog silently did nothing on exactly the boxes
# it was written to protect. It only ever looked like it worked because the config
# below ends with `quit` and the engine usually stopped on its own. When it did
# not, which is the case that matters, nothing stopped it.
#
# `ps ax` and `kill` are in every one of these systems. killall is there too, as a
# second pass, but it matches on the process name only, so it cannot be the
# primary: the bundle executable is a shell launcher that execs xash3d.bin.
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
# Fires on normal exit, on Ctrl-C, and if the ssh session dies underneath us.
trap 'cleanup' EXIT INT TERM HUP

rm -f last-run.log
mkdir -p valve/scrshots
rm -f valve/scrshots/*.png valve/scrshots/*.bmp valve/scrshots/*.tga 2>/dev/null

# A config the engine execs once it is up: let the menu settle, take one frame,
# then quit itself. `wait` is one frame, so this is frame-count based rather than
# wall-clock and behaves the same on a 450 MHz G3 as on a G5.
{
	i=0
	while [ $i -lt 200 ]; do echo wait; i=$((i+1)); done
	echo "screenshot"
	i=0
	while [ $i -lt 30 ]; do echo wait; i=$((i+1)); done
	echo "quit"
} > valve/hw-shot.cfg

# -nomsgbox: see hw-play.sh. A modal crash dialog on an unattended machine costs a
# human interruption per crash, and the crash text is already in three other places.
"$GAME" -nomsgbox +exec hw-shot.cfg "$@" >/dev/null 2>&1 &
sleep "$SECS"

cleanup

LEFT=$( engines | wc -l | tr -d ' ' )
echo "engine processes left: $LEFT"
echo "screenshots:"
ls -1 valve/scrshots/ 2>/dev/null | head -5
echo "log tail:"
sed 's/\x1b\[[0-9;]*m//g' last-run.log 2>/dev/null | tail -6

[ "$LEFT" = "0" ] || { echo "!! ENGINE STILL RUNNING - INTERVENE"; exit 1; }
exit 0
