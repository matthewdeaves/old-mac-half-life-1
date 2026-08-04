#!/bin/bash
# Assemble Half-Life.app (universal ppc + x86_64) from the flat fat bundle produced
# by the build, plus a legacy .icns from scripts/make-icon.py. Run this ON A MAC that
# has the fat bundle and SetFile (the Lion mini). The result is a double-click app that
# works on 10.3 through 10.5 PPC and 10.7 Intel from one binary - no cwd
# dependence (the game_launch fix resolves libxash next to the executable).
#
#   ./make-app.sh <flat-bundle-dir> <output.app> [icon.icns]
#
# <flat-bundle-dir> is the Half-Life-Universal layout produced by make-universal.sh:
# xash3d + *.dylib + libSDL2-2.0.0.dylib + gamedata/ (BOTH game-dylib arch sets and
# userconfig.cfg).
#
# WE SHIP NO valve FOLDER OF OUR OWN. gamedata/ is installed inside the bundle as
# Contents/Resources/Half-Life/valve, and Contents/Resources/Half-Life becomes the
# engine's READ-ONLY root (fs_rodir, found by FS_AppleBundledGameRoot). The player
# supplies their own untouched retail valve folder NEXT TO Half-Life.app, and there
# is nothing for them to merge: our recompiled game code never leaves the bundle. The
# writable root is the folder containing the .app (XASH3D_BASEDIR below), so configs
# and saves land in the player's own valve folder, and the bundle stays read-only.
#
# Fullscreen defaults to borderless (mode 2), which is native-res and does NOT switch
# display modes - safe on the G5.
set -euo pipefail

SRC="${1:?flat bundle dir}"
APP="${2:?output .app path}"
ICON="${3:-}"
# LSMinimumSystemVersion must NOT exceed the running OS or LaunchServices refuses to open
# the app - on 10.4 Tiger that surfaces as the "you can't use this application with this
# version of Mac OS X" dialog (10.3 Panther does NOT enforce it, which is why the G3 ran).
# For the UNIVERSAL bundle the floor is the OLDEST supported OS = 10.3.0, so every machine
# (10.3/10.4/10.5/10.7) is allowed to launch; each slice's own LC_VERSION_MIN still gates
# the actual code per arch. Override only for a single-OS build.
MIN_OS="${MIN_OS:-10.3.9}"
# Optional extra args appended to the launcher's exec line AFTER the auto-detected
# per-OS profile below (normally left empty - the launcher self-configures).
EXTRA_ARGS="${EXTRA_ARGS:-}"
# Port version - single source of truth is the repo VERSION file (env overrides).
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PORTVER="${VERSION:-}"
[ -n "$PORTVER" ] || PORTVER="$(tr -d ' \t\n' < "$REPO/VERSION" 2>/dev/null || true)"
[ -n "$PORTVER" ] || PORTVER="1.0.0"

