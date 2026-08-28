#!/usr/bin/env bash
# Smoke-test the DMG-installed copy on a target Mac EXACTLY as a human launches
# it: `open` on the bundle (what a Finder double-click does, i.e. through
# LaunchServices, not a direct exec of the binary) with the production config.
# We start it, confirm it reaches the running state and survives (a corrupt
# code slice crashes in under a second), scan the log for fatal errors, then
# quit it cleanly.
#
# This is the gate a corrupt-image bug OR a Gatekeeper/quarantine/signature
# rejection slips past: a direct deploy, or a direct exec of the binary, can be
# clean while the human double-click path is refused outright or crashes
# instantly. So we test the as-installed, as-launched artifact through the same
# door a human uses. Issue #19: this script used to exec the binary directly,
# which bypasses LaunchServices entirely and so could never catch what a real
# double-click hits.
#
# usage: scripts/smoke-dmg.sh <machine>
#   machine: yosemite | sawtooth | quicksilver | mini-g4 | imac-g5
#            | mini-intel | mini-intel2
#
# After this passes, start a NEW GAME by hand - reaching the menu proves the
# engine + menu + renderer came up on the production path, but not the in-game
# render/entity path.
set -euo pipefail
HOST="${1:?usage: $0 <machine>}"

# Claim this machine for the whole run. See scripts/pick-bench-host.sh.
#
# Re-exec under the picker rather than acquire-here-and-trap: bash traps REPLACE
# rather than compose, so a release trap installed at the top of a script that
# later sets its own trap is silently discarded, and the machine stays claimed
# until the stale reclaim. `--run` makes the lock a property of the INVOCATION,
# so it is released however this exits, and no caller has to remember to do it.
#
# The lock lives on the target, so it serialises across repos, agents and
# workstations, not just this checkout. It also refuses a host booted into an OS
# its alias does not name, which the multi-boot machines otherwise allow.
#
# RETRO_BENCH_LOCK names the host that is ALREADY claimed, and the test compares
# it to the host we want. A bare -z test used to mean "am I inside my own
# re-exec"; since the picker's --run started exporting the variable it would mean
# "am I inside ANY claim", so this script called from inside a claim on another
# machine would skip claiming THIS one and drive it unclaimed. Issue #13.
# BENCH_NO_LOCK=1 skips the lock, for when the picker itself is what you are
# debugging. It is not a way to get past a machine someone else is using.
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" --run "$HOST" "smoke-dmg" -- "$0" "$@"
fi
DEST_DIR="${DEST_DIR:-Desktop/Half-Life}"

case "$HOST" in
  yosemite|yosemite-tiger|g3-panther|g3-tiger)
                          MINALIVE=14; TIMEOUT=90 ;;   # G3, slowest. Both partitions.
  sawtooth|quicksilver|mini-g4) MINALIVE=10; TIMEOUT=60 ;; # G4 Tiger
  # The dual G5 multi-boots three OSes from one IP, so each partition has its own
  # alias. They were missing here, which made the machine that boots the most
  # OS versions the one this gate could not be run against at all. The quad G5
  # (quad-tiger/quad-leopard) had the same gap - "unknown machine: quad-leopard"
  # - found running the #19 launch matrix, since nothing else here exercises
  # every multi-boot alias by name.
  imac-g5|g5-imac|g5-panther|g5-tiger|g5-leopard|g5-desktop|quad-tiger|quad-leopard|g5quad-tiger|g5quad-leopard)
                          MINALIVE=10; TIMEOUT=60 ;;    # G5, any partition
  mini-intel|mini-intel2) MINALIVE=6;  TIMEOUT=40 ;;    # Intel Lion (both minis: same Macmini2,1)
  mini-sl|snow-build1)    MINALIVE=6;  TIMEOUT=40 ;;    # Intel Snow Leopard (Macmini3,1), the 10.6 floor
  imac-2019|imac|sequoia-build) MINALIVE=6; TIMEOUT=40 ;; # 2019 Intel 5K iMac (macOS 15.7 Sequoia)
  *) echo "unknown machine: $HOST" >&2; exit 2 ;;
esac

