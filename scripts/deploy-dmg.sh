#!/usr/bin/env bash
# Install the release DMG onto a target Mac the way an end user would: copy the
# .dmg to the Desktop, mount it, copy its contents into the game folder, unmount.
# This is deliberately the DMG path (not a direct rsync) so the test loop
# exercises the exact artifact and install steps a human performs - that is where
# a corrupt-image bug would hide (a direct deploy can be clean while the DMG is not).
#
# usage: scripts/deploy-dmg.sh <machine> [version]
#   machine: yosemite | sawtooth | quicksilver | mini-g4 | imac-g5
#            | mini-intel | mini-intel2   (ssh alias)
#   version: e.g. v0.21  (default: newest dist/Half-Life-OldMac-*.dmg)
#
# Preserves your game data: the retail files in the target's valve/ (pak0.pak,
# *.wad, maps/, models/, sound/, ...) are left untouched. From v1.2.0 the image
# carries no valve/ at all - our game code rides inside Half-Life.app - so this
# only installs the two apps, and then REMOVES the game code an older release left
# in valve/. That cleanup is not optional: the player's valve/ is a higher-priority
# searchpath than the app's read-only root, so a leftover hl_ppc.dylib from the
# previous release would silently keep being loaded in place of the new one.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOST="${1:?usage: $0 <machine> [version]}"
VERSION="${2:-}"
if [ -z "$VERSION" ]; then
  # `|| true` is required, not defensive: under `set -o pipefail` a failing ls
  # makes the whole substitution non-zero and `set -e` exits right here, so the
  # "no dmg found" message below could never print.
  DMG=$(ls -t "$REPO_ROOT"/dist/Half-Life-OldMac-*.dmg 2>/dev/null | head -1) || true
  [ -n "$DMG" ] || { echo "no dist/Half-Life-OldMac-*.dmg found - run scripts/make-dmg.sh" >&2; exit 1; }
else
  DMG="$REPO_ROOT/dist/Half-Life-OldMac-$VERSION.dmg"
  [ -f "$DMG" ] || { echo "missing $DMG" >&2; exit 1; }
fi
DMG_BASE=$(basename "$DMG")
DEST_DIR="${DEST_DIR:-Desktop/Half-Life}"   # relative to the target's home

# Claim the machine for the whole run. See scripts/pick-bench-host.sh.
#
# Re-exec under the picker rather than acquire-here-and-trap, matching the other
# three ports: bash traps REPLACE rather than compose, so a release trap set here
# would be silently discarded by any trap installed later. `--run` makes the lock
# a property of the INVOCATION, released however this exits.
#
# This matters here specifically because the script deletes and replaces three
# .app bundles in the player's game folder. Doing that while another session is
# mid-bench swaps the binary out from under a running engine, and the numbers
# that come back look like a real measurement of a build that was never fully
# installed. The picker also refuses a host booted into an OS its alias does not
# name, so `deploy-dmg.sh quad-tiger` cannot silently install onto Leopard.
#
# RETRO_BENCH_LOCK names the host that is ALREADY claimed, and the test compares
# it to the host we want. A bare -z test used to mean "am I inside my own
# re-exec"; since the picker's --run started exporting the variable it would mean
# "am I inside ANY claim", so this script called from inside a claim on another
# machine would skip claiming THIS one and drive it unclaimed. Issue #13.
# BENCH_NO_LOCK=1 skips the lock, for debugging the picker itself.
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
  export RETRO_BENCH_LOCK="$HOST"
  exec "$_PICK" --run "$HOST" "deploy-dmg" -- "$0" "$@"
fi

echo "[deploy-dmg $HOST] copy $DMG_BASE to ~/Desktop/"
ssh "$HOST" 'mkdir -p ~/Desktop'

# Remove any previously-shipped release DMGs first (scoped to our own release
# artifacts; the user's files are never touched) so stale versions don't pile up
# and a leftover same-name image can't be silently reused after a failed scp.
OLD=$(ssh "$HOST" 'ls -1 ~/Desktop/Half-Life-OldMac-*.dmg 2>/dev/null || true')
if [ -n "$OLD" ]; then
  echo "[deploy-dmg $HOST] removing old release DMG(s):"; echo "$OLD" | sed 's/^/    /'
  ssh "$HOST" 'rm -f ~/Desktop/Half-Life-OldMac-*.dmg'
