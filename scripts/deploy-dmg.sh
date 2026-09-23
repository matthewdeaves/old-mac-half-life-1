#!/usr/bin/env bash
# Install the release DMG onto a target Mac the way an end user would: copy the
# .dmg into this port's own staging directory, mount it, copy its contents into
# the game folder, unmount. This is deliberately the DMG path (not a direct
# rsync) so the test loop exercises the exact artifact and install steps a
# human performs - that is where a corrupt-image bug would hide (a direct
# deploy can be clean while the DMG is not). The staging directory is
# ~/oldmac/halflife, never the Desktop or another home-root path: that scratch
# belongs to this port, not the player's install. issue #35.
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
DEST_DIR="${DEST_DIR:-/Applications/Half-Life}"

# `workstation` is this arm64 dev box itself (scripts/pick-bench-host.sh's
# LOCAL_ALIASES: "ONE HOST NEEDS NO SSH AT ALL"). Every step below that would
# otherwise ssh/scp to $HOST runs directly on this machine instead.
case "$HOST" in
	workstation) LOCAL=1 ;;
	*)           LOCAL=0 ;;
esac

# Keep transfer failures attributable without xtrace, which would spill every
# command argument and environment setting into a fleet log.  The deployer used
# to print its copy banner before several SSH steps, so a later silent exit was
# too easily attributed to scp.
stage() {
	label="$1"; shift
	if "$@"; then
		return 0
	else
		rc=$?
		echo "[deploy-dmg $HOST] FATAL: $label failed (exit $rc)" >&2
		return "$rc"
	fi
}

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

# PRESTAGE=1: mount the image HERE and rsync its contents over, instead of
# shipping the .dmg and mounting it on the target. For a machine whose DiskImages
# stack cannot attach anything at all - quad-tiger fails every attach with
# DI_kextDriveActivate error 0xE00002C9 on a freshly booted box, with an image
# that mounts fine everywhere else (old-mac-build-host#41). Everything after the
# mount is the same code, so this is a different way to reach the install, not a
# second install path to keep in sync.
#
# Meaningless on the local workstation target: there is no second machine to
# rsync the mount to, and this box's hdiutil is not the thing PRESTAGE exists
# to route around.
if [ "$LOCAL" = 1 ] && [ "${PRESTAGE:-0}" = 1 ]; then
	echo "[deploy-dmg $HOST] FATAL: PRESTAGE is meaningless for the local workstation target" >&2
	exit 1
fi
if [ "${PRESTAGE:-0}" = 1 ]; then
	echo "[deploy-dmg $HOST] PRESTAGE: mounting the image locally and rsyncing its contents"
	LMNT="$(mktemp -d -t hl-prestage)"
	hdiutil detach "$LMNT" >/dev/null 2>&1 || true
	hdiutil attach -nobrowse -readonly -mountpoint "$LMNT" "$DMG" >/dev/null
	trap 'hdiutil detach "$LMNT" >/dev/null 2>&1 || hdiutil detach -force "$LMNT" >/dev/null 2>&1 || true; rmdir "$LMNT" 2>/dev/null || true' EXIT
	[ -d "$LMNT/Half-Life.app" ] || { echo "[deploy-dmg $HOST] FATAL: local mount has no Half-Life.app" >&2; exit 1; }
	ssh "$HOST" 'rm -rf "$HOME/oldmac/halflife/hlinstall-mnt" && mkdir -p "$HOME/oldmac/halflife/hlinstall-mnt"'
	# -E preserves the resource forks the icons live in, the way ditto does.
	#
	# The excludes are HFS volume housekeeping, not payload, and .Trashes is not
	# readable even by the user who mounted the image: without excluding it rsync
	# fails the whole transfer with "opendir .Trashes: Permission denied" and
	# exit 23, having skipped the deletion pass. None of these are part of the
	# release and none are copied by the hdiutil path either, which only ever
	# ditto's the three .app bundles by name.
	rsync -aE --delete \
		--exclude '.Trashes' --exclude '.fseventsd' --exclude '.Spotlight-V100' \
		--exclude '.DS_Store' --exclude '.TemporaryItems' --exclude '.VolumeIcon.icns' \
		"$LMNT"/ "$HOST:oldmac/halflife/hlinstall-mnt/"
	echo "[deploy-dmg $HOST] contents staged at ~/oldmac/halflife/hlinstall-mnt"
