#!/bin/sh
# vm-frame-check.sh - capture a real rendered frame off qemu-tiger3d, using
# QEMU's own host-side screendump (build-host#123) instead of the guest-side
# `screenshot` console command hw-shot.sh uses on real hardware.
#
# WHY THIS EXISTS ALONGSIDE hw-shot.sh
# -------------------------------------
# hw-shot.sh's guest-side capture came back solid black on qemu-tiger3d
# (halflife#51, matches qemu#7/#8: an R300 driver frame-readback bug in this
# VM). The engine was confirmed actually rendering (real fps, real GL_RENDERER
# string in the same bench-evidence bundle) - only the guest's own readback
# path was broken. screendump reads the emulated framebuffer from QEMU
# itself, on the workstation, so it bypasses that path entirely.
#
# Run this ON THE WORKSTATION, never over ssh into the guest: screendump
# talks to QEMU's monitor socket, a local process here, not something the
# guest can reach.
#
#   scripts/vm-frame-check.sh [seconds] [out.png]
#
# pre: qemu-tiger3d claimed (scripts/pick-bench-host.sh --acquire qemu-tiger3d),
#      up, and Half-Life.app deployed (scripts/deploy-dmg.sh qemu-tiger3d).
# post: <out.png> holds one frame of whatever the guest was actually
#       displaying. Release the claim yourself once done, same as hw-shot.sh's
#       caller does - this script does not touch the lock.
#
# KNOWN CAVEAT (halflife#47, tracked separately, not fixed here): an
# ssh-launched engine on this VM does not reliably reach a focused, rendering
# game window - one run captured the Finder desktop, another an abort() in
# HIServices GetCurrentProcess during SDL init. This script proves the
# CAPTURE path works (a real framebuffer, never solid black); it does not
# guarantee the guest was showing the game when it fired. Read the PNG.
set -eu

SECS="${1:-40}"
OUT="${2:-/tmp/qemu-tiger3d-frame.png}"
HOST=qemu-tiger3d

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Launch the game on the guest via the same +exec cfg pattern hw-shot.sh uses
# (settle waits then quit, no guest-side `screenshot` line - that capture
# path is the one already known broken on this VM). Matching hw-shot.sh's
# own invocation, rather than a bare launch, since that is the one already
# known to reach a running, ssh-launched engine on this VM (halflife#51).
ssh "$HOST" bash <<'REMOTE'
set -u
cd /Applications/Half-Life || exit 2
GAME="./Half-Life.app/Contents/MacOS/xash3d"
[ -x "$GAME" ] || { echo "no Half-Life.app on qemu-tiger3d"; exit 2; }
rm -f last-run.log
{
	i=0
	while [ $i -lt 400 ]; do echo wait; i=$((i+1)); done
	echo quit
} > valve/vm-frame-check.cfg
"$GAME" -nomsgbox +exec vm-frame-check.cfg >/dev/null 2>&1 &
echo $! > /tmp/vm-frame-check.pid
REMOTE

echo "[vm-frame-check] waiting ${SECS}s for the guest to render..."
sleep "$SECS"

echo "[vm-frame-check] host-side screendump -> $OUT"
scripts/shared.sh qemu-vm.sh screendump "$OUT"

echo "[vm-frame-check] stopping the guest engine"
# Kill by PID out of ps, never pkill: Tiger has none (see hw-shot.sh).
ssh "$HOST" bash <<'REMOTE'
set -u
cd /Applications/Half-Life 2>/dev/null || exit 0
engines() { ps ax | grep '[x]ash3d' | awk '{ print $1 }'; }
for p in $(engines); do kill "$p" 2>/dev/null; done
killall xash3d.bin xash3d 2>/dev/null
sleep 2
for p in $(engines); do kill -9 "$p" 2>/dev/null; done
killall -9 xash3d.bin xash3d 2>/dev/null
killall ReportCrash CrashReporter crashreporterd 2>/dev/null
rm -f /tmp/vm-frame-check.pid valve/vm-frame-check.cfg
REMOTE

[ -s "$OUT" ] || { echo "[vm-frame-check] FAILED: $OUT missing or empty"; exit 1; }
echo "[vm-frame-check] done: $OUT"
