#!/usr/bin/env bash
# Build the distributable Half-Life.app disk image - one .dmg that mounts and
# installs on every supported Mac, from a G3 on 10.3.9 Panther through modern
# Intel macOS.
#
# usage: scripts/make-dmg.sh [version-label]
#   version-label: e.g. v0.21 (default: the app's CFBundleShortVersionString,
#                  falling back to this repo's short HEAD hash)
#
# WHERE IT RUNS: this dev/orchestration box. It pulls the built universal app +
# game-code payload from the build host, stages the image contents locally, and
# ships them to a Tiger box that runs the actual hdiutil packaging.
#
#   SRC_HOST   build host holding the assembled universal bundle. Default: the
#              first of $BUILD_HOSTS (mini-intel mini-intel2) that actually has
#              SRC_APP on it - either Intel mini may have produced the build.
#   SRC_APP    path on SRC_HOST to the built Half-Life.app
#              (default: ~/oldmac/dist/universal-app/Half-Life.app)
#   (No SRC_VALVE any more: our recompiled game code now lives INSIDE
#   Half-Life.app, at Contents/Resources/Half-Life. See "WHAT SHIPS" below.)
#   DMG_HOST   Mac that runs hdiutil. DEFAULT: first REACHABLE Tiger box
#              (mini-g4, then quicksilver).
#
# WHY A TIGER HOST, NOT THE G3 AND NOT LION (empirically settled on this fleet):
#   * Lion's hdiutil writes a UDIF container that Panther's 2003-vintage
#     DiskImageMounter cannot parse - "no mountable file systems" on 10.3.9. No
#     hdiutil flag fixes it. So Lion is out for any image that must reach a G3.
#   * A TIGER-built UDZO image mounts on Panther AND everything newer (old->new
#     compatibility holds; new->old does not). 10.4 is the oldest OS we need for
#     the packaging step.
#   * We deliberately do NOT package on the 1999 G3: it is the flakiest hardware
#     in the fleet. On an earlier old-Mac release a single byte flipped during
#     that G3's hdiutil read->zlib->write and shipped a corrupt PowerPC slice
#     (a register-save opcode mutated into an illegal instruction -> instant
#     crash on the target), and it passed `hdiutil verify` silently. The
#     end-to-end content check below now catches such a flip on ANY host, but
#     there is no reason to package on the worst hardware.
#
# WHAT SHIPS (and what does not): the image carries Half-Life.app (and the mod
# installer) and NOTHING ELSE. There is no valve folder on the image at all. Our
# recompiled game code and default config live inside the app, under
# Contents/Resources/Half-Life, which the engine mounts as its read-only root. The
# player drops their OWN untouched retail valve folder next to the app; there is
# nothing to merge and no way for them to delete our game code by replacing that
# folder. Half-Life's game data (maps/models/sounds/paks) is Valve's and is not
# included. See the in-image README.txt.
#
# post: dist/Half-Life-OldMac-<version>.dmg
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Under dist/ like every other piece of build output. Before v1.4.4 this was
# ~/oldmac/dist-universal-app, and make-universal.sh told you to wrap the app onto
# the Desktop instead, so the two halves of the release never agreed on one path.
SRC_APP="${SRC_APP:-~/oldmac/dist/universal-app/Half-Life.app}"

# There are two interchangeable Intel build minis, so the universal bundle may
# have been assembled on EITHER. Pick the one that actually HOLDS the artifact -
# not merely the first one that is free, which is what pick-build-host.sh answers
# (that question is "where can I build?", this one is "where did the build land?").
# First reachable host carrying SRC_APP wins; explicit SRC_HOST always overrides.
if [ -z "${SRC_HOST:-}" ]; then
  for cand in ${BUILD_HOSTS:-mini-intel mini-intel2}; do
    if ssh -o ConnectTimeout=6 -o BatchMode=yes "$cand" "test -e $SRC_APP" 2>/dev/null; then
      SRC_HOST="$cand"; break
    fi
  done
  if [ -z "${SRC_HOST:-}" ]; then
    echo "make-dmg: no Intel build host holds $SRC_APP" >&2
    echo "  checked: ${BUILD_HOSTS:-mini-intel mini-intel2}" >&2
    echo "  build it first, or set SRC_HOST=<alias> / SRC_APP=<path> explicitly." >&2
    echo "  (a host synced before v1.4.4 may still hold it at ~/oldmac/dist-universal-app)" >&2
    exit 1
  fi
  echo "[make-dmg] source host with built bundle: $SRC_HOST"
