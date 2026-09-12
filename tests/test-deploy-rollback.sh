#!/bin/sh
# Exercise both a promoted fixture and a simulated interrupted promotion.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/deploy-rollback.sh"
TMP="$(mktemp -d -t hl-deploy-rollback)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
DEST="$TMP/Half-Life"
[ "$(HOME="$TMP/home" "$HELPER" root)" = "$TMP/home/oldmac/halflife/rollback" ] || {
	echo "unexpected default rollback root" >&2; exit 1; }

seed_old() {
	mkdir -p "$DEST/valve/cl_dlls" "$DEST/valve/dlls" "$DEST/valve/gfx/shell/mods" "$DEST/mod-user"
	echo old-app > "$DEST/Half-Life.app"
	echo old-mods > "$DEST/Half-Life Mods.app"
	echo old-report > "$DEST/Half-Life System Report.app"
	echo old-client > "$DEST/valve/cl_dlls/client_ppc.dylib"
	echo old-game > "$DEST/valve/dlls/hl_ppc.dylib"
	echo old-config > "$DEST/valve/userconfig.cfg"
	echo old-log > "$DEST/valve/last-run.log"
	echo old-art > "$DEST/valve/gfx/shell/mods/banner.tga"
	echo player-data > "$DEST/valve/pak0.pak"
	echo player-mod > "$DEST/mod-user/liblist.gam"
	echo finder-state > "$DEST/.DS_Store"
}

assert_eq() { [ "$(cat "$1")" = "$2" ] || { echo "expected $1 to contain $2" >&2; exit 1; }; }

seed_old
ROLLBACK="$TMP/rollback"
"$HELPER" backup "$DEST" "$ROLLBACK" candidate-fixture >/dev/null
[ -x "$ROLLBACK/RESTORE.sh" ]
[ -f "$ROLLBACK/manifest" ]

# Passing promotion: only deploy-owned paths change; player data remains.
rm -rf "$DEST/Half-Life.app" "$DEST/Half-Life Mods.app" "$DEST/Half-Life System Report.app"
echo new-app > "$DEST/Half-Life.app"
echo new-mods > "$DEST/Half-Life Mods.app"
echo new-report > "$DEST/Half-Life System Report.app"
rm -rf "$DEST/valve/cl_dlls" "$DEST/valve/dlls" "$DEST/valve/gfx/shell/mods"
rm -f "$DEST/valve/userconfig.cfg" "$DEST/valve/last-run.log" "$DEST/.DS_Store"
assert_eq "$DEST/Half-Life.app" new-app
assert_eq "$DEST/valve/pak0.pak" player-data
assert_eq "$DEST/mod-user/liblist.gam" player-mod

# Failure recovery: restore every backed-up owned path and leave user data alone.
"$ROLLBACK/RESTORE.sh" "$DEST" >/dev/null
assert_eq "$DEST/Half-Life.app" old-app
assert_eq "$DEST/Half-Life Mods.app" old-mods
assert_eq "$DEST/Half-Life System Report.app" old-report
assert_eq "$DEST/valve/cl_dlls/client_ppc.dylib" old-client
assert_eq "$DEST/valve/dlls/hl_ppc.dylib" old-game
assert_eq "$DEST/valve/userconfig.cfg" old-config
assert_eq "$DEST/valve/last-run.log" old-log
assert_eq "$DEST/valve/gfx/shell/mods/banner.tga" old-art
assert_eq "$DEST/.DS_Store" finder-state
assert_eq "$DEST/valve/pak0.pak" player-data
assert_eq "$DEST/mod-user/liblist.gam" player-mod

# A corrupt later saved payload must fail before changing the first app bundle.
BAD="$TMP/bad-rollback"
"$HELPER" backup "$DEST" "$BAD" interrupted-fixture >/dev/null
rm -f "$BAD/payload/Half-Life System Report.app"
rm -rf "$DEST/Half-Life.app"
echo candidate-after-failure > "$DEST/Half-Life.app"
if "$BAD/RESTORE.sh" "$DEST" >/dev/null 2>&1; then
	echo "restore unexpectedly accepted a missing payload" >&2; exit 1
fi
assert_eq "$DEST/Half-Life.app" candidate-after-failure
assert_eq "$DEST/valve/pak0.pak" player-data
echo "deploy rollback fixtures: promoted and restored"
