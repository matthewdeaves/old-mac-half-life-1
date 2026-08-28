#!/usr/bin/env bash
# Reproduce issue #18 on a real, logged-in Mac, and fail if it reproduces.
#
# #18: a menu text box killed the game on the first keystroke after the field's
# buffer was replaced by a shorter cvar value. CMenuField keeps iCursor as a
# byte index into szBuffer, and CMenuField::UpdateEditable() replaced szBuffer
# from the linked cvar without bringing iCursor back into range. Both of
# CMenuField's memmoves then take a length of the shape len - iCursor + 1,
# which is negative, and memmove's third parameter is size_t, so it converts to
# about 4 GB and the copy runs off the heap. Fixed in menu 9c7d838.
#
# THE RECIPE THIS DRIVES, and why each step is there:
#
#   The desync needs the field's buffer to SURVIVE a visit while the cvar does
#   not change. One open of a text box cannot do it: CMenuBaseWindow::Show() is
#   Init(), VidInit(), Reload(), so VidInit sets iCursor from the same string
#   Reload is about to write back. Consistent, no bug.
#
#   So: open the dialog, type extra characters (szBuffer grows, cvar unchanged
#   because the name is never committed), dismiss with Escape. The menu object
#   is persistent, so szBuffer keeps the long value. Re-open: VidInit sets
#   iCursor from the LONG buffer, then Reload -> UpdateEditable replaces it with
#   the SHORT cvar. iCursor is now past the terminator, and the next keystroke
#   is fatal.
#
#   It uses CMenuPlayerIntroduceDialog, not Multiplayer -> Customize, for one
#   reason: it is auto-focused. It derives from CMenuYesNoMessageBox, whose
#   Show() override (menu 903dc47) focuses the first text field in the dialog,
#   and its field is name.LinkCvar( "name" ). So no mouse click is needed to put
#   the keyboard in a cvar-linked field. Multiplayer -> Customize is the same
#   bug but takes focus from the mouse position, which injected keys cannot set.
#
#   The dialog is forced open by setting the name cvar to "Player", which
#   UI::Names::CheckIsNameValid (Utils.cpp) rejects along with "default" and
#   "unnamed"; menus/Multiplayer.cpp shows the dialog whenever that check fails.
#   config.cfg is backed up and restored, so the machine's own player name is
#   not disturbed.
#
# MEASURED A/B on g5-panther (dual PowerMac G5, 10.3.9), 2026-08-28, this exact
# script, same machine, same sequence, only libmenu.dylib differing:
#
#   pre-fix  (md5 9ceae18169c8a4c8a19a0213c15c3a26): pass 2 killed the process,
#            last-run.log recorded SIGSEGV at 0xffff8c80, the PowerPC commpage,
#            from CMenuField::Char+0x284. One keystroke was enough.
#   fixed    (md5 b0c2d462aa096a430500942c6aee7ad8): passes 2 and 3 both
#            survived, zero crash records.
#
# That A/B is what makes this a guard rather than a green light. If this script
# is ever changed, run it against the pre-fix dylib again and require a FAIL.
# A regression test nobody has watched fail is not known to work: the previous
# version of this script typed into ServerBrowser's addressField, which has no
# LinkCvar and so cannot desync, and it passed happily on a build with the bug
# in it.
#
# WHAT THIS CANNOT BE: a headless/CI check. It drives the real keyboard of a
# real logged-in GUI session via System Events, which needs Accessibility
# permission already granted to the ssh/osascript path and a display that is
# actually rendering. If the screen is asleep this fails rather than passes.
#
# Launch goes through `open`, not a direct exec of the binary. Executing
# xash3d.bin over ssh on 10.3 aborts in HIServices before reaching the menu,
# which looks like a crash and is not one.
#
# usage: scripts/test-text-input.sh <machine>
#   machine: any PowerPC or Intel alias smoke-dmg.sh knows. Hotkey 'm' for
#   Multiplayer is from 3rdparty/mainui/controls/PicButton.cpp's g_hotkeys[],
#   not guessed.
set -euo pipefail
HOST="${1:?usage: $0 <machine>}"

_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" --run "$HOST" "test-text-input" -- "$0" "$@"
fi
DEST_DIR="${DEST_DIR:-Desktop/Half-Life}"
CFG="\$HOME/$DEST_DIR/valve/config.cfg"
LOG="\$HOME/$DEST_DIR/last-run.log"