fi

# Auto-pick the first reachable Tiger host unless DMG_HOST is set explicitly.
if [ -z "${DMG_HOST:-}" ]; then
  for cand in mini-g4 quicksilver; do
    if ssh -o ConnectTimeout=6 -o BatchMode=yes "$cand" true 2>/dev/null; then DMG_HOST="$cand"; break; fi
  done
  DMG_HOST="${DMG_HOST:-mini-g4}"
  echo "[make-dmg] DMG_HOST not set - using reachable Tiger host: $DMG_HOST"
fi

# ---- stage the image contents locally (app + valve payload + README) --------
STAGE="$(mktemp -d -t hl-dmg)"
trap 'rm -rf "$STAGE"' EXIT
IMG="$STAGE/img"
mkdir -p "$IMG"

echo "[make-dmg] fetch built app from $SRC_HOST"
# The app is self-contained now - our game code rides inside it under
# Contents/Resources/Half-Life, so there is no second payload to fetch and no
# symlink to preserve.
rsync -a -e ssh "$SRC_HOST:$SRC_APP/" "$IMG/Half-Life.app/"

# The mod installer ("Half-Life Mods.app", fat ppc+x86_64, ~130 MB because it
# carries our prebuilt game dylibs for all 25 mods). OPTIONAL: an engine-only
# release is still a valid thing to cut, so a missing installer is a loud note
# rather than an error. Present => it is verified byte-for-byte like everything
# else shipped.
# Default is relative to the remote home (ssh lands in $HOME), NOT "~/..." - a
# tilde inside the quotes this path needs would be passed through literally.
# Absolute overrides work too.
#
# The name contains a space, and it is passed RAW: rsync 3.2.4+ (this dev box)
# quotes remote args itself by default, so neither backslash-escaping nor
# --protect-args is wanted. Both were tried and both fail - escaping arrives as a
# literal backslash, and --protect-args is a negotiated option that Lion's rsync
# 2.6.9 rejects outright ("unknown option"). This script is dev-box-only (see the
# header), so the modern-rsync behaviour is the one that matters.
SRC_MODS_APP="${SRC_MODS_APP:-oldmac/dist/Half-Life Mods.app}"
SHIP_MODS_APP=no
if ssh -o ConnectTimeout=6 -o BatchMode=yes "$SRC_HOST" "test -e \"$SRC_MODS_APP\"" 2>/dev/null; then
  echo "[make-dmg] including the mod installer from $SRC_HOST"
  rsync -a -e ssh "$SRC_HOST:$SRC_MODS_APP/" "$IMG/Half-Life Mods.app/"
  SHIP_MODS_APP=yes
else
  echo "[make-dmg] NOTE: no mod installer at $SRC_HOST:$SRC_MODS_APP - shipping engine only"
fi

# The system-report app. Tiny, and it is the one thing on the image that has to
# run on machines where the GAME does not: it exists so someone whose CPU/OS
# combination we never tested can tell us what they have (GitHub issues #14, #15).
# Optional in the same way the installer is, so a missing build is a note rather
# than a failed release.
SRC_SR_APP="${SRC_SR_APP:-oldmac/dist/Half-Life System Report.app}"
SHIP_SR_APP=no
if ssh -o ConnectTimeout=6 -o BatchMode=yes "$SRC_HOST" "test -e \"$SRC_SR_APP\"" 2>/dev/null; then
  echo "[make-dmg] including the system report app from $SRC_HOST"
  rsync -a -e ssh "$SRC_HOST:$SRC_SR_APP/" "$IMG/Half-Life System Report.app/"
  SHIP_SR_APP=yes
else
  echo "[make-dmg] NOTE: no system report app at $SRC_HOST:$SRC_SR_APP"
fi

BIN="$IMG/Half-Life.app/Contents/MacOS/xash3d.bin"
[ -f "$BIN" ] || { echo "[make-dmg] no xash3d.bin in fetched app - check SRC_APP" >&2; exit 1; }

