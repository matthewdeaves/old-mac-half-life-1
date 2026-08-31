#!/bin/bash
# Assemble Half-Life.app (universal, up to five slices) from the flat fat bundle
# produced by the build, plus a legacy .icns from scripts/make-icon.py. Run this ON A
# MAC that has the fat bundle and SetFile (the Lion mini). The result is a double-click
# app that works on 10.3.9 PowerPC through macOS 26 on Apple Silicon from one binary -
# no cwd dependence (the game_launch fix resolves libxash next to the executable).
#
# This script does not know or care which slices are in the binary; make-universal.sh
# fuses whatever it was given and says so. The launcher below picks a display profile
# by CPU, and its one CPU-specific branch is gated on `uname -p = powerpc`, so an
# architecture that did not exist when it was written falls through to the Intel
# path, which is the right default rather than an accident.
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
# For the UNIVERSAL bundle the floor is the OLDEST supported OS = 10.3.9, so every machine
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

# engine executable + fat dylibs + the fat SDL2. PowerPC links SDL statically, so the
# SDL dylib carries only the slices that need it and is harmless on a PowerPC machine.
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
cd "\$XASH3D_BASEDIR"
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
	# Two very different reasons land here, and they need different advice.
	# A read-only volume is the mounted disk image. A WRITABLE volume whose
	# write test still failed is modern macOS privacy protection: the Desktop,
	# Documents and Downloads are gated per-app, an unsigned app launched from
	# the Finder gets the write denied without any prompt, and before this
	# branch existed the launcher then told the user they were running from
	# the disk image, or died with no message at all when the dialog was
	# denied too. Measured on macOS 26: Finder launch died in this write test
	# while the same script ran fine from a terminal that held disk access.
	if df "\$XASH3D_BASEDIR" 2>/dev/null | tail -1 | grep -q "read-only"; then
		MSG="Half-Life cannot run from the disk image. Copy Half-Life.app into a normal folder (your Desktop is fine), put your Half-Life valve folder beside it, then launch it from there."
		TITLE="Copy Half-Life out of the disk image first"
	else
		MSG="macOS privacy protection is blocking Half-Life from writing its settings and saves next to the app. Move the whole Half-Life folder somewhere outside Desktop, Documents and Downloads - your home folder or Applications both work - and launch it from there. Granting the app Full Disk Access is not enough on current macOS: the app is unsigned, so the permission cannot attach to it."
		TITLE="macOS is blocking Half-Life"
	fi
	# Measured on macOS 26: osascript is suppressed in the same Finder-launch
	# context that fails the write test, so a dialog alone leaves the user with
	# a silent bounce-and-quit. A text file in /tmp is writable regardless, and
	# open(1) can still hand it to a text editor; last resort is stderr.
	if ! osascript -e "display dialog \"\$MSG\" buttons {\"OK\"} default button 1 with icon stop with title \"\$TITLE\"" >/dev/null 2>&1; then
		BLOCKNOTE="/tmp/why-half-life-did-not-open.txt"
		printf '%s\n\n%s\n' "\$TITLE" "\$MSG" > "\$BLOCKNOTE" 2>/dev/null &&
			open -e "\$BLOCKNOTE" 2>/dev/null ||
			echo "\$MSG" >&2
	fi
	exit 1
fi
rm -f "\$XASH3D_BASEDIR/.hlwritetest" 2>/dev/null