[ -d "$SRC/gamedata/dlls" ] || {
	echo "ERROR: $SRC/gamedata/dlls missing - run make-universal.sh first" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Half-Life"

# engine executable + fat dylibs + x86_64 SDL2 (ppc links SDL statically; harmless on ppc)
cp "$SRC"/xash3d "$SRC"/*.dylib "$APP/Contents/MacOS/"
mv "$APP/Contents/MacOS/xash3d" "$APP/Contents/MacOS/xash3d.bin"

# Launcher wrapper. Two things here are essential and non-obvious:
#  1. XASH3D_BASEDIR points the engine at the folder CONTAINING the .app, so the
#     game data ("valve") sits NEXT TO the app (sibling), writable in place - no
#     read-only / App Support split (which broke menu + config loading).
#  2. DYLD_LIBRARY_PATH forces dlopen() to find OUR libmenu.dylib before macOS's
#     system /usr/lib/libmenu.dylib (ncurses). Without it the engine loads the
#     wrong "libmenu", GetMenuAPI is absent, and the game silently drops to the
#     console with no menu - in every window mode, on both PPC and Intel.
# SMART LAUNCHER - one universal binary, best display profile per machine.
# The fullscreen MECHANISM differs by CPU/GPU (hard-won, see fleet notes); command-line
# flags win over video.cfg because SetFullscreenModeFromCommandLine() runs at video
# init, AFTER config.cfg is exec'd. The display profile is keyed on CPU CAPABILITY first
# (mirroring how dyld already selects the slice by CPU), then on an OS quirk - NOT on the
# OS version alone. The old OS-only keying mis-configured a G3 booted on Tiger/Leopard
# (2nd-partition installs) into the native-res branch, which slideshows on a Rage 128.
#   G3 (PowerPC 750 family, CPU subtype 9): its Rage-128-class GPU is fillrate-bound
#        and MUST run low-res on ANY OS (Panther/Tiger/Leopard). `fullscreen` CVAR is broken
#        on Panther anyway (renders full desktop res, ~15 fps), so exclusive mode-switch is
#        the only way to a real low res: -fullscreen + -width/-height = 800x600. Force -ref gl
#        too: auto-select's gl->soft fallback iterator-invalidates VidInit.
#   Panther (10.3) on any GPU: same broken-cvar story, so also exclusive 800x600.
#   G4 / G5 / Intel on 10.4+: -borderless (mode 2) = native-res desktop-sized window, NO
#        display mode-switch. A machine with a built-in display, the iMac G5 above all,
#        should run at its panel's own resolution, and mode 2 is how that is done without
#        a mode-switch. The G4 and G5 both take the ppc7400 slice; Intel is x86_64.
# Force -ref gl on every machine (see G3 note). There is no launcher retry anywhere: a
# failed launch should be visible rather than masked. -console is passed on every machine so the developer console is reachable: it sets
# host.allow_console (the ~ overlay). mainui is patched (patch-mainui-console.py) to show the
# on-screen "Console" menu button UNCONDITIONALLY, so -dev 1 is NO LONGER needed - developer
# stays 0 (no verbose logging). con_notifytime "0" (configs/userconfig.cfg) is STILL required
# to hide the top-left notify area: NORMAL console messages (map load, "Setting up renderer")
# echo there regardless of developer mode; the ~ overlay keeps the CLI fully accessible.
# Unquoted heredoc so $EXTRA_ARGS expands now; runtime $ vars are backslash-escaped.
# stdout/stderr are captured to last-run.log BESIDE the app (engine console). Not inside
# valve/: that folder is the player's own retail data and we do not write into it.
cat > "$APP/Contents/MacOS/xash3d" <<WRAP
#!/bin/bash
HERE="\$(cd "\$(dirname "\$0")" && pwd)"
export XASH3D_BASEDIR="\$(cd "\$HERE/../../.." && pwd)"
export DYLD_LIBRARY_PATH="\$HERE"
LOG="\$XASH3D_BASEDIR/last-run.log"

# Refuse to run from the disk image. XASH3D_BASEDIR is the folder CONTAINING the
# .app, so on a mounted .dmg that folder is read-only: the engine cannot write
# config.cfg, save games, or even this log, and Custom Game cannot install
# anything. It fails in confusing ways rather than obviously, so stop here and
# say what to do. \`df\` is used rather than statfs because this is a shell
# script that must work on 10.3 through modern macOS.
if df "\$XASH3D_BASEDIR" 2>/dev/null | tail -1 | grep -q "read-only" ||
   ! touch "\$XASH3D_BASEDIR/.hlwritetest" 2>/dev/null; then
	rm -f "\$XASH3D_BASEDIR/.hlwritetest" 2>/dev/null
	MSG="Half-Life cannot run from the disk image. Copy Half-Life.app into a normal folder (your Desktop is fine), put your Half-Life valve folder beside it, then launch it from there."
	osascript -e "display dialog \"\$MSG\" buttons {\"OK\"} default button 1 with icon stop with title \"Copy Half-Life out of the disk image first\"" >/dev/null 2>&1 ||
		echo "\$MSG" >&2
	exit 1
fi
rm -f "\$XASH3D_BASEDIR/.hlwritetest" 2>/dev/null

# The player supplies the game data; we ship none of it. Our recompiled game code
# lives inside this bundle, but Half-Life's own maps, models, sounds and WADs are
# Valve's and have to come from the player's retail copy, in a folder called "valve"
# sitting NEXT TO Half-Life.app. Without it the engine fails deep in filesystem init
# with "game directory valve not exist" on a console nobody sees, then quits with no
# window - which reads as a broken app rather than as missing data. Say so plainly.
if [ ! -d "\$XASH3D_BASEDIR/valve" ]; then
	MSG="Half-Life needs your game data. Put your retail Half-Life \"valve\" folder next to Half-Life.app, in the same folder, then launch it again. Nothing needs merging: this app carries all of the Mac game code itself."
	osascript -e "display dialog \"\$MSG\" buttons {\"OK\"} default button 1 with icon stop with title \"No valve folder found\"" >/dev/null 2>&1 ||
		echo "\$MSG" >&2
	exit 1
fi

# CPU capability first. A G3 is the PowerPC 750 family: CPU subtype 9 (G4 7400/7450 = 10/11,
# G5 970 = 100), which `machine` reports as "ppc750". NOTE: hw.optional.altivec is an
# Intel-only sysctl - it does NOT exist on PowerPC Mac OS X (errors on 10.4), so "no AltiVec"
# must be detected via the 750 subtype, not that sysctl. hw.cpusubtype exists on 10.3-10.5.
# Gate on uname -p = powerpc so no Intel subtype number can ever match the G3 branch.
OS="\$(sw_vers -productVersion)"
if [ "\$(uname -p)" = "powerpc" ] && { [ "\$(sysctl -n hw.cpusubtype 2>/dev/null)" = "9" ] || [ "\$(machine 2>/dev/null)" = "ppc750" ]; }; then
	PROFILE="-ref gl -fullscreen -width 800 -height 600"           # G3 (ppc750): low-res exclusive fullscreen, ANY OS
else
	# -borderless means SDL fullscreen-desktop, and on 10.7 that leaves the menu
	# bar in place: the window is the full 1920x1080 at 0,0 but the GL drawable is
	# 1920x1058, so the top 22 pixels are never painted and show as a white strip.
	# Measured on mini-intel; -fullscreen gives "real 1920x1080" and no strip.
	# PowerPC does NOT have that problem on any OS version it runs, so it takes
	# the native-resolution path instead of the exclusive-fullscreen quirks this
	# fleet has a history of.
	#
	# 10.3 used to be forced to exclusive 800x600 here, on the grounds that
	# Panther's fullscreen cvar is broken. It is, and -borderless never touches
	# it: measured on the dual G5's Panther partition, 10.3.9 build 7W98, ATI
	# Radeon 9600, "Window size: 1680x1050 (real 1680x1050)" with the menu drawn
	# through hardware GL. So a G4 or G5 on Panther gets its own desktop
	# resolution like every other PowerPC machine. Issue #41. The G3 is still
	# pinned to 800x600 above, by CPU and not by OS, because that is a fillrate
	# decision about its Rage 128 rather than anything to do with Panther.
	if [ "\$(uname -p)" = "powerpc" ]; then
		PROFILE="-ref gl -borderless"    # G4/G5, 10.3 through 10.5: native-res borderless
	else
		# Intel: exclusive fullscreen AT THE DESKTOP RESOLUTION.
		#
		# -fullscreen alone is not enough, and the reason is in the engine.
		# SetWidthAndHeightFromCommandLine() (client/dll_int/ref_common.c) returns
		# without calling R_SaveVideoMode at all when neither -width nor -height is
		# given, so the render size stays at whatever the width/height cvars hold.
		# On a first run there is no video.cfg, so those are the built-in defaults
		# rather than the display - while -fullscreen sets WINDOW_MODE_FULLSCREEN,
		# exclusive. The Video Modes menu then reports the DISPLAY mode, 1920x1080,
		# next to a picture plainly not being rendered at it. Picking any other
		# mode and picking 1920x1080 back writes a real video.cfg and it is correct
		# from then on, which is exactly what was seen on mini-intel.
		#
		# The G4/G5 never hit this because -borderless is SDL fullscreen-desktop,
		# which is defined to match the desktop and needs no width or height.
		#
		# So ask the display what it is. system_profiler is the only way to get
		# this from a shell on 10.7 and costs 0.31s here, measured, which is
		# nothing against engine startup. If it cannot be read we fall back to the
		# old behaviour rather than pass a made-up size.
		RES="\$(system_profiler SPDisplaysDataType 2>/dev/null | \
			sed -n 's/.*Resolution: \([0-9][0-9]*\) x \([0-9][0-9]*\).*/\1 \2/p' | head -1)"
		VW="\$(echo \$RES | awk '{print \$1}')"
		VH="\$(echo \$RES | awk '{print \$2}')"
		if [ -n "\$VW" ] && [ -n "\$VH" ]; then
			PROFILE="-ref gl -fullscreen -width \$VW -height \$VH"
		else
			PROFILE="-ref gl -fullscreen"
		fi
	fi
fi

# Anything the caller passes wins over the profile.
#
# The profile used to be handed to the engine unconditionally, with "\$@" after
# it, so a caller adding -ref soft got TWO -ref flags and the profile's won. That
# is not a cosmetic problem: it silently invalidated two renderer tests on the
# bench machines, both of which logged "Loading renderer: gl" while being
# recorded as software results. A flag you can pass and watch be ignored is worse
# than one that is not accepted at all.
#
# So drop from the profile any flag the caller has overridden. -width and -height
# go together with -fullscreen, because a caller choosing a display mode wants
# the whole mode, not a half-applied one.
for a in "\$@"; do
	case "\$a" in
		-ref)         PROFILE=\$( echo " \$PROFILE " | sed 's/ -ref [a-z]*//g' ) ;;
		-fullscreen|-borderless|-windowed|-width|-height)
			PROFILE=\$( echo " \$PROFILE " | sed -e 's/ -fullscreen//g' -e 's/ -borderless//g' -e 's/ -windowed//g' -e 's/ -width [0-9]*//g' -e 's/ -height [0-9]*//g' ) ;;
	esac