# Sanity: must be the 3-slice fat, not a stray single-arch binary. lipo -archs
# reads the Mach header directly; tolerate ppc subtype naming (ppc / ppc750).
# ppc970 is deliberately absent since v1.4.0: the G5 takes ppc7400. See
# docs/adr/0001-slices-are-chosen-by-cpu-capability.md.
ARCHS=$(lipo -archs "$BIN" 2>/dev/null || echo)
echo "[make-dmg] fat slices: ${ARCHS:-<none>}"
for a in ppc7400 x86_64; do
  case " $ARCHS " in *" $a "*) ;; *) echo "[make-dmg] fat binary missing $a slice (got: ${ARCHS:-none})" >&2; exit 1;; esac
done
case " $ARCHS " in *" ppc "*|*" ppc750 "*) ;; *) echo "[make-dmg] fat binary missing the generic ppc (G3) slice" >&2; exit 1;; esac

# Confirm the game code for both endian families is present, INSIDE the bundle.
# GAMEDATA sits under the engine's read-only root, which FS_AppleBundledGameRoot
# finds by probing for a valve/ inside the bundle. If it is absent the engine has
# no rodir at all and aborts at startup with "missing game library".
GAMEDATA="Half-Life.app/Contents/Resources/Half-Life/valve"
for g in cl_dlls/client_ppc.dylib cl_dlls/client_amd64.dylib \
         dlls/hl_ppc.dylib dlls/hl_amd64.dylib; do
  [ -f "$IMG/$GAMEDATA/$g" ] || { echo "[make-dmg] missing shipped game code: $GAMEDATA/$g" >&2; exit 1; }
done
# Nothing but the two apps and the text files may ship. A stray valve folder here
# would put our dylibs back outside the bundle and reintroduce the merge step.
[ -e "$IMG/valve" ] && { echo "[make-dmg] a valve folder is staged - we ship none" >&2; exit 1; }
true

# Our PORT version - single source of truth is the repo VERSION file (arg overrides).
if [ -n "${1:-}" ]; then
  PORTVER="$1"
else
  PORTVER="$(tr -d ' \t\n' < "$REPO_ROOT/VERSION" 2>/dev/null || true)"
  [ -n "$PORTVER" ] || PORTVER="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
fi
VERSION="v$PORTVER"
VOLNAME="Half-Life OldMac $VERSION"
OUT="$REPO_ROOT/dist/Half-Life-OldMac-$VERSION.dmg"
echo "[make-dmg] version: $VERSION"

# --- stamp the port version + full provenance into the bundle -----------------
# The build string records WHAT we built from (upstream pins + base engine) and
# our build id (git short hash = the exact state of our patches + fat recipe), so
# a shipped .app is self-describing. Pins come from the canonical build-pins.sh.
. "$REPO_ROOT/scripts/build-pins.sh"
OURHASH="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git -C "$REPO_ROOT" diff --quiet 2>/dev/null || OURHASH="${OURHASH}+dirty"
BUILDDATE="$(date +%Y-%m-%d)"
BUILD_ONELINE="$(provenance_oneline "$OURHASH" "$BUILDDATE")"
GETINFO="Half-Life-OldMac $PORTVER ($BUILD_ONELINE)"

APPRES="$IMG/Half-Life.app/Contents/Resources"
provenance_table "$OURHASH" "$BUILDDATE" "$PORTVER" | tee "$IMG/BUILD-INFO.txt" > "$APPRES/BUILD-INFO.txt"

# Ship the repo's canonical icon (source of truth), regardless of what the build
# box baked into the app - so an icon fix reaches the DMG without a full rebuild.
if [ -f "$REPO_ROOT/MacOSX/Half-Life.icns" ]; then
  cp "$REPO_ROOT/MacOSX/Half-Life.icns" "$APPRES/Half-Life.icns"
  # Copying the file is NOT enough: without CFBundleIconFile the Finder ignores
  # it entirely and draws the blank generic app icon. make-app.sh only wrote that
  # key when it was handed an icon argument, so a bundle assembled without one
  # shipped iconless and looked like an icon-rendering bug rather than a missing
  # plist entry. Set it here too, so the release is right regardless of how the
  # bundle was assembled.
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile Half-Life.icns" "$IMG/Half-Life.app/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Half-Life.icns" "$IMG/Half-Life.app/Contents/Info.plist"
  echo "[make-dmg] icon: Half-Life.icns + CFBundleIconFile set"