osa()   { ssh "$HOST" "osascript -e 'tell application \"System Events\" to $1'" >/dev/null 2>&1 || true; }
# grep -c prints 0 AND exits 1 when nothing matches, so the fallback has to be
# inside the remote shell or this emits two lines and every numeric test below
# gets a two-line string.
alive() { ssh "$HOST" "ps -axww | grep -c '[x]ash3d.bin' || true" 2>/dev/null; }

# Always put config.cfg back, however this exits.
restore_cfg() {
	ssh "$HOST" "[ -f $CFG.testbak ] && mv -f $CFG.testbak $CFG" >/dev/null 2>&1 || true
}
# PIPE included deliberately: piping this script into `head` closes the pipe
# early, and without PIPE the trap never ran and the machine was left with its
# player name set to "Player" and a stale config.cfg.testbak beside it.
trap 'ssh "$HOST" "killall -KILL xash3d.bin 2>/dev/null || true" >/dev/null 2>&1 || true; restore_cfg' EXIT INT TERM PIPE

echo "[text-input $HOST] cleaning up any stale run"
ssh "$HOST" "killall -KILL xash3d.bin 2>/dev/null || true; sleep 2; rm -f $LOG"

echo "[text-input $HOST] forcing the introduce dialog (name -> Player)"
ssh "$HOST" "cp $CFG $CFG.testbak && sed -e 's/^name \".*\"/name \"Player\"/' $CFG.testbak > $CFG"

echo "[text-input $HOST] launching via LaunchServices"
ssh "$HOST" "open \$HOME/$DEST_DIR/Half-Life.app"

# Wait for the menu, not a fixed sleep. Match the filename alone: the engine
# colours it, so the log holds "execing ESC[1;32mmainui.cfg ESC[0m" and a grep
# for the literal "execing mainui.cfg" can never match.
i=0
while [ "$i" -lt 40 ]; do
	if ssh "$HOST" "grep -q 'mainui\.cfg' $LOG 2>/dev/null"; then break; fi
	sleep 1; i=$((i+1))
done
if [ "$i" -ge 40 ]; then
	echo "[text-input $HOST] FAIL - never reached the menu"; exit 1
fi
[ "$(alive)" -ge 1 ] || { echo "[text-input $HOST] FAIL - died before the menu"; exit 1; }

# config.cfg has done its job the moment the engine has read it, so put it back
# NOW rather than leaning on the exit trap. Anything that kills this script from
# here on leaves the machine's own player name intact.
restore_cfg
echo "[text-input $HOST] config.cfg restored (name back to the machine's own)"

echo "[text-input $HOST] pass 1: open the dialog, type, dismiss (grows the buffer)"
osa 'keystroke "m"';      sleep 3
osa 'keystroke "ABCDEF"'; sleep 2
osa 'key code 53';        sleep 2   # Escape
[ "$(alive)" -ge 1 ] || { echo "[text-input $HOST] FAIL - died during pass 1"; exit 1; }

echo "[text-input $HOST] pass 2: re-open (buffer long, cvar short) and type one character"
osa 'keystroke "m"'; sleep 3
osa 'keystroke "X"'; sleep 2
ALIVE2=$(alive)

echo "[text-input $HOST] pass 3: backspace (the other memmove)"
for _ in 1 2 3 4; do osa 'key code 51'; done
sleep 2
ALIVE3=$(alive)

CRASH=$(ssh "$HOST" "grep -c '^Crash:' $LOG 2>/dev/null || true")
CRASH=${CRASH:-0}

if [ "$ALIVE2" -lt 1 ] || [ "$ALIVE3" -lt 1 ] || [ "$CRASH" -gt 0 ]; then
	echo "[text-input $HOST] FAIL - issue #18 reproduced (crash records: $CRASH)"
	echo "  alive after pass 2: $ALIVE2, after pass 3: $ALIVE3"
	ssh "$HOST" "grep -A6 '^Crash:' $LOG 2>/dev/null" | sed 's/^/  /' || true
	echo "  Symbolize the libmenu frames against the DEPLOYED dylib and the slice"
	echo "  that machine loaded, per ADR 0018. CMenuField::Char is the insert"
	echo "  memmove, CMenuField::KeyDown is the backspace one."
	exit 1
fi

echo "[text-input $HOST] PASS - typed and backspaced into a cvar-linked field"
echo "  across a dismiss/reopen cycle, which is the sequence that reproduces"
echo "  issue #18 on an unfixed build. No crash records."