echo "[smoke $HOST] launching DMG-installed Half-Life.app via LaunchServices (open), like a Finder double-click"
RESULT=$(ssh "$HOST" bash -s "$DEST_DIR" "$MINALIVE" "$TIMEOUT" <<'REMOTE_EOF'
set -u
DEST="$HOME/$1"; MINALIVE="$2"; TIMEOUT="$3"
BUNDLE="$DEST/Half-Life.app"
APP="$BUNDLE/Contents/MacOS/xash3d"
LOG="$DEST/last-run.log"

[ -x "$APP" ] || { echo "NO_INSTALL"; exit 0; }
[ -f "$DEST/valve/pak0.pak" ] || { echo "NO_DATA"; exit 0; }

# clean slate
killall -TERM xash3d.bin 2>/dev/null || true; sleep 1
killall -KILL xash3d.bin 2>/dev/null || true

# Keep the previous run's log instead of deleting it. The engine's crash
# handler writes the "Crash:" line and its symbolizable module+offset frames
# here, and per ADR 0018 that file is the first thing to read when a fleet
# machine crashes. Deleting it meant a smoke run destroyed the evidence from
# whatever went wrong just before it, which is exactly when someone is about to
# ask. One generation back is enough to cover "run the smoke test, then look".
[ -f "$LOG" ] && mv -f "$LOG" "$DEST/last-run.prev.log" 2>/dev/null || true
rm -f "$LOG"

# `open` is what a Finder double-click does: it goes through LaunchServices,
# which is what actually runs Gatekeeper's assessment. Direct exec of the
# binary (the old path here) skips LaunchServices entirely, so it could never
# catch a quarantine/signature/Info.plist rejection a real double-click hits -
# issue #19, "CLI/ssh exec passing while double-click fails". `open` returns as
# soon as the launch REQUEST is accepted or refused; it does not wait for the
# app, so a refusal is caught here and the app's own liveness is polled by PID
# separately below, the same as before.
OPEN_ERR=$(open "$BUNDLE" 2>&1 >/dev/null) || { echo "OPEN_REJECTED"; echo "OPENERR=$OPEN_ERR"; exit 0; }

PID=""
i=0
while [ "$i" -lt "$TIMEOUT" ]; do
  # Plain `ps ax`, not `ps -o comm`: Tiger's ps has no comm keyword at all
  # ("ps: comm: keyword not found"). And `-ww`, not bare `ps ax`: without it
  # BSD ps truncates COMMAND to terminal width, which over a non-tty ssh pipe
  # cut the line off at ".../Half-Life.app/Contents/" - before "xash3d.bin"
  # ever appeared - so this found nothing and spun for the full TIMEOUT even
  # though the game was running. Measured on quicksilver (Tiger G4). `ps -axww`
  # works back to 10.3.
  PID=$(ps -axww | grep -F "xash3d.bin" | grep -v grep | awk '{print $1; exit}')
  [ -n "$PID" ] && break
  sleep 1; i=$((i+1))
done
if [ -z "$PID" ]; then
  echo "ALIVE=0 LOGSIZE=0"
  echo "----LOGTAIL----"
  [ -f "$LOG" ] && tail -15 "$LOG" 2>/dev/null || true
  exit 0
fi

alive=0
while [ "$i" -lt "$TIMEOUT" ]; do
  if ! kill -0 "$PID" 2>/dev/null; then break; fi   # died - capture below
  alive=$((alive+1))
  [ "$alive" -ge "$MINALIVE" ] && break             # survived long enough
  sleep 1; i=$((i+1))
done

# quit cleanly: TERM before KILL (a hard KILL can wedge the PPC display LUT).
killall -TERM xash3d.bin 2>/dev/null || true; sleep 2
killall -KILL xash3d.bin 2>/dev/null || true
wait "$PID" 2>/dev/null || true

LOGSIZE=0; [ -f "$LOG" ] && LOGSIZE=$(wc -c < "$LOG" | tr -d ' ')
ERR=$(grep -aE 'Sys_Error|EXC_|illegal instruction|Segmentation|Bus error|Abort' "$LOG" 2>/dev/null | head -1 || true)
echo "ALIVE=$alive LOGSIZE=$LOGSIZE"
[ -n "$ERR" ] && echo "ERRLINE=$ERR"
echo "----LOGTAIL----"
[ -f "$LOG" ] && tail -15 "$LOG" 2>/dev/null || true
REMOTE_EOF
)

echo "$RESULT" | sed 's/^/  /'

case "$RESULT" in
  NO_INSTALL*)    echo "[smoke $HOST] FAIL - Half-Life.app not installed (run deploy-dmg.sh first)"; exit 1 ;;
  NO_DATA*)       echo "[smoke $HOST] FAIL - no valve/pak0.pak (add retail game data before smoke)"; exit 1 ;;
  OPEN_REJECTED*) echo "[smoke $HOST] FAIL - LaunchServices refused the launch (exactly what a real double-click hits: Gatekeeper/quarantine/signature/Info.plist)"; exit 1 ;;
esac

ALIVE=$(printf '%s\n' "$RESULT" | sed -n 's/^ALIVE=\([0-9]*\).*/\1/p' | head -1)
# Use the threshold decided at the top of this script. There used to be a second
# copy of that case statement here, and the two had to agree by hand: adding a
# host to one and not the other left MINALIVE_CHK empty, and the comparison below
# then failed with "integer expected" and reported the machine as a CRASH. A
# smoke gate that reports a working build as broken is worse than no gate.
MINALIVE_CHK="$MINALIVE"
if printf '%s' "$RESULT" | grep -q '^ERRLINE='; then
  echo "[smoke $HOST] FAIL - fatal error in log during production launch"; exit 1
fi
if [ "${ALIVE:-0}" -ge "$MINALIVE_CHK" ]; then
  echo "[smoke $HOST] PASS - reached running state and survived ${ALIVE}s on the production path, no fatal errors"
  exit 0
else
  echo "[smoke $HOST] FAIL - process did not survive to the running state (crash or early exit after ${ALIVE:-0}s)"; exit 1
fi
