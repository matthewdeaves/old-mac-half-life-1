#!/usr/bin/env bash
# Actually open a text-entry dialog and type into it on a real, logged-in Mac,
# then confirm the process is still alive and last-run.log carries no crash.
#
# Issue #18: every prior "fix" in this area (SDL_StartTextInput gating, focus-
# on-open, Escape-to-dismiss) was verified by launching the game and reaching
# the menu - never by actually opening the dialog and typing, which is the one
# thing that reproduces the bug. This script is that missing check.
#
# It did NOT find the crash. The user did, by hand, on g5-panther. This script
# could not have: its "reached the menu" gate grepped for the literal string
# "execing mainui.cfg", which the engine writes with colour escapes inside it,
# so the gate never matched and the typing below never ran once. Corrected
# 2026-08-28. Worth remembering that a test which never reached its assertion
# reports as a failure to reach the menu, not as a pass - but nobody read it
# either way.
#
# WHAT THIS CANNOT BE: a headless/CI check. It drives the real keyboard of a
# real logged-in GUI session via System Events, which needs Accessibility
# permission already granted to the ssh/osascript path and a display that is
# actually rendering (PowerPC/Leopard's display sleep cannot be woken by
# injected input - if the screen is asleep this fails, not passes, and you
# will not get a clean answer). Run it right after using the machine for
# something else, or right after a fresh boot, not cold.
#
# The "non-deterministic heap corruption" and "SDL_DYNAPI jump table" readings
# of this bug were both wrong and are withdrawn. Root cause, measured: a cursor
# left past the end of the field's buffer makes both of CMenuField's memmoves
# compute a negative length, which memmove takes as a ~4 GB size_t. It is a
# fixed trigger, not a race - it fires on the first keystroke after the field's
# buffer is replaced by a shorter cvar value. Fixed in menu 9c7d838.
#
# A PASS here is still only evidence for the paths it actually drove.
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
	# The engine colours the filename, so the log holds
	#   execing ESC[1;32mmainui.cfg ESC[0m
	# and a grep for the literal "execing mainui.cfg" can never match. That is
	# how this gate silently failed every run: the script reported "never
	# reached the menu" on a machine sitting happily at the menu, so the typing
	# step below had never once executed. Match the filename alone.
	if ssh "$HOST" "grep -q 'mainui\.cfg' \"\$HOME/$DEST_DIR/last-run.log\" 2>/dev/null"; then
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

# Both memmoves in CMenuField have to be exercised, not just one. Typing goes
# through Char()'s insert branch; Backspace goes through KeyDown()'s. Issue #18
# was originally reported as a Backspace bug and turned out to be neither -
# both branches compute a length of the shape len - iCursor + 1, so both blow
# up on a cursor left past the terminator. Delete a chunk and retype over it.
echo "[text-input $HOST] backspacing over it and retyping"
for _ in 1 2 3 4 5 6 7 8 9 10; do osa 'key code 51' >/dev/null 2>&1 || true; done
sleep 1
osa 'keystroke "27015"'
sleep 1

# The actual check: is the process still there, and did the log pick up a
# crash record while we were typing.
#
# NOT `pgrep` (absent on 10.3/10.4/10.7) and NOT bare `ps ax`, whose COMMAND
# column truncates over a non-tty ssh pipe and cuts the line off long before
# the trailing "xash3d.bin" - the same trap that made smoke-dmg.sh report every
# healthy launch as a crash. `-axww` disables the truncation.
ALIVE=1
ssh "$HOST" "ps -axww | grep -q '[x]ash3d.bin'" || ALIVE=0
CRASH=$(ssh "$HOST" "grep -c '^Crash:' \"\$HOME/$DEST_DIR/last-run.log\" 2>/dev/null || true")

echo "[text-input $HOST] dismissing (Escape) and quitting"
osa 'key code 53' >/dev/null 2>&1 || true
ssh "$HOST" "killall -TERM xash3d.bin 2>/dev/null || true"

if [ "$ALIVE" != 1 ] || [ "${CRASH:-0}" -gt 0 ]; then
	echo "[text-input $HOST] FAIL - process died or last-run.log recorded a crash while typing (crash count: ${CRASH:-0})"
	ssh "$HOST" "grep -A3 '^Crash:' \"\$HOME/$DEST_DIR/last-run.log\" 2>/dev/null" | sed 's/^/  /' || true
	exit 1
fi

echo "[text-input $HOST] INCONCLUSIVE - survived typing into the add-server field,"
echo "  but that field CANNOT reproduce issue #18 and a pass here is not a guard."
echo
echo "  Measured 2026-08-28 by A/B on g5-panther: the pre-fix libmenu.dylib"
echo "  (md5 9ceae18169c8a4c8a19a0213c15c3a26) passes this script exactly as the"
echo "  fixed one does. Not a flaky reproduction - a structural one."
echo
echo "  ServerBrowser's addressField has no LinkCvar (menus/ServerBrowser.cpp"
echo "  around 1249). #18 needs a cvar-linked field: the crash comes from"
echo "  CMenuField::UpdateEditable() replacing the buffer from a cvar without"
echo "  resyncing iCursor, and UpdateEditable only does anything when a cvar is"
echo "  linked. A field with no cvar behind it is immune by construction."
echo
echo "  The field that does reproduce it is 'name' in Multiplayer -> Customize"
echo "  (menus/PlayerSetup.cpp, name.LinkCvar( \"name\" )). Driving it needs"
echo "  focus, and CMenuBaseWindow::Show() takes focus from the mouse position,"
echo "  so 'u' then Tab or Down does not land on it - tried both, the name cvar"
echo "  was unchanged afterwards. It likely needs a real click at the field's"
echo "  screen coordinates. Keystroke injection itself is fine on this machine:"
echo "  'q' then 'o' from the main menu quits the game, proving System Events"
echo "  keys reach it."
echo
echo "  Until this drives a cvar-linked field and asserts the cvar changed, it"
echo "  must not report PASS. See issue #18."
exit 2