fi

# Refuse to ship an app that will draw as a blank generic icon. Both halves have
# to be true - the .icns present in Resources AND named by CFBundleIconFile - and
# it is exactly the combination that failed silently before.
for pair in "Half-Life.app:Half-Life.icns" "Half-Life Mods.app:Half-Life-Mods.icns"; do
  appname="${pair%%:*}"; icnsname="${pair##*:}"
  [ -d "$IMG/$appname" ] || continue
  [ -f "$IMG/$appname/Contents/Resources/$icnsname" ] || {
    echo "[make-dmg] $appname is missing Resources/$icnsname" >&2; exit 1; }
  got=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$IMG/$appname/Contents/Info.plist" 2>/dev/null || true)
  [ "$got" = "$icnsname" ] || {
    echo "[make-dmg] $appname CFBundleIconFile is '${got:-<unset>}', expected '$icnsname'" >&2; exit 1; }
  echo "[make-dmg] icon OK: $appname -> $icnsname"
done

# Guarantee the developer console is reachable on EVERY machine: mainui is patched to show
# the on-screen "Console" menu button UNCONDITIONALLY, and the launcher passes `-console`
# (sets host.allow_console for the ~ overlay + the menu button; developer stays 0, so no
# on-screen notify spam and no verbose logging). Enforce it here (idempotent) rather than
# depend on how the app was assembled: migrate any stale `-dev 1` launcher to `-console`,
# or insert `-console` if neither flag is present.
LAUNCHER="$IMG/Half-Life.app/Contents/MacOS/xash3d"
if [ -f "$LAUNCHER" ]; then
  if grep -q -- "-dev 1" "$LAUNCHER"; then
    sed -i '' 's|xash3d.bin" -dev 1 |xash3d.bin" -console |' "$LAUNCHER"
    echo "[make-dmg] launcher: migrated -dev 1 -> -console"
  elif ! grep -q -- "-console" "$LAUNCHER"; then
    sed -i '' 's|xash3d.bin" |xash3d.bin" -console |' "$LAUNCHER"
    echo "[make-dmg] launcher: inserted -console"
  fi
fi

# Ship the repo's canonical userconfig.cfg (renderer-safe defaults + the con_notifytime 0
# override that hides the on-screen notify area - normal console messages notify regardless
# of developer mode), regardless of what the build box staged into valve/.
if [ -f "$REPO_ROOT/configs/userconfig.cfg" ]; then
  cp "$REPO_ROOT/configs/userconfig.cfg" "$IMG/$GAMEDATA/userconfig.cfg"
  echo "[make-dmg] $GAMEDATA/userconfig.cfg: shipped repo canonical"
fi

# Stamp ALL THREE bundles, not just the game. Get Info on the mod installer and
# the system report app used to show no version and no provenance at all, which
# is unhelpful precisely when someone is reporting a problem with one of them.
PB=/usr/libexec/PlistBuddy
COPYRIGHT="Half-Life is a trademark of Valve. No Valve game content is included. Unofficial fan project."
for b in "Half-Life.app" "Half-Life Mods.app" "Half-Life System Report.app"; do
  PLIST="$IMG/$b/Contents/Info.plist"
  [ -f "$PLIST" ] || continue
  $PB -c "Set :CFBundleShortVersionString $PORTVER" "$PLIST" 2>/dev/null || $PB -c "Add :CFBundleShortVersionString string $PORTVER" "$PLIST"
  $PB -c "Set :CFBundleVersion $PORTVER"            "$PLIST" 2>/dev/null || $PB -c "Add :CFBundleVersion string $PORTVER" "$PLIST"
  $PB -c "Set :CFBundleGetInfoString $GETINFO"      "$PLIST" 2>/dev/null || $PB -c "Add :CFBundleGetInfoString string $GETINFO" "$PLIST"
  $PB -c "Set :NSHumanReadableCopyright $COPYRIGHT" "$PLIST" 2>/dev/null || $PB -c "Add :NSHumanReadableCopyright string $COPYRIGHT" "$PLIST"
  # 10.3.9, not 10.3.0: every PowerPC slice is built against the 10.3.9 SDK, so a
  # 10.3.5 machine would otherwise launch and fail with no explanation. Set here
  # as well as in each build script, so it holds however the bundle was assembled.
  $PB -c "Set :LSMinimumSystemVersion 10.3.9" "$PLIST" 2>/dev/null || $PB -c "Add :LSMinimumSystemVersion string 10.3.9" "$PLIST"
  echo "[make-dmg] stamped $b: $PORTVER"