elif [ "$LOCAL" = 1 ]; then

# Same staging path and same by-name DMG cleanup as the remote leg, just with
# a plain cp instead of scp+ssh - there is no second machine to reach.
echo "[deploy-dmg $HOST] copy $DMG_BASE to ~/oldmac/halflife/deploy-stage/ (local)"
mkdir -p "$HOME/oldmac/halflife/deploy-stage"
OLD=$(ls -1 "$HOME"/oldmac/halflife/deploy-stage/Half-Life-OldMac-*.dmg 2>/dev/null || true)
if [ -n "$OLD" ]; then
	echo "[deploy-dmg $HOST] removing old release DMG(s):"; echo "$OLD" | sed 's/^/    /'
	rm -f "$HOME"/oldmac/halflife/deploy-stage/Half-Life-OldMac-*.dmg
fi

stage "copy candidate DMG" cp "$DMG" "$HOME/oldmac/halflife/deploy-stage/$DMG_BASE"

# Verify the copy landed intact - defence in depth on top of make-dmg.sh's
# end-to-end content check, matching the remote leg's md5 compare.
LCL_MD5=$(md5 -q "$DMG" 2>/dev/null || md5sum "$DMG" 2>/dev/null | awk '{print $1}')
DST_MD5=$(md5 -q "$HOME/oldmac/halflife/deploy-stage/$DMG_BASE" 2>/dev/null || md5sum "$HOME/oldmac/halflife/deploy-stage/$DMG_BASE" 2>/dev/null | awk '{print $1}')
[ "$LCL_MD5" = "$DST_MD5" ] || { echo "[deploy-dmg $HOST] FATAL: local copy corrupted the DMG ($LCL_MD5 != $DST_MD5)" >&2; exit 1; }
echo "[deploy-dmg $HOST] staged DMG verified intact ($DST_MD5)"

else

# Transfer staging lives under ~/oldmac/halflife, not ~/Desktop or the home
# root: it is scratch this port owns for the length of one deploy, not part of
# the player's installed game. issue #35.
echo "[deploy-dmg $HOST] copy $DMG_BASE to ~/oldmac/halflife/deploy-stage/"
stage "create staging directory" ssh "$HOST" 'mkdir -p ~/oldmac/halflife/deploy-stage'

# Remove any previously-shipped release DMGs first (scoped to our own release
# artifacts; the user's files are never touched) so stale versions don't pile up
# and a leftover same-name image can't be silently reused after a failed scp.
if OLD=$(ssh "$HOST" 'ls -1 ~/oldmac/halflife/deploy-stage/Half-Life-OldMac-*.dmg 2>/dev/null || true'); then :; else
	rc=$?
	echo "[deploy-dmg $HOST] FATAL: list prior release DMGs failed (exit $rc)" >&2
	exit "$rc"
fi
if [ -n "$OLD" ]; then
	echo "[deploy-dmg $HOST] removing old release DMG(s):"; echo "$OLD" | sed 's/^/    /'
	stage "remove prior release DMGs" ssh "$HOST" 'rm -f ~/oldmac/halflife/deploy-stage/Half-Life-OldMac-*.dmg'
fi

stage "copy candidate DMG" scp -q "$DMG" "$HOST:oldmac/halflife/deploy-stage/$DMG_BASE"

# Verify the .dmg arrived intact (md5 local vs remote) - defence in depth on top
# of make-dmg.sh's end-to-end content check.
LCL_MD5=$(md5 -q "$DMG" 2>/dev/null || md5sum "$DMG" 2>/dev/null | awk '{print $1}')
if RMT_MD5=$(ssh "$HOST" "md5 'oldmac/halflife/deploy-stage/$DMG_BASE' | awk '{print \$NF}'"); then :; else
	rc=$?
	echo "[deploy-dmg $HOST] FATAL: read target DMG checksum failed (exit $rc)" >&2
	exit "$rc"