# A loose engine dylib sitting next to the .app SHADOWS the one inside it, and
# does so silently. Issue #42.
#
# The renderer and the menu are loaded with directpath true, so FS_FindLibrary
# reaches FS_AllowDirectPaths; no searchpath holds a bare dylib name, the lookup
# falls through to the fs_ext_path branch, and that joins fs_rootdir with the
# name and takes it if the file exists. fs_rootdir is XASH3D_BASEDIR, which is
# set three lines above this: the folder containing the .app. So a stale
# libref_gl.dylib beside the app wins over the shipped one, and the symptom is
# whatever that old build did rather than anything pointing at the cause.
#
# WARN, do not delete. This folder holds the player's own retail data and their
# installed mods, and a script that deletes things it does not recognise there
# is a far worse fault than the one it fixes. Naming the files and the fix is
# enough: it is a rare condition, but silent, and a player who has hit it has no
# way at all to work out why.
#
# filesystem_stdio.dylib is deliberately not in this list. It loads before any
# searchpath exists and resolves through DYLD_LIBRARY_PATH, so it cannot be
# shadowed this way, and listing it would be a false alarm.
SHADOW=""
for lib in libxash.dylib libmenu.dylib libref_gl.dylib libref_soft.dylib libSDL2-2.0.0.dylib; do
	[ -e "\$XASH3D_BASEDIR/\$lib" ] && SHADOW="\$SHADOW \$lib"
done
if [ -n "\$SHADOW" ]; then
	MSG="These files are sitting next to Half-Life.app and will be loaded INSTEAD of the ones inside it:\$SHADOW

They are almost certainly left over from an older version. Move them to the Trash and launch again. Nothing inside Half-Life.app needs them."
	# Held in a variable rather than appended here, because the last line of this
	# launcher opens the log with > and would truncate anything written now. The
	# note is emitted after that, so the evidence survives whether or not anyone
	# was looking at a screen. (Measured: the first version of this wrote the
	# line and the run then wiped it.)
	SHADOW_NOTE="launcher: WARNING, loose engine libraries beside the app shadow the bundled ones:\$SHADOW"
	echo "\$MSG" >&2
	# Ask, but only where there is someone to ask. This launcher is also driven
	# headless over ssh by the benchmark harness, where osascript has no window
	# server, so a dialog would sit unanswered for ever and hang the run.
	# Default to continuing: the game usually still works, it is just not running
	# the code we shipped, and that is a thing to be told rather than blocked for.
	#
	# The condition is nested rather than written as
	#   [ -n "\$OLDMAC_NO_PROMPT" ] || [ ! -t 0 ] && ! osascript ...
	# because shell has no precedence between || and &&: that parses as
	# ( A || B ) && C, so setting OLDMAC_NO_PROMPT still ran osascript and still
	# hung. Measured, by hanging.
	if [ -n "\${OLDMAC_NO_PROMPT:-}" ]; then
		:   # caller asked for no prompts, warning already logged and printed
	elif [ ! -t 0 ] && ! osascript -e 'return 1' >/dev/null 2>&1; then
		:   # no terminal and no window server, so nobody to ask
	else
		# Somebody is there: a terminal, or a window server for the dialog.
		# This block used to sit inside the nobody-to-ask branch above, so the
		# Quit / Run anyway choice could never appear anywhere.
		ANSWER="\$(osascript -e "display dialog \"\$MSG\" buttons {\"Quit\", \"Run anyway\"} default button 1 with icon caution with title \"Old Half-Life files are in the way\"" 2>/dev/null)"
		case "\$ANSWER" in
			*"Run anyway"*) ;;                      # they were told, they chose
			*Quit*)         exit 1 ;;               # they chose to stop
			*)              ;;                      # dialog failed; already warned
		esac
	fi
