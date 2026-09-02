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

# ---- claim the machines this drives ----------------------------------------
#
# Two machines, and they get different treatment because they are used
# differently. Issue #11.
#
# DMG_HOST does the work: a whole app bundle rsynced onto it, then hdiutil. It is
# claimed for the run, by re-execing under the picker exactly as deploy-dmg.sh
# and smoke-dmg.sh do. The guard compares RETRO_BENCH_LOCK to THIS host rather
# than testing that it is empty, because the picker's --run exports it and a bare
# test would skip the claim whenever make-dmg is called from inside another
# claim (issue #13).
#
# Both hosts are exported first so the re-exec does not repeat the probing above
# and cannot pick a different pair the second time round.
#
# SRC_HOST is only READ from: rsync pulls the built bundle off it. It is checked
# rather than claimed, because claiming a build mini for the length of a Tiger
# packaging run would hold an idle machine for many minutes to protect a
# read-only copy. scripts/lock-check.sh refuses only when somebody ELSE holds it.
export SRC_HOST DMG_HOST
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$DMG_HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
  export RETRO_BENCH_LOCK="$DMG_HOST"
  exec "$_PICK" --run "$DMG_HOST" "make-dmg" -- "$0" "$@"
fi

"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lock-check.sh" "$SRC_HOST" \
  "fetch the built bundle from $SRC_HOST" || exit 1

# ---- stage the image contents locally (app + valve payload + README) --------
STAGE="$(mktemp -d -t hl-dmg)"
trap 'rm -rf "$STAGE"' EXIT
IMG="$STAGE/img"
mkdir -p "$IMG"

# Fetch a tree from the build host, and survive the link dropping mid-transfer.
#
# This is not defensive programming for its own sake. The path from a build mini
# to this box was measured at ~0.55 MB/s (docs/apple-silicon-arm64.md in the
# build-host repo), and a fetch HAS hung here, at 54 MB of 138, and had to be
# killed and restarted by hand. The payload has since grown: the mod installer
# carries four slices of 25 mod dylib pairs rather than two.
#
# --partial keeps what arrived so a retry resumes rather than starting again, and
# ServerAliveInterval makes a dead link fail in seconds instead of hanging until
# TCP gives up. The outbound leg to the packaging host already had a retry loop;
# this is the same treatment for the leg that actually failed.
fetch_tree() {
  src="$1"; dst="$2"; what="$3"
  attempt=1
  # Five, not three. Measured 2026-08-08: this link degraded to 0.075 MB/s mid
  # session, having been 0.55 MB/s, while ssh control connections stayed fine and
  # the mini answered pings. Three attempts was not enough to get 350 MB across.
  # --partial makes every attempt resume rather than restart, so more attempts is
  # cumulative progress and not repeated work.
  while [ "$attempt" -le 5 ]; do
    if rsync -a --partial -e 'ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4' \
         "$src" "$dst"; then
      return 0
    fi
    echo "[make-dmg] $what: transfer failed (attempt $attempt/5), retrying" >&2
    attempt=$(( attempt + 1 ))
    sleep 5
  done
  echo "[make-dmg] FATAL: could not fetch $what from $SRC_HOST after 5 attempts" >&2
  exit 1
}

echo "[make-dmg] fetch built app from $SRC_HOST"
# The app is self-contained now - our game code rides inside it under
# Contents/Resources/Half-Life, so there is no second payload to fetch and no
# symlink to preserve.
fetch_tree "$SRC_HOST:$SRC_APP/" "$IMG/Half-Life.app/" "Half-Life.app"

# The mod installer ("Half-Life Mods.app", fat ppc + i386 + x86_64 + arm64, and
# by far the largest thing on the image because it carries our prebuilt game
# dylibs for all 25 mods at every one of those slices). OPTIONAL: an engine-only
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
  fetch_tree "$SRC_HOST:$SRC_MODS_APP/" "$IMG/Half-Life Mods.app/" "Half-Life Mods.app"
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
  fetch_tree "$SRC_HOST:$SRC_SR_APP/" "$IMG/Half-Life System Report.app/" "Half-Life System Report.app"
  SHIP_SR_APP=yes
