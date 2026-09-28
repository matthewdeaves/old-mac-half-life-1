#!/bin/sh
# Host framebuffer smoke capture; not the deterministic check-frames baseline.
# Capture Half-Life gameplay from QEMU's framebuffer, bypassing qemu#7
# guest glReadPixels. Run on the workstation with the VM installed.
# usage: scripts/vm-frame-check.sh [readiness-timeout-seconds] [out.png]
set -eu
SECS="${1:-120}"
OUT="${2:-/tmp/qemu-tiger3d-frame.png}"
HOST=qemu-tiger3d
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ]; then
    exec scripts/shared.sh pick-bench-host.sh --run "$HOST" vm-frame-check -- "$0" "$@"
fi
case "$SECS" in ''|*[!0-9]*|0) echo 'timeout must be positive' >&2; exit 2;; esac
ssh "$HOST" ': > /Applications/Half-Life/last-run.log'
# build-host#147: the game starts through the shared launch guard, which
# refuses if any game already runs on the guest, holds one ssh session open
# for the engine's life and arms a watchdog. The on-guest script forwards TERM
# to the engine and removes the cfg it wrote.
ssh "$HOST" 'cat > /tmp/hl-vmshot.sh' <<'REMOTE'
set -e
cd /Applications/Half-Life
[ ! -e valve/vmshot.cfg ] || { echo "vmshot.cfg already exists" >&2; exit 2; }
trap 'rm -f valve/vmshot.cfg' EXIT
{
    i=0; while [ $i -lt 600 ]; do echo wait; i=$((i+1)); done
    echo 'echo VM_CAPTURE_READY'
    i=0; while [ $i -lt 1200 ]; do echo wait; i=$((i+1)); done
    echo quit
} > valve/vmshot.cfg
./Half-Life.app/Contents/MacOS/xash3d -nomsgbox -nosound -ref gl \
    -width 1024 -height 768 -fullscreen +map c0a0 +exec vmshot.cfg >/dev/null 2>&1 &
gp=$!
trap 'kill -TERM $gp 2>/dev/null' TERM INT
wait $gp || true
wait $gp 2>/dev/null || true
REMOTE
LG="$(scripts/shared.sh launch-game.sh "$HOST" xash3d --max-secs 900 -- /bin/bash /tmp/hl-vmshot.sh)" || {
    echo "[vm-frame-check] launch refused or failed: $LG" >&2; exit 2;
}
SESSION_PID="$(printf '%s\n' "$LG" | sed -n 's/^PID \([0-9][0-9]*\)$/\1/p')"
[ -n "$SESSION_PID" ] || { echo "[vm-frame-check] no pid from launch-game.sh: $LG" >&2; exit 2; }
trap 'scripts/shared.sh launch-game.sh --stop "$HOST" "$SESSION_PID" >/dev/null 2>&1' INT TERM
guest_alive() { ssh -o ConnectTimeout=15 "$HOST" "kill -0 $SESSION_PID" >/dev/null 2>&1; }
captured=0
i=0
while [ "$i" -lt "$SECS" ] && guest_alive; do
    if ssh "$HOST" 'grep -q VM_CAPTURE_READY /Applications/Half-Life/last-run.log'; then
        scripts/shared.sh qemu-vm.sh screendump "$OUT"
        captured=1
        break
    fi
    sleep 1
    i=$((i+1))
done
# The cfg always asks the engine to quit; do not SIGKILL a fullscreen R300
# process. Keep waiting for its clean exit even if capture timed out.
while guest_alive; do sleep 2; done
trap - INT TERM
[ "$captured" = 1 ] && [ -s "$OUT" ] || {
    echo '[vm-frame-check] no gameplay frame captured' >&2; exit 1;
}
echo "[vm-frame-check] captured gameplay and exited cleanly: $OUT"