fi

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
# G5 970 = 100), which "machine" reports as "ppc750". NOTE: hw.optional.altivec is an
# Intel-only sysctl - it does NOT exist on PowerPC Mac OS X (errors on 10.4), so "no AltiVec"
# must be detected via the 750 subtype, not that sysctl. hw.cpusubtype exists on 10.3-10.5.
# Gate on uname -p = powerpc so no Intel subtype number can ever match the G3 branch.
OS="\$(sw_vers -productVersion)"
if [ "\$(uname -p)" = "powerpc" ] && { [ "\$(sysctl -n hw.cpusubtype 2>/dev/null)" = "9" ] || [ "\$(machine 2>/dev/null)" = "ppc750" ]; }; then
	# G3 (ppc750): low-res exclusive fullscreen, ANY OS. The perf-ppc engine adds
	# Rage 128 knobs, no-ops on every other machine because only this profile
	# passes them: -gldepth16 requests the card's native 16-bit Z and
	# -glnostencil drops the stencil buffer nothing shipped reads (together +5%,
	# invisible at Half-Life's scale), -bilinear selects single-mip filtering
	# where the Rage 128 pays double for trilinear (+14%, a subtle mip seam).
	# The 16-bit display mode (+23%) is NOT a launch flag any more: the engine's
	# vid_16bit cvar defaults on for a detected G3 and the player can turn it
	# off in the video menu; the archived choice then sticks, which a profile
	# flag re-applied every launch could never allow. -bpp 16 / -bpp 32 remain
	# as bench overrides. Measured 2026-08-18 on yosemite, c0a0: 44.6 fps in
	# 16-bit, 36.1 in 32-bit, 30.0 for v1.7.2.
	PROFILE="-ref gl -fullscreen -width 800 -height 600 -gldepth16 -glnostencil -bilinear +r_shadows 0 +gl_singlepass 1"
	MSAA_FORCE=0      # G3: OFF, and said rather than implied. Issue #8.
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
		PROFILE="-ref gl -borderless +gl_singlepass 1"  # G4/G5: native-res borderless
		# Shadows, MSAA and ripples were measured on this fleet's own cards:
		# ATI Radeon 9200/9600/9650 (issues #8, #9, #10). The branch above is
		# CPU family (ppc7400/7450/970), which is not the same class as "has a
		# Radeon": early G4s (Sawtooth/Yikes/Gigabit) shipped a Rage 128 (Pro),
		# the same generation as the G3's card that issue #8 measured to have
		# NO multisampling at all, and some G4/G5 configurations shipped an
		# nVidia card instead. None of those are this fleet's hardware, so
		# forcing the Radeon-measured defaults onto them assumes a GPU nobody
		# has run this port on. Issue #17.
		#
		# ioreg names the actual chip, and unlike system_profiler it works on
		# Panther too: SPDisplaysDataType is not in "system_profiler
		# -listDataTypes" on 10.3.9 at all, measured on yosemite, empty output
		# at exit 0. ATI's Radeon-generation chips are ATY,R<code> or
		# ATY,RV<code> (RV280 = Radeon 9200, RV351 = 9600/9650, both measured
		# on this fleet); the Rage 128 (Pro) is ATY,Rage128*, a different
		# prefix. An nVidia card or an unreadable ioreg has no ATY node at all.
		if ioreg -l 2>/dev/null | grep -qE 'ATY,R[V0-9][0-9A-Za-z]*'; then
			PROFILE="\$PROFILE +r_shadows 1"
			MSAA_DEFAULT=2   # measured, issue #8
			# G5 only, by CPU subtype: 100 is the 970, 10 and 11 are the 7400
			# and 7450. The G5 is the one machine measured to have headroom to
			# spend at its own refresh rate, so it is the only one that gets
			# water ripples. Issue #9.
			if [ "\$(sysctl -n hw.cpusubtype 2>/dev/null)" = "100" ]; then
				RIPPLE_DEFAULT=1
			fi
		else
			# Same position as Intel and arm64 below: nothing measured, so
			# nothing forced. Shadows get the explicit off (r_shadows carries
			# no flags and resets to the engine's own 0 every launch anyway,
			# but issue #8 already established "said rather than implied" for
			# this reason); MSAA and ripple are left unset rather than forced
			# off, because unlike the G3's own Rage 128 this card was never
			# actually measured to gain nothing from either.
			PROFILE="\$PROFILE +r_shadows 0"
		fi
		# A video.cfg carried over from a release older than issue #41 archives
		# exclusive fullscreen, and on the iMac G5 under Leopard that launch
		# dies in SDL_ShowWindow with "minimize failed (-4959)" (issue #57).
		# Isolated to this FILE on that machine: same build, same config.cfg
		# and opengl.cfg, old video.cfg crashes and a fresh one runs. Which of
		# the two keys is the trigger was not separated, so both are set to
		# what a fresh engine writes under -borderless. The G3 branch above
		# keeps exclusive fullscreen deliberately and is not touched. sed -i
		# does not exist on 10.3, hence the temp file.
		VCFG="\$XASH3D_BASEDIR/valve/video.cfg"
		if [ -f "\$VCFG" ] &&
		   { grep -q '^fullscreen "1"' "\$VCFG" 2>/dev/null || grep -q '^vid_maximized "1"' "\$VCFG" 2>/dev/null; }; then
			sed -e 's/^fullscreen "1"/fullscreen "2"/' -e 's/^vid_maximized "1"/vid_maximized "0"/' "\$VCFG" > "\$VCFG.hlfix" 2>/dev/null &&
				cat "\$VCFG.hlfix" > "\$VCFG" 2>/dev/null
			rm -f "\$VCFG.hlfix" 2>/dev/null
		fi
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
			sed -n 's/.*Resolution:.*[^0-9]\([0-9][0-9]*\)[[:space:]]*x[[:space:]]*\([0-9][0-9]*\).*/\1 \2/p' | head -1)"
		VW="\$(echo \$RES | awk '{print \$1}')"
		VH="\$(echo \$RES | awk '{print \$2}')"
		if [ -n "\$VW" ] && [ -n "\$VH" ]; then
			PROFILE="-ref gl -fullscreen -width \$VW -height \$VH +gl_singlepass 0"
		else
			PROFILE="-ref gl -fullscreen +gl_singlepass 0"
		fi
		# gl_singlepass OFF here, deliberately, and said rather than implied -
		# this whole branch is everything that is not PowerPC (arm64 included:
		# uname -p there is "arm", not "powerpc", so it lands here too). The
		# optimization exists for GPUs that ARE fillrate-bound (measured on
		# the G3's Rage 128, ~81% GPU-blocked); nothing in this branch ever
		# is, so there is nothing to trade for the risk. And the risk is
		# confirmed real, not theoretical: user-reported 2026-08-31, the
		# flashlight beam on imac-2019 (AMD Radeon Pro 580X) rendered as a
		# grid of grey squares instead of a light cone, with gl_singlepass 1.
		# Setting it to 0 live in-game fixed it completely; toggling
		# gl_overbright made no difference. The classic two-pass world render
		# (this cvar off) is the one path proven correct on every piece of
		# hardware in the fleet, PowerPC included - it is what single-pass
		# was built to improve on, not replace as the fallback. Issue #28.
		#
		# +gl_singlepass 0 above is not enough on its own: the cvar is
		# FCVAR_GLCONFIG, archived into opengl.cfg, and every machine that has
		# ever run a build before this fix (every machine in the fleet,
		# tonight, since the old fleet-wide pin forced "1") already holds a
		# "1" there. A command-line +cvar is not guaranteed to win a race
		# against that archived value depending on exactly where in the boot
		# sequence stuffcmds runs relative to the opengl.cfg exec - untested
		# and not worth trusting blind. Patching the file directly, the same
		# proven pattern as the video.cfg fix above, removes the question
		# entirely. sed -i does not exist on 10.3 either, hence the temp file,
		# even though this branch never runs there.
		OGLCFG_SP="\$XASH3D_BASEDIR/valve/opengl.cfg"
		if [ -f "\$OGLCFG_SP" ] && grep -q '^gl_singlepass "1"' "\$OGLCFG_SP" 2>/dev/null; then
			sed 's/^gl_singlepass "1"/gl_singlepass "0"/' "\$OGLCFG_SP" > "\$OGLCFG_SP.hlfix" 2>/dev/null &&
				cat "\$OGLCFG_SP.hlfix" > "\$OGLCFG_SP" 2>/dev/null
			rm -f "\$OGLCFG_SP.hlfix" 2>/dev/null
		fi
	fi