else
  echo "[make-dmg] NOTE: no system report app at $SRC_HOST:$SRC_SR_APP"
fi

BIN="$IMG/Half-Life.app/Contents/MacOS/xash3d.bin"
[ -f "$BIN" ] || { echo "[make-dmg] no xash3d.bin in fetched app - check SRC_APP" >&2; exit 1; }

# Sanity: must be the full fat, not a stray single-arch binary.
# ppc970 is deliberately absent since v1.4.0: the G5 takes ppc7400. See
# docs/adr/0001-slices-are-chosen-by-cpu-capability.md.
#
# This used `lipo -archs`, which works HERE and only here. This script runs on
# the dev box and stages into a local temp dir, so the lipo that reads $BIN is
# the modern one; the Tiger host is only ever handed the finished tree to run
# hdiutil on. That is why releases have been cutting cleanly.
#
# It is still worth not depending on: `lipo -archs` DOES NOT EXIST ON TIGER
# (measured on mini-g4, 10.4.11: "lipo: unknown flag: -archs"), so the moment
# anyone runs this on the packaging host to debug something, ARCHS comes back
# empty and the next line reports a missing ppc7400 slice on a perfectly good
# binary. `lipo -info` is present everywhere.
#
# Old lipo also cannot NAME every slice. Tiger prints a correct fat as
#   ppc750 ppc7400 i386 (cputype (16777223) cpusubtype (-2147483645))
# naming ppc750, ppc7400 and i386 happily while showing x86_64 as a number, and
# Lion does the same for arm64. So match on the name first and fall back to the
# cputype for the ones a given lipo predates.
ARCHS="$(lipo -info "$BIN" 2>/dev/null | sed 's/.*: //')"
echo "[make-dmg] fat slices: ${ARCHS:-<none>}"

has_arch () {
  case " $ARCHS " in *" $1 "*) return 0 ;; esac
  case "$1" in
    x86_64) case "$ARCHS" in *16777223*) return 0 ;; esac ;;   # CPU_TYPE_X86_64
    arm64)  case "$ARCHS" in *16777228*) return 0 ;; esac ;;   # CPU_TYPE_ARM64
  esac
  return 1
}

# Every slice build-pins.sh declares on its "Fat slices" line must be here. i386
# is for the 2006 Core Solo and Core Duo machines, which have no 64-bit mode.
for a in ppc7400 i386 x86_64; do
  has_arch "$a" || { echo "[make-dmg] fat binary missing $a slice (got: ${ARCHS:-none})" >&2; exit 1; }
done
has_arch ppc || has_arch ppc750 || { echo "[make-dmg] fat binary missing the generic ppc (G3) slice" >&2; exit 1; }
# arm64 is built on a different machine, so a fuse without it is possible by
# design and every fuse must SAY which way it went rather than leave it to be
# discovered from the finished image.
if has_arch arm64; then
  echo "[make-dmg] arm64 slice present"
  HAVE_ARM64=1
else
  echo "[make-dmg] NOTE: no arm64 slice on this image - Apple Silicon will not launch it" >&2
  HAVE_ARM64=0
fi

# Confirm the game code for both endian families is present, INSIDE the bundle.
# GAMEDATA sits under the engine's read-only root, which FS_AppleBundledGameRoot
# finds by probing for a valve/ inside the bundle. If it is absent the engine has
# no rodir at all and aborts at startup with "missing game library".
GAMEDATA="Half-Life.app/Contents/Resources/Half-Life/valve"
# One pair per architecture the engine can dlopen: the engine asks for these BY
# NAME (3rdparty/library_suffix), so an i386 engine looks for hl_i386.dylib and
# nothing else will do.
# NOTE the i386 pair has NO suffix. COM_GenerateLibraryName special-cases 32-bit
# x86 on Apple/Windows/Linux and gives it none, because that was Half-Life's
# original platform, so it is hl.dylib and client.dylib while every other
# architecture takes the _<arch> form.
for g in cl_dlls/client_ppc.dylib cl_dlls/client_amd64.dylib cl_dlls/client.dylib \
         dlls/hl_ppc.dylib dlls/hl_amd64.dylib dlls/hl.dylib; do
  [ -f "$IMG/$GAMEDATA/$g" ] || { echo "[make-dmg] missing shipped game code: $GAMEDATA/$g" >&2; exit 1; }