fi

scp -q "$DMG" "$HOST:Desktop/$DMG_BASE"

# Verify the .dmg arrived intact (md5 local vs remote) - defence in depth on top
# of make-dmg.sh's end-to-end content check.
LCL_MD5=$(md5 -q "$DMG" 2>/dev/null || md5sum "$DMG" 2>/dev/null | awk '{print $1}')
RMT_MD5=$(ssh "$HOST" "md5 'Desktop/$DMG_BASE' | awk '{print \$NF}'")
[ "$LCL_MD5" = "$RMT_MD5" ] || { echo "[deploy-dmg $HOST] FATAL: scp corrupted the DMG ($LCL_MD5 != $RMT_MD5)" >&2; exit 1; }
echo "[deploy-dmg $HOST] DMG on Desktop verified intact ($RMT_MD5)"

echo "[deploy-dmg $HOST] mount + install into ~/$DEST_DIR/ (preserving retail valve/ data)"
ssh "$HOST" bash -s "$DMG_BASE" "$DEST_DIR" <<'REMOTE_EOF'
set -e
DMG_BASE="$1"; DEST_DIR="$2"
MNT="$HOME/hlinstall-mnt"
DEST="$HOME/$DEST_DIR"

# fresh mountpoint - detach any stale attach, then rmdir (never rm -rf a path
# that might still be a mounted read-only volume).
hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true
rmdir "$MNT" 2>/dev/null || true
mkdir -p "$MNT"
# Keep the attach output: we need the /dev/diskN out of it. On 10.3
# `hdiutil detach <mountpoint>` fails unconditionally ("No such file or
# directory") even for a mountpoint we just asked for, while detaching the device
# node works. Measured on the G3 under Panther, where this script was silently
# leaving the image mounted after every deploy.
ATTACH_OUT=$(hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$HOME/Desktop/$DMG_BASE")
DEV=$(echo "$ATTACH_OUT" | awk '/^\/dev\/disk/ { print $1; exit }')

mkdir -p "$DEST/valve"
# Replace the app wholesale so no stale bundle files survive. ditto keeps the
# bundle bit, perms (+x on the launcher) and resource forks (the icon).
rm -rf "$DEST/Half-Life.app"
ditto "$MNT/Half-Life.app" "$DEST/Half-Life.app"
# The mod installer, when the image carries one (v1.2.0+). Replaced wholesale for
# the same reason as the engine app. Optional: engine-only images are still valid,
# and an older DMG must keep deploying cleanly.
if [ -d "$MNT/Half-Life Mods.app" ]; then
	rm -rf "$DEST/Half-Life Mods.app"
	ditto "$MNT/Half-Life Mods.app" "$DEST/Half-Life Mods.app"
	echo "mod installer: installed"
else
	echo "mod installer: not on this image (engine-only release)"
fi

# The system report app. Optional in the same way the installer is: an older image
# will not have it, and that is not a reason to fail the deploy.
if [ -d "$MNT/Half-Life System Report.app" ]; then
	rm -rf "$DEST/Half-Life System Report.app"
	ditto "$MNT/Half-Life System Report.app" "$DEST/Half-Life System Report.app"
	echo "installed: Half-Life System Report.app"
fi

# Strip com.apple.quarantine on every installed bundle. ditto/scp from our own
# pipeline never sets it, but the image this script installs from can arrive by
# a route that does (AirDrop, a browser download, a Mail attachment), and a
# quarantined ad-hoc-signed app is exactly what Gatekeeper blocks on a real
# Finder double-click while a direct exec (our old smoke path) never notices.
# Defence in depth: cheap, idempotent, never fatal if the flag was never set.
#
# `xattr -d -r` (recursive), not `-dr`: Leopard's xattr has no -r at all
# ("usage: xattr [-l] file ... / -p / -w / -d"), so `-dr` was an unrecognized
# option that printed usage and did nothing - harmless here since our own
# pipeline never sets the flag, but silently no-op on the one OS that most
# needs a working fallback. `find | xargs` works on every OS back to 10.3,
# with or without -r.
for app in "$DEST/Half-Life.app" "$DEST/Half-Life Mods.app" "$DEST/Half-Life System Report.app"; do
	[ -d "$app" ] || continue
	find "$app" -print0 2>/dev/null | xargs -0 xattr -d com.apple.quarantine 2>/dev/null || true
done

# Verify the signature survived the install byte-for-byte. make-dmg.sh ad-hoc
# signs every bundle and checks it there; this catches corruption introduced
# between the image and the installed copy (issue #19: found genuinely broken
# on imac-2019 - ditto alone was clean in isolation, so something about that
# machine's prior install state broke it, not this script). A signature that
# fails codesign -v also fails spctl and is refused by LaunchServices on a
# real double-click, so this must be fatal - ON A PLATFORM WHERE IT MEANS
# ANYTHING. Leopard's own codesign (introduced in 10.5, the format has moved
# on hugely since) reports this dev box's modern ad-hoc signature as "code or
# signature modified" on a bundle a fresh `ditto` produced seconds earlier -
# a tool-version mismatch, not corruption, and there is no Gatekeeper on
# PowerPC to reject anything anyway. Measured on g5-desktop (10.5.8): the
# freshly-mounted, untouched DMG's own Half-Life.app already fails this
# machine's codesign -v. Fatal only on non-PowerPC, where LaunchServices can
# actually act on the answer; a non-fatal note everywhere else.
if command -v codesign >/dev/null 2>&1 && [ "$(uname -p)" != "powerpc" ]; then
	for app in "$DEST/Half-Life.app" "$DEST/Half-Life Mods.app" "$DEST/Half-Life System Report.app"; do
		[ -d "$app" ] || continue
		codesign -v "$app" 2>&1 || { echo "FATAL: $(basename "$app") signature is invalid after install" >&2; exit 1; }
	done
	echo "signatures verified on the installed bundles"
fi

# Old releases put our game code, default config and mod artwork INSIDE the
# player's valve/. All of that now ships inside Half-Life.app, and valve/ outranks
# the app's read-only root in the search path, so anything left behind would shadow
# what we just installed - the player would keep running the previous release's
# game code with no sign anything was wrong. Remove exactly the files we ever put
# there, by name, and nothing else: retail data (pak0.pak, *.wad, maps/, models/,
# the Windows client.dll and hl.dll) is never touched.
if [ -d "$MNT/valve" ]; then
	# Pre-v1.2.0 image: it still carries a valve payload, so install it as before.
	ditto "$MNT/valve/cl_dlls" "$DEST/valve/cl_dlls"
	ditto "$MNT/valve/dlls"    "$DEST/valve/dlls"
	[ -f "$MNT/valve/userconfig.cfg" ] && cp -p "$MNT/valve/userconfig.cfg" "$DEST/valve/userconfig.cfg" || true
else
	REMOVED=0
	for f in valve/cl_dlls/client_ppc.dylib valve/cl_dlls/client_amd64.dylib \
	         valve/dlls/hl_ppc.dylib valve/dlls/hl_amd64.dylib \
	         valve/userconfig.cfg valve/last-run.log; do
		if [ -f "$DEST/$f" ]; then rm -f "$DEST/$f"; REMOVED=$(( REMOVED + 1 )); fi
	done
	# Mod banners/blurbs the old installer staged; all 25 now ship inside the app.
	if [ -d "$DEST/valve/gfx/shell/mods" ]; then
		rm -rf "$DEST/valve/gfx/shell/mods"
		REMOVED=$(( REMOVED + 1 ))
	fi
	# Only prune directories we may have created, and only while empty.
	rmdir "$DEST/valve/gfx/shell" "$DEST/valve/gfx" "$DEST/valve/cl_dlls" "$DEST/valve/dlls" 2>/dev/null || true
	echo "valve/: removed $REMOVED leftover item(s) from previous releases; retail data untouched"
fi

# Report engine build spill sitting loose beside the bundle, and do NOT delete it.
#
# Everything named here has lived inside Half-Life.app/Contents/MacOS since v1.2.0.
# A loose copy at the root of the game folder is left over from a raw build staged
# there, and it is not inert: the engine loads the renderer and the menu with
# directpath=true, which falls through FS_FindFile's fs_ext_path branch to
# fs_rootdir/<name>, and fs_rootdir is XASH3D_BASEDIR, this very folder. The stale
# copy wins over the one in the bundle, with nothing in the log to say so.
#
# We name it and stop. This folder is the player's: the retail valve/, every mod
# they installed, saves. A blanket sweep here is how installed mods got destroyed
# once already, and no amount of pattern-matching makes it safe to run unattended.
SPILL=""
for f in xash3d xash3d.bin libxash.dylib libmenu.dylib libref_gl.dylib \
         libref_soft.dylib filesystem_stdio.dylib libSDL2-2.0.0.dylib; do
	[ -e "$DEST/$f" ] && SPILL="$SPILL $f"
done
if [ -n "$SPILL" ]; then
	echo "WARNING: engine files are loose in $DEST and SHADOW the ones inside the app:"
	for f in $SPILL; do echo "    $f"; done
	echo "  These are build spill, not part of any release. Move them out by hand, e.g."
	echo "    mkdir -p ~/old-build-spill && (cd '$DEST' && mv$SPILL ~/old-build-spill/)"
	echo "  Nothing has been deleted. Your valve/ and mods are untouched."
fi

# Make the Finder notice a changed icon.
#
# Replacing a bundle in place is not enough: the Finder caches an app's icon
# against the bundle, and on Tiger/Leopard it will happily keep drawing the OLD
# one indefinitely. Bumping the bundle's and the Info.plist's modification time
# invalidates that, which is the least invasive nudge available - it does not
# touch the user's other windows or restart anything.
for app in "$DEST/Half-Life.app" "$DEST/Half-Life Mods.app" "$DEST/Half-Life System Report.app"; do
	[ -d "$app" ] || continue
	touch "$app/Contents/Info.plist" "$app/Contents" "$app" 2>/dev/null || true
done
# The touch above is not always enough. On Panther it kept drawing the GENERIC
# application icon for the System Report app after v1.4.3 changed which .icns
# file that bundle carries: the icon file and CFBundleIconFile were both correct
# on disk, and Finder still ignored them. Re-registering the bundle with
# LaunchServices is what actually clears it. The tool has lived at this path
# since 10.3, and this is best-effort: if it is missing or fails, the touch above
# still stands and a wrong icon is not worth failing a deploy over.
LSREG=/System/Library/Frameworks/ApplicationServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREG" ]; then
	for app in "$DEST/Half-Life.app" "$DEST/Half-Life Mods.app" "$DEST/Half-Life System Report.app"; do
		[ -d "$app" ] || continue
		"$LSREG" -f "$app" >/dev/null 2>&1 || true
	done
	echo "re-registered the three bundles with LaunchServices (icon cache)"
fi
# ...and drop the per-folder .DS_Store, which is where the stale icon position
# and cached badge actually live for this directory.
rm -f "$DEST/.DS_Store" 2>/dev/null || true

# detach - retry until the slow-disk flush completes; only then rmdir the now-
# empty mountpoint.
# Every detach here is best-effort and must not abort the script under `set -e`:
# by this point the install has already succeeded, and a stubborn image is worth a
# warning, not a failed deploy.
for k in 1 2 3 4 5; do
	if [ -n "$DEV" ] && hdiutil detach "$DEV" >/dev/null 2>&1; then break; fi
	if hdiutil detach "$MNT" >/dev/null 2>&1; then break; fi
	sleep 2
done
if [ -n "$DEV" ]; then hdiutil detach -force "$DEV" >/dev/null 2>&1 || true; fi
hdiutil detach -force "$MNT" >/dev/null 2>&1 || true
rmdir "$MNT" 2>/dev/null || true
if mount | grep -q " $MNT " 2>/dev/null; then
	echo "WARNING: $MNT is still mounted - eject it by hand"
fi

echo "installed into $DEST:"
ls -1 "$DEST" | sed 's/^/    /'
echo "app binary archs:"
file "$DEST/Half-Life.app/Contents/MacOS/xash3d.bin" 2>/dev/null | sed 's/.*: /    /' || true
if [ -d "$DEST/Half-Life Mods.app" ]; then
	echo "mod installer: $(ls "$DEST/Half-Life Mods.app/Contents/Resources/mods" 2>/dev/null | wc -l | tr -d ' ') mod builds bundled"
fi
if [ -f "$DEST/valve/pak0.pak" ]; then echo "retail valve/ game data present (pak0.pak) - ready to launch."
else echo "NOTE: no valve/pak0.pak yet - add your retail Half-Life data to $DEST/valve before launching."; fi
REMOTE_EOF

echo "[deploy-dmg $HOST] done - installed from $DMG_BASE"