fi

# Multisampling, on a FRESH install only.
#
# gl_msaa_samples defaults to 0 in the engine and mainui has no control for it,
# so nothing has ever asked for MSAA on any machine here. Measured on hardware,
# fullscreen, map crossfire, 300 frames, median of 3 (issue #8):
#
#   mini G4    1024x768   121.2 fps off,  62.9 at 2x,  20.5 at 4x
#   Quicksilver 1024x768   75.4 fps off,  57.8 at 2x,  32.9 at 4x
#   dual G5    1680x1050   98.4 fps off,  71.4 at 2x,  44.2 at 4x
#   G3 800x600             58.7 off, 58.8 at 2x, 59.1 at 4x, and two screenshots
#                          at 0 and 4 are visually identical: the Rage 128 has no
#                          multisampling, so the request does nothing either way.
#
# So 2 on the G4 and G5, and 0 ENFORCED on the G3 rather than merely absent.
# Intel and arm64 are left alone deliberately: nothing has been measured on
# either, so silence there means "not decided", not "off". 4x is a 55 to 83% cut for a
# difference you have to look for, which is the wrong end of the trade even by
# the rule that effects beat frames above a machine's floor.
#
# WRITTEN ONLY IF THE KEY IS ABSENT. gl_msaa_samples is FCVAR_GLCONFIG, so the
# engine archives it into opengl.cfg on every exit; once a player has run the
# game once, the key exists and this never touches it again. That makes this a
# default for new installs and not a setting re-applied behind the player's back,
# which is the mistake the -bilinear note at gl_opengl.c warns about.
#
# opengl.cfg is exec'd by R_Init_Video_ (engine/client/dll_int/ref_common.c:305)
# BEFORE the GL context is created, so a value seeded here is live on this launch.
if [ -d "\$XASH3D_BASEDIR/valve" ]; then
	OGLCFG="\$XASH3D_BASEDIR/valve/opengl.cfg"
	if [ -n "\${MSAA_FORCE:-}" ]; then
		# ENFORCED, every launch. An omitted cvar is not a cvar set to 0: the
		# engine execs opengl.cfg before this and an archived value would stand,
		# so a G3 that ever archived 4 would keep asking for 4. It costs nothing
		# on the Rage 128 measured here, but a G3 with a card that CAN
		# multisample is the machine in this fleet least able to pay for it, and
		# that is the case a silent default gets wrong. Rewritten only when the
		# value is not already right, so a launch normally touches nothing.
		if ! grep -q "^gl_msaa_samples \"\$MSAA_FORCE\"" "\$OGLCFG" 2>/dev/null; then
			if [ -f "\$OGLCFG" ]; then
				grep -v '^gl_msaa_samples' "\$OGLCFG" > "\$OGLCFG.hlnew" 2>/dev/null &&
					printf 'gl_msaa_samples "%s"\n' "\$MSAA_FORCE" >> "\$OGLCFG.hlnew" 2>/dev/null &&
					cat "\$OGLCFG.hlnew" > "\$OGLCFG" 2>/dev/null
				rm -f "\$OGLCFG.hlnew" 2>/dev/null
			else
				printf 'gl_msaa_samples "%s"\n' "\$MSAA_FORCE" > "\$OGLCFG" 2>/dev/null
			fi
		fi
	elif [ -n "\${MSAA_DEFAULT:-}" ]; then
		# SEEDED, on a fresh install only, so a player's own choice stands.
		if ! grep -q '^gl_msaa_samples' "\$OGLCFG" 2>/dev/null; then
			printf 'gl_msaa_samples "%s"\n' "\$MSAA_DEFAULT" >> "\$OGLCFG" 2>/dev/null
		fi
	fi