done
# An arm64 engine with no arm64 game code would launch to "missing game
# library" on exactly the machines the slice was added for.
if [ "$HAVE_ARM64" = 1 ]; then
  for g in cl_dlls/client_arm64.dylib dlls/hl_arm64.dylib; do
    [ -f "$IMG/$GAMEDATA/$g" ] || { echo "[make-dmg] arm64 engine but missing game code: $GAMEDATA/$g" >&2; exit 1; }
  done
fi
# Nothing but the two apps and the text files may ship. A stray valve folder here
# would put our dylibs back outside the bundle and reintroduce the merge step.
[ -e "$IMG/valve" ] && { echo "[make-dmg] a valve folder is staged - we ship none" >&2; exit 1; }
true

# Our PORT version - single source of truth is the repo VERSION file (arg overrides).
if [ -n "${1:-}" ]; then
  # Strip a leading v: the usage line's own example used to produce vv0.21,
  # which is the mistake test-artifact.sh exists to catch after the fact.
  PORTVER="${1#v}"
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

# The slice list is MEASURED off the binary that is about to ship, not declared.
# $ARCHS came from `lipo -info "$BIN"` above, and this script runs on the dev box,
# whose lipo can name every architecture we build; the old-lipo cputype fallbacks
# exist for the build hosts, not here. Normalised to the " . " separator the rest
# of BUILD-INFO uses, and any trailing "(cputype ...)" noise dropped.
#
# It was a hardcoded literal in build-pins.sh until it under-reported arm64 on a
# five-slice release. tests/test-artifact.sh compares this line against lipo, and
# that is the check that caught it.
SLICE_LINE="$(printf '%s' "$ARCHS" | sed 's/(cputype[^)]*)*//g; s/  */ /g; s/^ //; s/ $//; s/ / . /g')"
provenance_table "$OURHASH" "$BUILDDATE" "$PORTVER" "$SLICE_LINE" \
	| tee "$IMG/BUILD-INFO.txt" > "$APPRES/BUILD-INFO.txt"

# Ship the repo's canonical icons (source of truth), regardless of what the build
# box baked into the apps - so an icon fix reaches the DMG without a full rebuild.
#
# ALL THREE apps, not just the game. This used to refresh Half-Life.app only and
# merely VERIFY the other two, so the mod installer and the system report kept
# whatever icon was baked in whenever they were last built. New artwork landed,
# the game got it, and those two silently shipped icons weeks older. Their build
# dirs are not rebuilt by build-all.sh either, so nothing else would have caught
# it.
for pair in "Half-Life.app:Half-Life.icns" \
            "Half-Life Mods.app:Half-Life-Mods.icns" \
            "Half-Life System Report.app:Half-Life-SysReport.icns"; do
  appname="${pair%%:*}"; icnsname="${pair##*:}"
  [ -d "$IMG/$appname" ] || continue
  [ -f "$REPO_ROOT/MacOSX/$icnsname" ] || continue
  cp "$REPO_ROOT/MacOSX/$icnsname" "$IMG/$appname/Contents/Resources/$icnsname"
  # Copying the file is NOT enough: without CFBundleIconFile the Finder ignores
  # it entirely and draws the blank generic app icon. make-app.sh only wrote that
  # key when it was handed an icon argument, so a bundle assembled without one
  # shipped iconless and looked like an icon-rendering bug rather than a missing
  # plist entry. Set it here too, so the release is right regardless of how the
  # bundle was assembled.
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $icnsname" "$IMG/$appname/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $icnsname" "$IMG/$appname/Contents/Info.plist"
  echo "[make-dmg] icon refreshed from repo: $appname -> $icnsname"