fi
[ "$LCL_MD5" = "$RMT_MD5" ] || { echo "[deploy-dmg $HOST] FATAL: scp corrupted the DMG ($LCL_MD5 != $RMT_MD5)" >&2; exit 1; }
echo "[deploy-dmg $HOST] staged DMG verified intact ($RMT_MD5)"

fi   # end of the non-PRESTAGE image transfer

case "$DEST_DIR" in
  /*) DEST_LABEL="$DEST_DIR" ;;
  *)  # shellcheck disable=SC2088 # a label for the log line only; the path is relative to the TARGET's home, not this one
      DEST_LABEL="~/$DEST_DIR" ;;
esac
echo "[deploy-dmg $HOST] mount + install into $DEST_LABEL/ (preserving retail valve/ data)"
# Captured into a variable, not piped straight into ssh/bash as a literal
# heredoc, so the exact same install logic runs either over ssh or directly on
# this box - one script body, not two copies to keep in sync.
INSTALL_SCRIPT=$(cat <<'REMOTE_EOF'
set -e
DMG_BASE="$1"; DEST_DIR="$2"
MNT="$HOME/oldmac/halflife/hlinstall-mnt"
case "$DEST_DIR" in
	/*) FINAL_DEST="$DEST_DIR" ;;
	*)  FINAL_DEST="$HOME/$DEST_DIR" ;;
esac
DEST="$FINAL_DEST"
HELPER="${HELPER:?missing rollback helper}"
[ -x "$HELPER" ] || { echo "missing executable rollback helper: $HELPER" >&2; exit 1; }
ROLLBACK=""
STAGE=""
finish() {
	rc=$?
	if [ "$rc" -ne 0 ] && [ -n "$ROLLBACK" ]; then
		echo "DEPLOY FAILED: original owned paths remain at $ROLLBACK" >&2
		echo "Restore with: $ROLLBACK/RESTORE.sh '$FINAL_DEST'" >&2
	fi
	if [ "$rc" -ne 0 ] && [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
		rm -rf "$STAGE"
		echo "discarded incomplete owned staging tree: $STAGE" >&2
	fi
	rm -f "$HELPER"
	exit "$rc"
}
trap finish EXIT

# PRESTAGED=1 means the caller could not mount the image on this machine and has
# already put the image's CONTENTS at $MNT by other means. Skip the attach and
# use what is there; everything after this point is identical, which is the whole
# point of doing it this way rather than hand-rolling a second install path.
#
# quad-tiger needs this: its DiskImages kext fails every attach with
# DI_kextDriveActivate error 0xE00002C9 / "timed out waiting for IOService to
# become quiescent", on a freshly booted machine, with an image that mounts fine
# on every other host in the fleet. That is a kernel-level fault on that box, not
# a bad image. old-mac-build-host#41.
if [ "${PRESTAGED:-0}" = 1 ]; then
	[ -d "$MNT/Half-Life.app" ] || { echo "PRESTAGED=1 but $MNT holds no Half-Life.app" >&2; exit 1; }
	echo "prestaged: using image contents already at $MNT (no hdiutil on this host)"
	DEV=""
else

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
ATTACH_OUT=$(hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$HOME/oldmac/halflife/deploy-stage/$DMG_BASE")
DEV=$(echo "$ATTACH_OUT" | awk '/^\/dev\/disk/ { print $1; exit }')

fi   # end of the non-PRESTAGED attach

# Do not even inventory the old install until the mounted candidate has the
# executable shape we are about to promote.  This catches a bad/mixed staging
# directory before a single installed file is replaced.
[ -x "$MNT/Half-Life.app/Contents/MacOS/xash3d" ] || { echo "FATAL: candidate has no executable launcher" >&2; exit 1; }
[ -x "$MNT/Half-Life.app/Contents/MacOS/xash3d.bin" ] || { echo "FATAL: candidate has no engine binary" >&2; exit 1; }
[ -d "$MNT/Half-Life.app/Contents/Resources/Half-Life/valve" ] || { echo "FATAL: candidate has no bundled game root" >&2; exit 1; }

# A first move onto /Applications is promoted from a sibling staging tree built
# from the Desktop game, so the player's retail data, saves and mods are copied
# in rather than lost - the Desktop source is copied, never renamed or
# modified. An /Applications install that already exists is a later upgrade of
# an already-migrated host, not a second migration: it goes through the same
# backup-then-replace path as any other destination, below. issue #35.
case "$DEST_DIR" in
	/Applications/*)
		[ -w "$(dirname "$FINAL_DEST")" ] || { echo "FATAL: destination parent is not writable: $(dirname "$FINAL_DEST")" >&2; exit 1; }
		if [ ! -e "$FINAL_DEST" ]; then
			SOURCE="${DATA_SOURCE:-$HOME/Desktop/Half-Life}"
			[ -f "$SOURCE/valve/pak0.pak" ] || { echo "FATAL: source retail data missing: $SOURCE/valve/pak0.pak" >&2; exit 1; }
			STAGE="${FINAL_DEST}.hl-stage-$$"
			[ ! -e "$STAGE" ] || { echo "FATAL: staging path exists: $STAGE" >&2; exit 1; }
			echo "staging preserved Desktop tree $SOURCE -> $STAGE"
			ditto "$SOURCE" "$STAGE"
			DEST="$STAGE"
		fi
		;;
esac

# Keep the original app bundles, old port-owned valve runtime files and Finder
# state outside the game root.  The helper's fixed inventory deliberately never
# includes retail data, saves or mod directories.  The backup is retained after
# success so a user can restore before a manual test if the candidate is wrong.
ROLLBACK_ROOT="${ROLLBACK_ROOT:-$($HELPER root)}"
ROLLBACK="$ROLLBACK_ROOT/$(date +%Y%m%d-%H%M%S)-$DMG_BASE"
"$HELPER" backup "$FINAL_DEST" "$ROLLBACK" "$DMG_BASE"

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

# The loose files beside the apps on the image. Without this an upgrade kept
# whatever copies the first install brought: measured 2026-09-23 on the
# workstation, a v1.9.19 deploy left BUILD-INFO.txt reading 1.9.16-rc1. Named
# one by one, never a sweep of the image root, for the same reason the apps are.
for loose in "BUILD-INFO.txt" "README.txt" "Fix Launch Problems.command"; do
	[ -f "$MNT/$loose" ] || continue
	rm -f "$DEST/$loose"
	ditto "$MNT/$loose" "$DEST/$loose"
	echo "installed: $loose"
done

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
# ANYTHING.
#
# The ad-hoc signature is written by THIS dev box's current codesign, and an
# old enough codesign cannot parse a format that far ahead of it: measured
# FATAL false positives on g5-desktop (10.5.8, PowerPC, Darwin 9 - codesign
# itself debuted in Leopard) and mini-sl (10.6.8, Intel, Darwin 10) - both
# report "code or signature modified" on a bundle `ditto` had just produced
# seconds earlier. Not CPU-specific: mini-sl is Intel. Gated on Darwin major
# instead: >= 15 (El Capitan, when SIP and the modern codesign format had
# landed) is the only class of machine this check can trust either way, and
# the only one where Gatekeeper enforcement is real enough to reject a bad
# signature on a double-click. Below that, a warning, never a failed deploy.
DARWIN_MAJOR=$(uname -r | cut -d. -f1)
if command -v codesign >/dev/null 2>&1 && [ "${DARWIN_MAJOR:-0}" -ge 15 ] 2>/dev/null; then
	for app in "$DEST/Half-Life.app" "$DEST/Half-Life Mods.app" "$DEST/Half-Life System Report.app"; do
		[ -d "$app" ] || continue
		codesign -v "$app" 2>&1 || { echo "FATAL: $(basename "$app") signature is invalid after install" >&2; exit 1; }
	done
	echo "signatures verified on the installed bundles"
elif command -v codesign >/dev/null 2>&1; then
	for app in "$DEST/Half-Life.app" "$DEST/Half-Life Mods.app" "$DEST/Half-Life System Report.app"; do
		[ -d "$app" ] || continue
		codesign -v "$app" >/dev/null 2>&1 || echo "note: codesign -v disagrees on $(basename "$app") - not trusted below Darwin 15, continuing"
	done
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
	echo "    mkdir -p ~/oldmac/halflife/build-spill && (cd '$DEST' && mv$SPILL ~/oldmac/halflife/build-spill/)"
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
if [ "${PRESTAGED:-0}" = 1 ]; then
	# Nothing was ever mounted, so there is nothing to detach. $MNT is an
	# ordinary directory the caller rsynced; remove it rather than leaving a
	# second full copy of the payload on the machine's disk.
	rm -rf "$MNT"
else
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
fi

if [ -n "$STAGE" ]; then
	mv "$STAGE" "$FINAL_DEST"
	DEST="$FINAL_DEST"
	STAGE=""
	echo "promoted staged candidate into $DEST"
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

# Keep ONE rollback: the one this deploy just wrote, so the previous build can
# still be restored before a manual test. Every older one is a superseded
# build and goes, or they pile up forever (old-mac-build-host's tidy removed 11
# from one host). Matched by the name backup() gives them, so nothing else
# under the rollback root is ever touched.
for old in "$ROLLBACK_ROOT"/*-Half-Life-OldMac-*.dmg; do
	[ -d "$old" ] || continue
	[ "$old" = "$ROLLBACK" ] && continue
	rm -rf "$old" && echo "pruned superseded rollback $(basename "$old")"
done
REMOTE_EOF
)

if [ "$LOCAL" = 1 ]; then
	# Still a throwaway copy, not the checkout's real deploy-rollback.sh: the
	# install script's own EXIT trap does `rm -f "$HELPER"` once it is done,
	# and that must never delete the copy this repo actually uses.
	ROLLBACK_HELPER="$(mktemp -t hl-deploy-rollback)"
	cp "$REPO_ROOT/scripts/deploy-rollback.sh" "$ROLLBACK_HELPER"
	chmod +x "$ROLLBACK_HELPER"
	env PRESTAGED="${PRESTAGE:-0}" HELPER="$ROLLBACK_HELPER" bash -s "$DMG_BASE" "$DEST_DIR" <<<"$INSTALL_SCRIPT"
else
	# The helper carries the narrow, inventory-backed rollback transaction.  It
	# is copied from this checkout for this one deploy, so old fleet trees do
	# not need a prior sync just to make a candidate installation reversible.
	ROLLBACK_HELPER="/tmp/hl-deploy-rollback-$$.sh"
	scp -q "$REPO_ROOT/scripts/deploy-rollback.sh" "$HOST:$ROLLBACK_HELPER"
	ssh "$HOST" "PRESTAGED=${PRESTAGE:-0} HELPER='$ROLLBACK_HELPER' bash -s '$DMG_BASE' '$DEST_DIR'" <<<"$INSTALL_SCRIPT"
fi

# The staged DMG has now been fully extracted into $DEST_DIR - remove it, so a
# manual test/deploy round doesn't leave its own source image behind forever.
# Scoped to our own named release artifact, same as the pre-copy cleanup above;
# never touches anything of the player's. old-mac-build-host's own fleet sweep
# (issue #26) found this leftover on 8 of 9 reachable hosts, back when the
# staging path was ~/Desktop: every deploy up to that fix installed cleanly and
# then left the .dmg it was installed from sitting there, since nothing ever
# removed it after use. Moved under ~/oldmac/halflife (issue #35); the failure
# mode and the fix are the same either way. PRESTAGE mode never copies a .dmg to
# the target at all, so there is nothing to remove there.
if [ "${PRESTAGE:-0}" != 1 ]; then
	if [ "$LOCAL" = 1 ]; then
		rm -f "$HOME/oldmac/halflife/deploy-stage/$DMG_BASE"
	else
		ssh "$HOST" "rm -f ~/oldmac/halflife/deploy-stage/$DMG_BASE"
	fi
	echo "[deploy-dmg $HOST] removed staged $DMG_BASE (installed copy is at $DEST_LABEL)"
fi

echo "[deploy-dmg $HOST] done - installed from $DMG_BASE"