fi

# Water ripples, on a FRESH install only, same mechanism and the same reason.
#
# r_ripple is FCVAR_GLCONFIG like gl_msaa_samples, so it is archived and only an
# install that has never run can be seeded. It is NOT set through the launch
# profile above, unlike r_shadows: a value on the command line would be re-applied
# every launch, and mainui gives the player a "Water ripples" checkbox
# (menus/VideoOptions.cpp:211) whose setting that would silently undo.
#
# Only the G5 asks for it, and only because it is the one machine measured to
# have headroom at its own refresh rate: 60.007 fps capped against 181.6
# uncapped. The G4 has none, 42.3 capped against 62.9, and the G3 less. The cost
# with water actually in view is unmeasured on this fleet, because the only map
# here carrying a water texture does not show it from the spawn point. Issue #9.
if [ -n "\${RIPPLE_DEFAULT:-}" ] && [ -d "\$XASH3D_BASEDIR/valve" ]; then
	RCFG="\$XASH3D_BASEDIR/valve/opengl.cfg"
	if ! grep -q '^r_ripple ' "\$RCFG" 2>/dev/null; then
		printf 'r_ripple "%s"\n' "\$RIPPLE_DEFAULT" >> "\$RCFG" 2>/dev/null
	fi
fi

# The menu's hint text is drawn in the CONSOLE font, which stops growing at 1280.
#
# mainui draws a menu item's description with EngFuncs::DrawConsoleString
# (controls/PicButton.cpp), so it uses the console font while the item beside it
# is scaled by uiStatic.scaleX. The engine has only THREE console fonts and picks
# by width (engine/client/console.c, Con_LoadConchars):
#
#     width <= 640   font 0
#     width >= 1280  font 2      <- the largest there is
#
# So past 1280 the buttons keep scaling and the descriptions do not. At 2880 wide
# they are drawn at their 1280 size beside buttons twice the size, which reads as
# a bug in the artwork rather than as a font that ran out of sizes.
#
# con_fontscale scales the font texture and fixes it. Derived from the width we
# are about to ask for rather than hardcoded, because the same fixed number that
# looks right on a 5K display would be enormous on the G3's 800x600.
#
# Only computed where the width is already known, which is the G3 profile (800,
# so this is a no-op) and every Intel and Apple Silicon machine. The PowerPC
# borderless path deliberately does not ask: it would mean a system_profiler call
# on every launch of a 20-year-old machine to correct a font on displays that are
# at most 1680 wide, where the error is small.
case "\$PROFILE" in
	*-width\ *)
		CONW=\$( echo "\$PROFILE" | sed -n 's/.*-width \([0-9][0-9]*\).*/\1/p' )
		if [ -n "\$CONW" ]; then
			# Clamped at 3: beyond that the bitmap font is so magnified that it is
			# worse than small. awk because 10.3 has no shell float arithmetic.
			FS=\$( echo "\$CONW" | awk '{ s = \$1 / 1280; if( s < 1 ) s = 1; if( s > 3 ) s = 3; printf "%.1f", s }' )
			case "\$FS" in
				1.0) ;;                                  # nothing to correct
				*) PROFILE="\$PROFILE +con_fontscale \$FS" ;;
			esac
		fi
		;;
