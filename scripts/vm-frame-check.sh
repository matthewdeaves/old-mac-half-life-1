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
# build-host#147: the shared launch guard's game list decides whether a game
# already runs. Its detached launch mode is not used: a detached xash3d.bin on
# Tiger aborts in HIServices (see the comment below on the held ssh session).
RUNNING="$(scripts/shared.sh launch-game.sh --check "$HOST")" || {
    echo "[vm-frame-check] game probe failed: $RUNNING" >&2; exit 2;
}
if [ -n "$RUNNING" ]; then
    echo "A game is already running; quit it before capturing: $RUNNING" >&2
    exit 2
fi
ssh "$HOST" ': > /Applications/Half-Life/last-run.log'
# Keep the SSH bootstrap session alive until the engine quits. Closing it
# after a remote background launch can break Tiger GUI initialization.
ssh "$HOST" bash <<'REMOTE' &
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
    -width 1024 -height 768 -fullscreen +map c0a0 +exec vmshot.cfg >/dev/null 2>&1
REMOTE
SESSION_PID=$!
captured=0
i=0
while [ "$i" -lt "$SECS" ] && kill -0 "$SESSION_PID" 2>/dev/null; do
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
wait "$SESSION_PID"
[ "$captured" = 1 ] && [ -s "$OUT" ] || {
    echo '[vm-frame-check] no gameplay frame captured' >&2; exit 1;
}
echo "[vm-frame-check] captured gameplay and exited cleanly: $OUT"