done

echo "launcher: xash3d.bin -console \$PROFILE $EXTRA_ARGS \$@" > "\$LOG"
exec "\$HERE/xash3d.bin" -console \$PROFILE $EXTRA_ARGS "\$@" >> "\$LOG" 2>&1
WRAP
chmod +x "$APP/Contents/MacOS/xash3d"

# OUR game code, inside the bundle, under the rodir's own "valve".
#
# It has to be at THAT level, not at the rodir root: Host_CheckGameLibraries runs a
# pre-flight look for the game libraries via Platform_LibraryExists( path, true ),
# and that gamedironly flag restricts the search to FS_GAMEDIR_PATH |
# FS_CUSTOM_PATH | FS_GAMERODIR_PATH. The rodir ROOT is FS_STATIC_PATH, so dylibs
# sitting there are invisible to it and the engine aborts at startup with
# "missing game library ... Required: apple-amd64" even though the real dlopen
# would have found them. <rodir>/valve/ gets FS_GAMERODIR_PATH and is seen.
#
# This does NOT create a phantom second "valve" in Custom Game: FS_InitStdio only
# registers a rodir directory as a game if it holds gameinfo.txt or liblist.gam
# (FS_CheckForXashGameDir), and ours holds neither - just game code and artwork.
# The previous layout DID create one, because Contents/Resources/Half-Life/valve
# was a symlink to the player's real valve folder, liblist.gam included.
#
# The rodir is the LOWEST-priority searchpath, so anything the player puts in their
# own valve folder still overrides what we ship.
mkdir -p "$APP/Contents/Resources/Half-Life/valve"
cp -R "$SRC/gamedata/." "$APP/Contents/Resources/Half-Life/valve/"
find "$APP/Contents/Resources/Half-Life" -name '.DS_Store' -delete 2>/dev/null || true

