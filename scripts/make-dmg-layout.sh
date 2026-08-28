#!/usr/bin/env bash
# Produce the .DS_Store that gives the release image a laid-out Finder window,
# and print its path. Issue #23.
#
# WHY THIS IS A SEPARATE STEP, AND WHY IT RUNS HERE
#
# The release image must be built on a Tiger G4 with -format UDZO, which is a
# hard rule: that is what makes it mount on Panther and everything newer
# (docs/adr/0005, and the hard rules). Tiger has no create-dmg and no package
# manager to install one, and modern create-dmg wants a bash and an osascript
# newer than 10.4 ships. Checked 2026-08-29 on mini-g4 and quicksilver: absent
# on both.
#
# That does not matter, because a window layout is not an operation performed at
# image-creation time. Icon positions, window bounds, icon size and view style
# all live in the volume's .DS_Store, which is DATA sitting in the folder.
# make-dmg.sh already stages the payload here and rsyncs a finished folder to
# the Tiger host, where `hdiutil create -srcfolder` packages whatever it finds,
# a .DS_Store included. So the layout is built on a modern Mac and the image is
# still built on the Tiger G4. Neither rule bends.
#
# The layout is built against PLACEHOLDERS, not the real payload. Finder keys
# icon positions by NAME, so an empty directory called "Half-Life.app" produces
# the same .DS_Store entry as the real 53 MB bundle. That turns a 300 MB copy
# into a few kilobytes.
#
# WHAT THE LAYOUT SAYS, AND WHY IT IS NOT "DRAG TO APPLICATIONS"
#
# Every other port's image can offer the usual Applications-folder alias. Ours
# must not. This image carries THREE bundles that have to stay together, and the
# player's own valve/ has to sit BESIDE them, not inside anything. Dropping the
# apps into /Applications individually is the one arrangement that breaks the
# mod installer, because it separates them and puts them somewhere nobody will
# think to put valve/. So the layout groups the three apps and puts README.txt
# where it is read, and the guidance stays "copy these out into one folder",
# matching what the Mods app's own read-only alert already tells people.
#
# usage: scripts/make-dmg-layout.sh <volume-name> <out-path-for-DS_Store>
set -euo pipefail

VOLNAME="${1:?usage: $0 <volume-name> <out-DS_Store-path>}"
OUT="${2:?usage: $0 <volume-name> <out-DS_Store-path>}"

case "$( uname -s )" in
	Darwin ) ;;
	* ) echo "$0: needs macOS (Finder), got $( uname -s )" >&2; exit 2 ;;
esac

WORK="$( mktemp -d -t hl-dsstore )"
SRC="$WORK/src"
IMG="$WORK/layout.dmg"
# MUST mount under /Volumes, NOT at a private mountpoint. Finder addresses a
# volume by its /Volumes name, so `tell disk "<volname>"` against an image
# mounted anywhere else fails with -1728, "Can't get disk". Measured
# 2026-08-29: a -mountpoint under /tmp produced that error every time and no
# .DS_Store; the same script mounting normally wrote one immediately. That also
# rules out -nobrowse, which hides it from Finder for the same reason.
MNT="/Volumes/$VOLNAME"
cleanup() {
	hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# Placeholders, named exactly as the real items. Bundles must be DIRECTORIES so
# Finder treats them as one icon rather than a file.
mkdir -p "$SRC/Half-Life.app" "$SRC/Half-Life Mods.app" "$SRC/Half-Life System Report.app"
: > "$SRC/README.txt"
: > "$SRC/BUILD-INFO.txt"

# A read-write image, because Finder cannot write a .DS_Store onto a read-only
# one. Tiny: the placeholders are empty.
rm -f "$IMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$SRC" -ov \
	-format UDRW -size 16m "$IMG" >/dev/null

# Refuse rather than clobber: a volume of this name already mounted is either
# someone else's or a leftover, and detaching it blind is not ours to do.
if [ -e "$MNT" ]; then
	echo "$0: /Volumes/$VOLNAME already exists; eject it and retry" >&2
	exit 4
fi
hdiutil attach "$IMG" >/dev/null

# Positions are in the window's coordinate space.
OSAERR="$( osascript 2>&1 >/dev/null <<OSA

tell application "Finder"
	tell disk "$VOLNAME"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 140, 940, 620}
		set theView to the icon view options of container window
		set arrangement of theView to not arranged
		set icon size of theView to 96
		set text size of theView to 12
		set position of item "Half-Life.app" of container window to {150, 140}
		set position of item "Half-Life Mods.app" of container window to {370, 140}
		set position of item "Half-Life System Report.app" of container window to {590, 140}
		set position of item "README.txt" of container window to {260, 330}
		set position of item "BUILD-INFO.txt" of container window to {480, 330}
		close
		open
		update without registering applications
		delay 2
		close
	end tell
end tell
OSA
)" || true
[ -n "$OSAERR" ] && echo "$0: WARNING: Finder layout reported: $OSAERR" >&2

# Finder writes .DS_Store lazily; give it a moment.
sleep 3
sync

if [ ! -f "$MNT/.DS_Store" ]; then
	echo "$0: no .DS_Store was written; Finder may not be running, or this is a" >&2
	echo "  headless session. The image is still valid, just unstyled." >&2
	exit 3
fi

mkdir -p "$( dirname "$OUT" )"
cp "$MNT/.DS_Store" "$OUT"
echo "$0: layout written, $( stat -f%z "$OUT" ) bytes -> $OUT"