done
# Last chance to catch a stale build before a disk image exists. make-app.sh
# copied in the stamp make-universal.sh wrote after reading it back from all three
# slices, so if it disagrees with build-pins.sh here then the app being packaged
# was not built from the pinned source, whatever the mtimes say.
STAMP_FILE="$IMG/Half-Life.app/Contents/Resources/BUILD-STAMP"
if [ -f "$STAMP_FILE" ]; then
	APP_STAMP="$( tr -d " \t\n" < "$STAMP_FILE" )"
	if [ "$APP_STAMP" != "$PIN_ENGINE_COMMIT" ]; then
		echo "[make-dmg] FATAL: the app was built from $APP_STAMP" >&2
		echo "           build-pins.sh says            $PIN_ENGINE_COMMIT" >&2
		echo "           Re-run scripts/build-all.sh on the build host." >&2
		exit 1
	fi
	echo "[make-dmg] build stamp verified against the pin: $( short "$APP_STAMP" )"
else
	echo "[make-dmg] FATAL: the app carries no BUILD-STAMP." >&2
	echo "           Every app built by the current make-app.sh has one, so this bundle" >&2
	echo "           is stale. This is not hypothetical: SRC_HOST is chosen as the first" >&2
	echo "           build host that HAPPENS to hold an app, so a mini left holding an" >&2
	echo "           older dist/ gets picked over the one that just built. Re-run" >&2
	echo "           scripts/build-all.sh on the host you mean, or set SRC_HOST." >&2
	exit 1
fi

echo "[make-dmg] build id - $BUILD_ONELINE"

# ---- user-facing README inside the image ------------------------------------
cat > "$IMG/README.txt" <<EOF
Half-Life - Old-Mac universal build ($VERSION)
==============================================

Half-Life 1 on the open-source Xash3D FWGS engine, as ONE universal app for
PowerPC and Intel Macs. The right code slice (PowerPC G3, PowerPC G4/G5, or
Intel x86_64) and the right renderer + display mode are chosen automatically at
launch.

CHECK YOUR MAC IS COVERED
-------------------------
The app carries one code slice per CPU family, and macOS picks by CPU alone -
it ignores the OS version. So an unsupported combination does NOT fall back to
a slice that would have worked; it just fails to launch. Check this table:

    G3  (PowerPC 750)        10.3.9 Panther, 10.4 Tiger or 10.5 Leopard
    G4  (PowerPC 7400/7450)  10.3.9 Panther, 10.4 Tiger or 10.5 Leopard
    G5  (PowerPC 970)        10.3.9 Panther, 10.4 Tiger or 10.5 Leopard
    Intel, 64-bit            10.7 Lion or newer - not 10.6
    Apple Silicon            the Intel slice, under Rosetta 2

Every PowerPC slice is built for 10.3.9, so any PowerPC Mac from Panther up
should run this. Confirmed here on a G3 under 10.3.9 and 10.4, a G4 under 10.4,
a G5 under 10.5, an Intel mini under 10.7 and an M5 under macOS 26. The other
PowerPC combinations are untested only because there is no machine set up that
way, and a report either way is useful - see below.

Not covered: 32-bit-only Intel Macs (Core Solo / Core Duo), which would need an
i386 slice, and 64-bit Intel on 10.6, which has no libc++. There is no native
Apple Silicon slice; an Apple Silicon Mac runs the Intel one through Rosetta 2.

This is a Mac OS X / macOS build and is NOT for Mac OS 9 / Classic.

YOU NEED YOUR OWN COPY OF HALF-LIFE
-----------------------------------
This image ships the engine and the recompiled Mac game code, but NOT Half-Life's
game data (maps, models, sounds, textures) - that is Valve's. Supply it from your
own retail copy (Steam or disc); the folder tested against is the "valve" folder
from the Game of the Year edition, and a Steam install's works the same way.

