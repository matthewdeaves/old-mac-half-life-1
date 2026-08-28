#!/usr/bin/env bash
# Actually open a text-entry dialog and type into it on a real, logged-in Mac,
# then confirm the process is still alive and last-run.log carries no crash.
#
# Issue #18: every prior "fix" in this area (SDL_StartTextInput gating, focus-
# on-open, Escape-to-dismiss) was verified by launching the game and reaching
# the menu - never by actually opening the dialog and typing, which is the one
# thing that reproduces the bug. This script is that missing check. It found,
# hands-on, a genuine PowerPC crash (SIGBUS in CMenuItemsHolder::Key) that
# every earlier smoke test missed, because none of them typed anything.
#
# WHAT THIS CANNOT BE: a headless/CI check. It drives the real keyboard of a
# real logged-in GUI session via System Events, which needs Accessibility
# permission already granted to the ssh/osascript path and a display that is
# actually rendering (PowerPC/Leopard's display sleep cannot be woken by
# injected input - if the screen is asleep this fails, not passes, and you
# will not get a clean answer). Run it right after using the machine for
# something else, or right after a fresh boot, not cold.
#
# Non-deterministic by nature: the underlying bug (if present) is believed to
# be a heap-corruption timing issue, not a fixed trigger - see issue #18's
# writeup. A single PASS is evidence, not proof. Run it more than once before
# trusting a quiet run, especially after any change anywhere near menu init,
# audio init, or allocation patterns generally - the crash has shown up
# alongside an unrelated CoreAudio fault, not only in isolation.
#
# usage: scripts/test-text-input.sh <machine>
#   machine: any PowerPC or Intel alias smoke-dmg.sh knows. Hotkeys below are
#   sourced from 3rdparty/mainui/controls/PicButton.cpp's g_hotkeys[] table,
#   not guessed - 'm' Multiplayer, 'i' Internet game, 'a' Add server.
set -euo pipefail
HOST="${1:?usage: $0 <machine>}"

_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" --run "$HOST" "test-text-input" -- "$0" "$@"
fi
DEST_DIR="${DEST_DIR:-Desktop/Half-Life}"

osa() { ssh "$HOST" "osascript -e 'tell application \"System Events\" to $1'" 2>&1; }

echo "[text-input $HOST] cleaning up any stale run"
ssh "$HOST" "killall -TERM xash3d.bin 2>/dev/null || true; sleep 1; rm -f \"\$HOME/$DEST_DIR/last-run.log\""

echo "[text-input $HOST] launching via LaunchServices"
ssh "$HOST" "open \"\$HOME/$DEST_DIR/Half-Life.app\""

# Wait for the menu, not a fixed sleep: poll the log for the last thing it
# execs on the way to the menu.
i=0
while [ "$i" -lt 30 ]; do
	if ssh "$HOST" "grep -q 'execing mainui.cfg' \"\$HOME/$DEST_DIR/last-run.log\" 2>/dev/null"; then
		break
	fi
	sleep 1; i=$((i+1))
done
if [ "$i" -ge 30 ]; then
	echo "[text-input $HOST] FAIL - never reached the menu"; exit 1
fi

echo "[text-input $HOST] Multiplayer -> Internet game -> Add server"
osa 'keystroke "m"'; sleep 1
osa 'keystroke "i"'; sleep 2
osa 'keystroke "a"'; sleep 1

echo "[text-input $HOST] typing into the address field"
osa 'keystroke "209.255.10.255:27015"'
sleep 1

# The actual check: is the process still there, and did the log pick up a
# crash record while we were typing.
ALIVE=1
ssh "$HOST" "pgrep -f xash3d.bin >/dev/null 2>&1 || ps ax | grep -q '[x]ash3d.bin'" || ALIVE=0
CRASH=$(ssh "$HOST" "grep -c '^Crash:' \"\$HOME/$DEST_DIR/last-run.log\" 2>/dev/null || true")

echo "[text-input $HOST] dismissing (Escape) and quitting"
osa 'key code 53' >/dev/null 2>&1 || true
ssh "$HOST" "killall -TERM xash3d.bin 2>/dev/null || true"

if [ "$ALIVE" != 1 ] || [ "${CRASH:-0}" -gt 0 ]; then
	echo "[text-input $HOST] FAIL - process died or last-run.log recorded a crash while typing (crash count: ${CRASH:-0})"
	ssh "$HOST" "grep -A3 '^Crash:' \"\$HOME/$DEST_DIR/last-run.log\" 2>/dev/null" | sed 's/^/  /' || true
	exit 1
fi

echo "[text-input $HOST] PASS - survived typing into the add-server field"