done

# Refuse to ship an app that will draw as a blank generic icon. Both halves have
# to be true - the .icns present in Resources AND named by CFBundleIconFile - and
# it is exactly the combination that failed silently before.
for pair in "Half-Life.app:Half-Life.icns" \
            "Half-Life Mods.app:Half-Life-Mods.icns" \
            "Half-Life System Report.app:Half-Life-SysReport.icns"; do
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

# First-run key bindings: WASD movement instead of Valve's 1998 arrow-only
# defaults. Lives at the rodir valve/ level, the lowest-priority searchpath, so
# the engine only sees it on a machine with no config.cfg of its own; the
# player's own config always outranks it.
if [ -f "$REPO_ROOT/configs/config.cfg" ]; then
  cp "$REPO_ROOT/configs/config.cfg" "$IMG/$GAMEDATA/config.cfg"
  echo "[make-dmg] $GAMEDATA/config.cfg: shipped first-run binds (WASD)"
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
PowerPC, Intel and Apple Silicon Macs. The right code slice (PowerPC G3,
PowerPC G4/G5, 32-bit Intel, 64-bit Intel or Apple Silicon) and the right
renderer + display mode are chosen automatically at launch.

CHECK YOUR MAC IS COVERED
-------------------------
The app carries one code slice per CPU family, and macOS picks by CPU alone -
it ignores the OS version. So an unsupported combination does NOT fall back to
a slice that would have worked; it just fails to launch. Check this table:

    G3  (PowerPC 750)              10.3.9 Panther, 10.4 Tiger or 10.5 Leopard
    G4  (PowerPC 7400/7450)        10.3.9 Panther, 10.4 Tiger or 10.5 Leopard
    G5  (PowerPC 970)              10.3.9 Panther, 10.4 Tiger or 10.5 Leopard
    Intel, 32-bit (Core Solo/Duo)  10.6 Snow Leopard
    Intel, 64-bit                  10.6.8 Snow Leopard or newer
    Apple Silicon                  macOS 11 or newer, native arm64

Every PowerPC slice is built for 10.3.9, so any PowerPC Mac from Panther up
should run this. Confirmed here on a G3 under 10.3.9 and 10.4, a G4 under
10.4, G5s under 10.3.9, 10.4 and 10.5, Intel minis under 10.6.8 and 10.7, and
an M5 under macOS 26. The other combinations are untested only because there
is no machine set up that way, and a report either way is useful - see below.

One honest gap: the 32-bit Intel slice has not yet been run on a real Core
Solo or Core Duo Mac, only proven loadable on 64-bit machines. If you have a
2006 Mac mini, iMac, MacBook or MacBook Pro, your report is especially useful.

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
1. Double-click "Fix Half-Life.command" on this disk image. It copies
   Half-Life to ~/Half-Life, your home folder, and clears the two things
   recent macOS does to an unsigned app before it can be double-clicked (see
   MODERN macOS below). On Panther, Tiger or Leopard this step still works,
   it just has nothing to clear.