There is deliberately NO "valve" folder on this image. Everything we built lives
inside Half-Life.app, so yours stays yours: drop it in untouched, with nothing to
merge and nothing of ours to overwrite by accident.

INSTALL
-------
1. Make a folder for the game, e.g.  ~/Desktop/Half-Life/  - it can be anywhere
   and named anything (Desktop, Applications, an external drive); the app only
   needs your "valve" folder sitting next to it.
2. Copy Half-Life.app from this disk image into that folder.
3. Copy your own "valve" folder in beside it, whole and unmodified. It should
   contain at least:
       valve/pak0.pak
       valve/liblist.gam
       valve/*.wad   (halflife.wad, decals.wad, liquids.wad, xeno.wad, ...)
       valve/maps/  valve/models/  valve/sound/  valve/sprites/  valve/gfx/
4. Double-click Half-Life.app.

Final layout:
   ~/Desktop/Half-Life/Half-Life.app         (ours: engine + Mac game code inside)
   ~/Desktop/Half-Life/valve/                (yours: retail game data, untouched)

Your saves and settings are written into your valve folder as you play. The app
itself is never written to, so you can replace it with a newer version at any
time without losing anything.

MODS (Blue Shift, Opposing Force, They Hunger, and 22 more)
-----------------------------------------------------------
If "Half-Life Mods.app" is on this disk image, copy it into the same folder as
Half-Life.app and run it. It installs any of 25 Half-Life mods so they appear in
the game's Custom Game menu, on PowerPC and Intel alike.

It ships the recompiled PowerPC + Intel game code for every mod. What it does
NOT ship is the mods themselves: it fetches each one from that mod's own public
release, checks it against a known checksum and unpacks it for you. Budget
roughly 6 GB of free space for a full install. It needs 256 MB of memory and
says so if the machine has less.

18 of the 25 download automatically. The other seven do not, and the app names
each one and says why:
  - Blue Shift, Opposing Force and Deathmatch Classic are Valve products you
    buy, not free mods, so nothing here will ever download them. If you own them
    and their folders are already beside Half-Life.app, the installer adds the
    Mac game code and they work like the rest.
  - Four more are published only as Windows installer programs that no Mac tool
    can open. Unpack those on a PC, put the folder beside Half-Life.app, and run
    the installer again.

Every mod belongs to the people who made it. This project supplies game code and
no content whatsoever.

IF IT DOES NOT LAUNCH, OR YOU HAVE AN UNTESTED MAC
--------------------------------------------------
Run "Half-Life System Report.app" from this disk image. It says what your Mac
is and which slice it would load, and copies that to the clipboard in one press
so you can paste it into a report at:
   https://github.com/matthewdeaves/old-mac-halflife/issues

It reads only and sends nothing anywhere. It runs on any PowerPC Mac from 10.3
and any 64-bit Intel Mac from 10.7, so it will start on machines where the game
does not. It cannot help on the two cases ruled out above, 32-bit-only Intel and
Intel on 10.6, because it has no slice those can load either.

The tested list above is the hardware available here, not the limit of what can
work. Reports are how that list gets widened, and a report that it simply worked
is as useful as one that it did not.

MODERN macOS (Gatekeeper)
-------------------------
The app is unsigned, so recent macOS will quarantine it. Right-click
Half-Life.app and choose Open the first time, or run:
   xattr -dr com.apple.quarantine ~/Desktop/Half-Life/Half-Life.app
(Not needed on Panther / Tiger / Leopard.)

NOTES
-----
* Hardware OpenGL on every machine, with an automatic software fallback.
* The developer console is available on all machines (open with the ~ key).
* LAN multiplayer works, including across PowerPC and Intel.
* Built with AI assistance (Claude Code), directed and hardware-tested by the author.

MORE OLD-MAC BUILDS
-------------------
If you like this, you may also like my old-Mac universal builds of Quake:
  Quake     (QuakeSpasm) : https://github.com/matthewdeaves/old-mac-quakespasm
  Quake II  (yquake2)    : https://github.com/matthewdeaves/old-mac-quake2
  Quake III (ioquake3)   : https://github.com/matthewdeaves/old-mac-quake3

Project: https://github.com/matthewdeaves/old-mac-halflife
EOF

# ---- the shippable, corruption-sensitive files, verified end-to-end ---------
# hdiutil verify only checks the container's INTERNAL checksum (that its blocks
# decompress to whatever was stored) - NOT that the stored bytes match our
# source. A single flipped byte anywhere in the stage->rsync->hdiutil chain
# passes hdiutil verify and ships a broken binary. So after packaging we mount
# the finished image and md5 every shipped binary inside it against the local
# source, retrying on mismatch and failing loud if it can't be made clean.
SHIP_LIST="$STAGE/ship-files.txt"
cat > "$SHIP_LIST" <<'LIST'
Half-Life.app/Contents/MacOS/xash3d
Half-Life.app/Contents/MacOS/xash3d.bin
Half-Life.app/Contents/MacOS/libxash.dylib
Half-Life.app/Contents/MacOS/libref_gl.dylib
Half-Life.app/Contents/MacOS/libref_soft.dylib
Half-Life.app/Contents/MacOS/libmenu.dylib
Half-Life.app/Contents/MacOS/filesystem_stdio.dylib
Half-Life.app/Contents/MacOS/libSDL2-2.0.0.dylib
Half-Life.app/Contents/Resources/Half-Life/valve/cl_dlls/client_ppc.dylib
Half-Life.app/Contents/Resources/Half-Life/valve/cl_dlls/client_amd64.dylib
Half-Life.app/Contents/Resources/Half-Life/valve/dlls/hl_ppc.dylib
Half-Life.app/Contents/Resources/Half-Life/valve/dlls/hl_amd64.dylib
Half-Life.app/Contents/Resources/Half-Life/valve/userconfig.cfg
LIST

# Every mod dylib we ship gets the same byte-for-byte treatment as the engine.
# That is ~130 MB across 48 files, and it is the point: the corruption this check
# exists to catch (a single flipped byte surviving hdiutil verify) is exactly as
# fatal in a mod's game code as in the engine's.
if [ "$SHIP_SR_APP" = yes ]; then
  SRBIN="$IMG/Half-Life System Report.app/Contents/MacOS/HalfLifeSystemReport"
  [ -f "$SRBIN" ] || { echo "[make-dmg] system report app has no executable" >&2; exit 1; }
  echo "[make-dmg] system report slices: $(lipo -archs "$SRBIN")"
fi

if [ "$SHIP_MODS_APP" = yes ]; then
  MODSBIN="$IMG/Half-Life Mods.app/Contents/MacOS/HalfLifeMods"
  [ -f "$MODSBIN" ] || { echo "[make-dmg] mod installer has no executable - check SRC_MODS_APP" >&2; exit 1; }
  MODARCHS=$(lipo -archs "$MODSBIN" 2>/dev/null || echo)
  case " $MODARCHS " in
    *" ppc "*) ;; *) echo "[make-dmg] mod installer missing its ppc slice (got: ${MODARCHS:-none})" >&2; exit 1;;
  esac
  case " $MODARCHS " in
    *" x86_64 "*) ;; *) echo "[make-dmg] mod installer missing its x86_64 slice (got: ${MODARCHS:-none})" >&2; exit 1;;
  esac
  echo "[make-dmg] mod installer slices: $MODARCHS"

  echo "Half-Life Mods.app/Contents/MacOS/HalfLifeMods" >> "$SHIP_LIST"
  nmods=0
  for d in "$IMG/Half-Life Mods.app/Contents/Resources/mods"/*/; do
    [ -d "$d" ] || continue
    b="$(basename "$d")"
    for role in server client; do
      f="$d$role.dylib"
      [ -f "$f" ] || { echo "[make-dmg] mod $b is missing $role.dylib" >&2; exit 1; }
      a=$(lipo -archs "$f" 2>/dev/null || echo)
      case " $a " in *" ppc "*) ;; *) echo "[make-dmg] mod $b $role.dylib is not fat ppc (got: ${a:-none})" >&2; exit 1;; esac
      case " $a " in *" x86_64 "*) ;; *) echo "[make-dmg] mod $b $role.dylib is not fat x86_64 (got: ${a:-none})" >&2; exit 1;; esac
      echo "Half-Life Mods.app/Contents/Resources/mods/$b/$role.dylib" >> "$SHIP_LIST"
    done
    nmods=$((nmods + 1))
  done
  echo "[make-dmg] mod builds bundled and arch-checked: $nmods"