# Icon. Optional as an ARGUMENT, but default to the repo's canonical one rather
# than shipping an iconless bundle: forgetting the third argument used to produce
# an app with no CFBundleIconFile at all, which Finder renders as the blank
# generic application icon. That is a silent, easy mistake to make and it reaches
# the release.
if [ -z "${ICON:-}" ]; then
	CANON="$(cd "$(dirname "$0")/.." && pwd)/MacOSX/Half-Life.icns"
	[ -f "$CANON" ] && ICON="$CANON"
fi

ICONKEY=""
if [ -n "$ICON" ] && [ -f "$ICON" ]; then
	cp "$ICON" "$APP/Contents/Resources/Half-Life.icns"
	ICONKEY='	<key>CFBundleIconFile</key><string>Half-Life.icns</string>'
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Half-Life</string>
	<key>CFBundleDisplayName</key><string>Half-Life</string>
	<key>CFBundleIdentifier</key><string>org.xash3d.halflife</string>
	<key>CFBundleExecutable</key><string>xash3d</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleSignature</key><string>????</string>
	<key>CFBundleVersion</key><string>$PORTVER</string>
	<key>CFBundleShortVersionString</key><string>$PORTVER</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
$ICONKEY
	<key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Make Finder honor CFBundleIconFile (clear any stale custom-icon flag).
if command -v SetFile >/dev/null 2>&1; then
	SetFile -a c "$APP" 2>/dev/null || true
elif [ -x /Developer/Tools/SetFile ]; then
	/Developer/Tools/SetFile -a c "$APP" 2>/dev/null || true
fi

echo "built $APP"
# xash3d is the shell launcher; the Mach-O is xash3d.bin. Diagnostic only, never fatal.
lipo -info "$APP/Contents/MacOS/xash3d.bin" 2>/dev/null | sed 's/^/  /' || true
