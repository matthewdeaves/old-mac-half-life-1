#!/usr/bin/env bash
# Smoke-test the DMG-installed copy on a target Mac EXACTLY as a human launches
# it: the production bundle (Half-Life.app launcher self-configures renderer +
# display mode per machine). We start it, confirm it reaches the running state
# and survives (a corrupt code slice crashes in under a second), scan the log for
# fatal errors, then quit it cleanly.
#
# This is the gate a corrupt-image bug slips past: a direct deploy can be clean
# while the human DMG-launch path crashes instantly. So we test the as-installed,
# as-launched artifact.
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
DEST_DIR="${DEST_DIR:-Desktop/Half-Life}"

case "$HOST" in
  yosemite|yosemite-tiger|g3-panther|g3-tiger)
                          MINALIVE=14; TIMEOUT=90 ;;   # G3, slowest. Both partitions.
  sawtooth|quicksilver|mini-g4) MINALIVE=10; TIMEOUT=60 ;; # G4 Tiger
  # The dual G5 multi-boots three OSes from one IP, so each partition has its own
  # alias. They were missing here, which made the machine that boots the most
  # OS versions the one this gate could not be run against at all.
  imac-g5|g5-imac|g5-panther|g5-tiger|g5-leopard|g5-desktop)
                          MINALIVE=10; TIMEOUT=60 ;;    # G5, any partition
  mini-intel|mini-intel2) MINALIVE=6;  TIMEOUT=40 ;;    # Intel Lion (both minis: same Macmini2,1)
  *) echo "unknown machine: $HOST" >&2; exit 2 ;;
esac

echo "[smoke $HOST] launching DMG-installed Half-Life.app with production config"
RESULT=$(ssh "$HOST" bash -s "$DEST_DIR" "$MINALIVE" "$TIMEOUT" <<'REMOTE_EOF'
set -u
DEST="$HOME/$1"; MINALIVE="$2"; TIMEOUT="$3"
APP="$DEST/Half-Life.app/Contents/MacOS/xash3d"
LOG="$DEST/last-run.log"

[ -x "$APP" ] || { echo "NO_INSTALL"; exit 0; }
[ -f "$DEST/valve/pak0.pak" ] || { echo "NO_DATA"; exit 0; }

# clean slate
killall -TERM xash3d.bin 2>/dev/null || true; sleep 1
killall -KILL xash3d.bin 2>/dev/null || true
rm -f "$LOG"

# The launcher execs xash3d.bin (same PID) and redirects console -> last-run.log.
"$APP" >/dev/null 2>&1 &
PID=$!
alive=0
i=0
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
  NO_INSTALL*) echo "[smoke $HOST] FAIL - Half-Life.app not installed (run deploy-dmg.sh first)"; exit 1 ;;
  NO_DATA*)    echo "[smoke $HOST] FAIL - no valve/pak0.pak (add retail game data before smoke)"; exit 1 ;;
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