fi

# md5 helper that is portable across this box and Tiger (both BSD md5): the hash
# is the last whitespace field of `md5 <file>` on macOS/Tiger.
src_sums() { while IFS= read -r f; do
  printf '%s  %s\n' "$(md5 "$IMG/$f" | awk '{print $NF}')" "$f"; done < "$SHIP_LIST" | sort; }
SRC_SUMS="$(src_sums)"

mkdir -p "$REPO_ROOT/dist"
REMOTE="/tmp/hl-dmg-$VERSION"

attempt=0; verified=no
while [ "$attempt" -lt 3 ]; do
  attempt=$((attempt + 1))
  echo "[make-dmg] attempt $attempt/3: ship staged image to $DMG_HOST and run hdiutil"
  ssh "$DMG_HOST" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
  rsync -a -e 'ssh -o ServerAliveInterval=15' "$IMG/" "$DMG_HOST:$REMOTE/img/"
  scp -q "$SHIP_LIST" "$DMG_HOST:$REMOTE/ship-files.txt"
  # UDZO = zlib-compressed read-only image; widest compatibility incl. Panther.
  ssh "$DMG_HOST" "rm -f '$REMOTE/out.dmg' && \
    hdiutil create -volname '$VOLNAME' -srcfolder '$REMOTE/img' \
      -ov -format UDZO '$REMOTE/out.dmg' >/dev/null && \
    hdiutil verify '$REMOTE/out.dmg' >/dev/null"

  # md5 the shipped files INSIDE the finished image (mount -> hash -> detach) at
  # a private mountpoint (not /Volumes) to dodge any stale same-name mount.
  DMG_SUMS=$(ssh "$DMG_HOST" bash -s "$REMOTE" <<'REMOTE_EOF' || true
REM="$1"; MP="$REM/mnt"
mkdir -p "$MP"
hdiutil detach "$MP" >/dev/null 2>&1 || true
hdiutil attach -nobrowse -readonly -mountpoint "$MP" "$REM/out.dmg" >/dev/null 2>&1 || exit 7
while IFS= read -r f; do
  printf '%s  %s\n' "$(md5 "$MP/$f" 2>/dev/null | awk '{print $NF}')" "$f"
done < "$REM/ship-files.txt" | sort
hdiutil detach "$MP" >/dev/null 2>&1 || hdiutil detach -force "$MP" >/dev/null 2>&1 || true
REMOTE_EOF
)
  if [ "$DMG_SUMS" = "$SRC_SUMS" ]; then verified=yes; break; fi
  echo "[make-dmg] WARNING: DMG contents differ from source (attempt $attempt) - retrying" >&2
  echo "--- source ---"; echo "$SRC_SUMS"
  echo "--- in dmg ---"; echo "$DMG_SUMS"
done

[ "$verified" = yes ] || {
  echo "[make-dmg] FATAL: could not produce an uncorrupted DMG after $attempt attempts on $DMG_HOST." >&2
  echo "           The build host may have a failing disk/RAM. Try a different DMG_HOST." >&2
  exit 1
}
echo "[make-dmg] verified: engine + game code inside the DMG match source byte-for-byte"

# Fetch the container back and confirm scp didn't corrupt it in transit either.
scp -q "$DMG_HOST:$REMOTE/out.dmg" "$OUT"
RMT_MD5=$(ssh "$DMG_HOST" "md5 '$REMOTE/out.dmg' | awk '{print \$NF}'")
LCL_MD5=$(md5 "$OUT" | awk '{print $NF}')
[ "$RMT_MD5" = "$LCL_MD5" ] || { echo "[make-dmg] FATAL: scp corrupted $OUT ($RMT_MD5 != $LCL_MD5)" >&2; exit 1; }
ssh "$DMG_HOST" "rm -rf '$REMOTE'" 2>/dev/null || true

echo "[make-dmg] OK - $OUT"
echo "           container md5 $LCL_MD5, contents verified vs source, built on $DMG_HOST"
ls -lh "$OUT"