esac

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
		# The G3 profile's Rage 128 knobs are flags with no value to override,
		# so a caller (bench.sh A/Bs above all) turns each off with a -no form.
		# The -no token itself passes through to the engine, which ignores
		# unknown parameters; only the profile flag is stripped.
		-nobpp)         PROFILE=\$( echo " \$PROFILE " | sed 's/ -bpp [0-9]*//g' ) ;;
		-nogldepth16)   PROFILE=\$( echo " \$PROFILE " | sed 's/ -gldepth16//g' ) ;;
		-noglnostencil) PROFILE=\$( echo " \$PROFILE " | sed 's/ -glnostencil//g' ) ;;
		-nobilinear)    PROFILE=\$( echo " \$PROFILE " | sed 's/ -bilinear//g' ) ;;
	esac
done

echo "launcher: xash3d.bin -console \$PROFILE $EXTRA_ARGS \$@" > "\$LOG"
[ -n "\${SHADOW_NOTE:-}" ] && echo "\$SHADOW_NOTE" >> "\$LOG"
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

# Carry the fused bundle's provenance into the .app. make-universal.sh wrote this
# after checking all three slices agreed with build-pins.sh, so it is a record of
# what was actually built, not a restatement of what was asked for. make-dmg.sh
# checks it against the pin, which is the last point before a disk image exists.
if [ -f "$SRC/BUILD-STAMP" ]; then
	cp "$SRC/BUILD-STAMP" "$APP/Contents/Resources/BUILD-STAMP"
fi

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
	<key>NSMicrophoneUsageDescription</key><string>Half-Life uses the microphone for in-game voice chat.</string>
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