2. Copy your own "valve" folder into ~/Half-Life, beside Half-Life.app,
   whole and unmodified. It should contain at least:
       valve/pak0.pak
       valve/liblist.gam
       valve/*.wad   (halflife.wad, decals.wad, liquids.wad, xeno.wad, ...)
       valve/maps/  valve/models/  valve/sound/  valve/sprites/  valve/gfx/
3. Double-click Half-Life.app.

Doing this by hand instead: copy Half-Life.app into any normal folder (your
home folder or /Applications both work - NOT Desktop, Documents or
Downloads, recent macOS silently blocks an unsigned app writing there, see
MODERN macOS below), put your "valve" folder beside it, then launch it.

Final layout:
   ~/Half-Life/Half-Life.app                 (ours: engine + Mac game code inside)
   ~/Half-Life/valve/                        (yours: retail game data, untouched)

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
   https://github.com/matthewdeaves/old-mac-half-life-1/issues

It reads only and sends nothing anywhere. It runs on any PowerPC Mac from
10.3, 32-bit Intel from 10.4, 64-bit Intel from 10.5 and Apple Silicon
natively, so it starts on machines where the game does not.

The tested list above is the hardware available here, not the limit of what can
work. Reports are how that list gets widened, and a report that it simply worked
is as useful as one that it did not.

MODERN macOS (Gatekeeper and privacy protection)
-------------------------------------------------
The app is unsigned. On recent macOS this causes two separate problems, both
of which "Fix Half-Life.command" (above, INSTALL step 1) handles for you:

1. Gatekeeper quarantines it, so the very first launch is blocked with a
   warning. (Manual fix: right-click Half-Life.app and choose Open, or run
   xattr -dr com.apple.quarantine on it.)
2. Recent macOS silently blocks an unsigned app from writing its saves and
   settings if it is stored inside Desktop, Documents or Downloads - no
   prompt, and Full Disk Access does not help, because it cannot attach to
   an app with no stable signed identity. If you see a dialog saying macOS
   is blocking Half-Life, this is why: move the whole Half-Life folder to
   your home folder or /Applications and launch it from there.

Neither applies on Panther, Tiger or Leopard.

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

Project: https://github.com/matthewdeaves/old-mac-half-life-1
EOF

# ---- double-click fixer for modern macOS's two unsigned-app frictions -------
# Quarantine and TCC's Desktop/Documents/Downloads write-block used to both be
# manual steps in the README above (right-click Open, or an xattr command
# typed by hand, plus "move the folder yourself" once a player already hit
# the privacy-protection dialog from Contents/MacOS/xash3d). A human is not
# guaranteed to be there to do that - same reasoning as deploy-dmg.sh's own
# quarantine strip, applied to a player's own download instead of a bench
# deploy. A .command file opens in Terminal on double-click, no other click
# needed. Not needed and harmless on Panther/Tiger/Leopard: neither
# restriction exists pre-10.15, so every check below finds nothing to do.
cat > "$IMG/Fix Half-Life.command" <<'FIXEOF'
#!/bin/bash
# Run this once if Half-Life won't open, or before you play for the first
# time on a Mac running Sequoia or newer.
set +e
HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
TARGET="$HOME/Half-Life"

echo "Half-Life fixer"
echo "==============="
echo

# Step 1: get off the disk image, if that is where this is running from.
# Same detection as the game's own launcher (Contents/MacOS/xash3d): a
# read-only volume cannot take the write-test file at all.
ON_DMG=0
if ! touch "$HERE/.hlfixtest" 2>/dev/null; then
	ON_DMG=1
else
	rm -f "$HERE/.hlfixtest"
fi

if [ "$ON_DMG" = 1 ]; then
	echo "Running from the disk image. Copying Half-Life to:"
	echo "    $TARGET"
	echo
	mkdir -p "$TARGET"
	for item in "Half-Life.app" "Half-Life Mods.app" "Half-Life System Report.app" "README.txt" "BUILD-INFO.txt"; do
		if [ -e "$HERE/$item" ]; then
			cp -R "$HERE/$item" "$TARGET/" && echo "  copied $item"
		fi
	done
	HERE="$TARGET"
	echo
	if [ ! -d "$HERE/valve" ]; then
		echo "Your own Half-Life \"valve\" folder is not here yet. Copy it in"
		echo "beside Half-Life.app at:"
		echo "    $TARGET"
		echo "before you launch the game."
		echo
	fi
else
	# Step 2: already off the image. Is it somewhere recent macOS silently
	# blocks an unsigned app's saves and settings writes (no prompt, no
	# error until the app's own check catches it)?
	case "$HERE" in
		"$HOME/Desktop"|"$HOME/Desktop"/*|"$HOME/Documents"|"$HOME/Documents"/*|"$HOME/Downloads"|"$HOME/Downloads"/*)
			if [ "$HERE" = "$TARGET" ]; then
				: # already the target
			elif [ -e "$TARGET" ]; then
				echo "This folder is inside Desktop, Documents or Downloads, which recent"
				echo "macOS blocks an unsigned app from writing to - but $TARGET"
				echo "already exists, so this cannot move it there for you."
				echo "Move this folder to your home folder or /Applications by hand,"
				echo "then run this again."
				echo
			else
				echo "This folder is inside Desktop, Documents or Downloads. Recent macOS"
				echo "silently blocks an unsigned app's saves and settings there, so"
				echo "moving the whole folder to:"
				echo "    $TARGET"
				echo
				mv "$HERE" "$TARGET" && HERE="$TARGET" && echo "  moved."
				echo
			fi
			;;
		*)
			echo "Location looks fine: $HERE"
			echo
			;;
	esac
fi

# Step 3: clear Gatekeeper quarantine on every bundle here. Same xattr
# pattern as deploy-dmg.sh: `-d -r`, not `-dr`, and never fatal if the flag
# was never set.
echo "Clearing quarantine..."
for app in "$HERE/Half-Life.app" "$HERE/Half-Life Mods.app" "$HERE/Half-Life System Report.app"; do
	[ -d "$app" ] || continue
	find "$app" -print0 2>/dev/null | xargs -0 xattr -d com.apple.quarantine 2>/dev/null || true
	echo "  $(basename "$app")"
done

echo
echo "Done. Half-Life is at:"
echo "    $HERE"
echo
echo "Double-click Half-Life.app from there to play."
echo
read -p "Press Return to close this window..." _
FIXEOF
chmod +x "$IMG/Fix Half-Life.command"

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
Half-Life.app/Contents/Resources/Half-Life/valve/cl_dlls/client.dylib
Half-Life.app/Contents/Resources/Half-Life/valve/dlls/hl_ppc.dylib
Half-Life.app/Contents/Resources/Half-Life/valve/dlls/hl_amd64.dylib
Half-Life.app/Contents/Resources/Half-Life/valve/dlls/hl.dylib
Half-Life.app/Contents/Resources/Half-Life/valve/userconfig.cfg
LIST
# The corruption this list exists to catch is exactly as fatal in the arm64
# pair, when it shipped, as in any other. The unsuffixed pair above is i386.
if [ "$HAVE_ARM64" = 1 ]; then
  cat >> "$SHIP_LIST" <<'LIST'
Half-Life.app/Contents/Resources/Half-Life/valve/cl_dlls/client_arm64.dylib
Half-Life.app/Contents/Resources/Half-Life/valve/dlls/hl_arm64.dylib
LIST
fi

# Every mod dylib we ship gets the same byte-for-byte treatment as the engine.
# That is ~130 MB across 48 files, and it is the point: the corruption this check
# exists to catch (a single flipped byte surviving hdiutil verify) is exactly as
# fatal in a mod's game code as in the engine's.
if [ "$SHIP_SR_APP" = yes ]; then
  SRBIN="$IMG/Half-Life System Report.app/Contents/MacOS/HalfLifeSystemReport"
  [ -f "$SRBIN" ] || { echo "[make-dmg] system report app has no executable" >&2; exit 1; }
  echo "[make-dmg] system report slices: $(lipo -archs "$SRBIN")"
  echo "Half-Life System Report.app/Contents/MacOS/HalfLifeSystemReport" >> "$SHIP_LIST"
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
      case " $a " in *" i386 "*) ;; *) echo "[make-dmg] mod $b $role.dylib is not fat i386 (got: ${a:-none})" >&2; exit 1;; esac
      case " $a " in *" x86_64 "*) ;; *) echo "[make-dmg] mod $b $role.dylib is not fat x86_64 (got: ${a:-none})" >&2; exit 1;; esac
      if [ "$HAVE_ARM64" = 1 ]; then
        case " $a " in *" arm64 "*) ;; *) echo "[make-dmg] mod $b $role.dylib has no arm64 slice beside an arm64 engine (got: ${a:-none})" >&2; exit 1;; esac
      fi
      echo "Half-Life Mods.app/Contents/Resources/mods/$b/$role.dylib" >> "$SHIP_LIST"
    done
    nmods=$((nmods + 1))
  done
  echo "[make-dmg] mod builds bundled and arch-checked: $nmods"
fi

# md5 helper that is portable across this box and Tiger (both BSD md5): the hash
# is the last whitespace field of `md5 <file>` on macOS/Tiger.
# ---- ad-hoc code-sign the staged bundles ---------------------------------
# macOS on arm64 refuses to map a page whose code signature does not validate
# and kills the process with CODESIGNING / Invalid Page. Signing also gives each
# bundle a stable identity, so macOS stops re-asking for Desktop/Documents
# access on every launch, which it does for an app it cannot identify.
#
# All THREE apps are signed, not just the game: the Mods app and the System
# Report app are launched by the user too.
#
# Order is not optional: codesign validates a bundle's nested code when it signs
# the bundle, so anything inside must already be signed. Plain dylibs first,
# then each framework as a DIRECTORY, then the .app last. The 25 mod dylib pairs
# are dlopen'd, so they need signing as well.
#
# Signed here rather than on DMG_HOST, which is a Tiger G4 with no codesign and
# no notion of arm64, and before the checksums so the end-to-end byte
# verification hashes the files exactly as they will ship.
if command -v codesign >/dev/null 2>&1; then
	echo "[make-dmg] ad-hoc code-signing the staged bundles"
	find "$IMG" -type f \( -name '*.dylib' -o -name '*.so' \) -not -path '*.framework/*' -print0 2>/dev/null \
	  | while IFS= read -r -d '' f; do codesign --force --sign - "$f" >/dev/null 2>&1 || true; done
	find "$IMG" -type d -name '*.framework' -print0 2>/dev/null \
	  | while IFS= read -r -d '' fw; do
			for stray in "$fw"/*; do
				[ -L "$stray" ] && continue
				[ "$(basename "$stray")" = "Versions" ] && continue
				mkdir -p "$fw/Versions/A/Resources"
				mv "$stray" "$fw/Versions/A/Resources/" 2>/dev/null || true
			done
			codesign --force --sign - "$fw" >/dev/null 2>&1 || true
		done
	# xash3d is a shell launcher; xash3d.bin is the Mach-O it execs. Sign the
	# real binary, then the bundle.
	for app in "$IMG"/*.app; do
		[ -d "$app" ] || continue
		[ -f "$app/Contents/MacOS/xash3d.bin" ] && \
			codesign --force --sign - "$app/Contents/MacOS/xash3d.bin" >/dev/null 2>&1 || true
		codesign --force --sign - "$app" >/dev/null 2>&1 || true
		codesign -v "$app" >/dev/null 2>&1 \
		  || { echo "[make-dmg] FATAL: $(basename "$app") signature does not validate" >&2; exit 1; }
	done
	echo "[make-dmg] signatures verified on all three bundles"
else
	echo "[make-dmg] WARN: no codesign here; the bundles will NOT run on Apple Silicon" >&2
fi

# ---- Finder window layout ----------------------------------------------------
# Built HERE and shipped as data, so the image is still created on the Tiger G4
# with -format UDZO. A .DS_Store is just a file in the staged folder and
# `hdiutil create -srcfolder` below packages it like any other. Tiger has no
# create-dmg and no way to install one, which is why this is not done there.
# Never fatal: an unstyled image is a cosmetic loss, not a broken release.
# scripts/make-dmg-layout.sh, issue #23.
if [ -x "$REPO_ROOT/scripts/make-dmg-layout.sh" ]; then
  if "$REPO_ROOT/scripts/make-dmg-layout.sh" "$VOLNAME" "$IMG/.DS_Store"; then
    echo "[make-dmg] Finder layout staged"
  else
    echo "[make-dmg] NOTE: no Finder layout (see above); image will be unstyled" >&2
    rm -f "$IMG/.DS_Store"
  fi
fi

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
