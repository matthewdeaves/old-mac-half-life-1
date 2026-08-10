#!/bin/bash
# test-artifact.sh - invariants that can only be checked against a built image.
#
#     tests/test-artifact.sh dist/Half-Life-OldMac-v1.4.1.dmg
#     tests/test-artifact.sh                    # newest dmg in dist/
#
# Needs a Mac, because it reads Mach-O headers with lipo and otool and mounts a
# UDZO image. Everything that does NOT need those lives in test-repo.py, which
# runs anywhere.
#
# Each check corresponds to something that shipped wrong, or that would break a
# specific machine in a way nobody would connect back to the build:
#
#   * a generic `ppc (ALL)` executable slice makes Tiger and Leopard mis-grade
#     the fat and refuse to exec on a 750 host;
#   * an Intel slice whose LC_VERSION_MIN drifts promises a machine something the
#     binary cannot deliver. This check once read "must be 10.7", because libc++
#     arrived in 10.7; the Intel slices now link libstdc++ and the floor is 10.6,
#     so the check asserts 10.6 and would catch a drift in either direction;
#   * the game payload above the `valve/` level is invisible to
#     Host_CheckGameLibraries and the engine aborts with "missing game library";
#   * BUILD-INFO.txt naming a slice the binary does not carry is what v1.4.0
#     shipped.
#
# Exit status is the number of failed checks.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="${1:-}"
if [ -z "$DMG" ]; then
	DMG="$(ls -t "$REPO"/dist/Half-Life-OldMac-*.dmg 2>/dev/null | head -1)"
fi
[ -n "$DMG" ] && [ -f "$DMG" ] || { echo "no disk image given and none found in dist/" >&2; exit 1; }

MNT="/tmp/hl-artifact-test.$$"
FAILED=0
PASSED=0

ok()   { PASSED=$((PASSED + 1)); [ "${VERBOSE:-}" = 1 ] && echo "  ok    $1"; return 0; }
bad()  { FAILED=$((FAILED + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "          $2"; return 0; }
is()   { # is <name> <expected> <actual>
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}
# lipo does not promise an order, so compare arch SETS rather than strings.
archs() { lipo -archs "$1" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ *$//'; }
setis() { # setis <name> <expected-space-separated> <file>
	want="$(printf '%s\n' $2 | sort | tr '\n' ' ' | sed 's/ *$//')"
	is "$1" "$want" "$(archs "$3")"
}

cleanup() { hdiutil detach "$MNT" >/dev/null 2>&1; rmdir "$MNT" 2>/dev/null; }
trap cleanup EXIT

echo "artifact invariants: $(basename "$DMG")"
mkdir -p "$MNT"
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$DMG" >/dev/null 2>&1 \
	|| { echo "  FAIL  image will not mount" >&2; exit 1; }

APP="$MNT/Half-Life.app"
MODS="$MNT/Half-Life Mods.app"
SR="$MNT/Half-Life System Report.app"

# ---- what is on the image -------------------------------------------------
for f in "$APP" "$MODS" "$SR" "$MNT/README.txt" "$MNT/BUILD-INFO.txt"; do
	[ -e "$f" ] && ok "present: $(basename "$f")" || bad "missing: $(basename "$f")"
done
# We ship no game content, ever. A valve folder here would mean Valve's data
# leaked into the image.
[ -e "$MNT/valve" ] && bad "a valve folder is on the image" "we ship code, not content" \
                    || ok "no valve folder on the image"

# ---- executable slices ----------------------------------------------------
BIN="$APP/Contents/MacOS/xash3d.bin"
# FIVE slices. i386 for the 2006 Core Solo and Core Duo, arm64 for Apple Silicon.
# Spelled out rather than derived, because this is the check that says the release
# supports what it claims to support, and deriving it from the file under test
# would make it agree with whatever shipped.
setis "engine executable is ppc750 ppc7400 i386 x86_64 arm64" "ppc750 ppc7400 i386 x86_64 arm64" "$BIN"

# The exact-subtype rule. A generic ppc slice in the EXECUTABLE is the failure
# mode that bricks a G3 on Tiger, so assert the absence explicitly rather than
# relying on the archs list alone.
# NOT a grep for a two-line pattern. It used to be, and it could never match:
# $(printf '\n') strips its own trailing newline and collapses to the empty
# string, and grep is line-oriented anyway, so the check reported "ok" on every
# image ever tested, including ones that genuinely carry CPU_SUBTYPE_POWERPC_ALL.
# lipo prints one "architecture <name>" line per slice, and the name for a generic
# ppc slice is exactly "ppc", so ask for that.
if lipo -detailed_info "$BIN" 2>/dev/null | awk '/^architecture ppc$/ { found = 1 } END { exit !found }'; then
	bad "executable carries a generic ppc (ALL) slice"
else
	ok "executable carries no generic ppc (ALL) slice"
fi

# ---- dylib slices ---------------------------------------------------------
# Generic ppc here is deliberate: dlopen grades dylibs fine on a 750 host.
for d in libxash libref_gl libref_soft libmenu filesystem_stdio; do
	f="$APP/Contents/MacOS/$d.dylib"
	[ -f "$f" ] || { bad "missing dylib: $d"; continue; }
	setis "$d.dylib is ppc ppc7400 i386 x86_64 arm64" "ppc ppc7400 i386 x86_64 arm64" "$f"
done

# ---- OS floors ------------------------------------------------------------
# Only the x86_64 slice states one. Both PowerPC slices deliberately carry no
# LC_VERSION_MIN, which is why a PowerPC OS floor has to be established by
# comparing undefined symbols instead. See docs/adr/0001.
MINV="$(otool -arch x86_64 -l "$BIN" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/version/{print $2; exit}')"
# 10.6, not 10.7. The floor came down when the Intel slices moved to libstdc++:
# libstdc++.6.dylib has no file on disk on macOS 26 but still dlopens from the dyld
# shared cache, so one slice covers 10.6.8 through macOS 26. See docs/adr/0010.
is "x86_64 slice targets 10.6" "10.6" "$MINV"
MINI="$(otool -arch i386 -l "$BIN" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/version/{print $2; exit}')"
is "i386 slice targets 10.6" "10.6" "$MINI"
for a in ppc750 ppc7400; do
	if otool -arch "$a" -l "$BIN" 2>/dev/null | grep -q LC_VERSION_MIN_MACOSX; then
		bad "$a slice has an LC_VERSION_MIN" "PowerPC slices should carry none"
	else
		ok "$a slice has no LC_VERSION_MIN"
	fi
done

# ---- the System Report app reaches further than the game ------------------
# It exists for the machine nobody in the fleet has, so it must run where the
# game cannot: 64-bit Intel below the game's own floor. See issue #24.
#
# The game's Intel floor has since come DOWN, from 10.7 to 10.6, which narrows
# the gap this app exists to cover rather than removing it: 10.5 is still below
# 10.6. The threshold below is spelled as the game's floor so that lowering the
# game again fails here with the reason, rather than silently leaving the report
# app with nothing to add.
GAME_INTEL_FLOOR=1006
SRBIN="$SR/Contents/MacOS/HalfLifeSystemReport"
if [ -f "$SRBIN" ]; then
	setis "report app is ppc i386 x86_64 arm64" "i386 ppc x86_64 arm64" "$SRBIN"
	for pair in i386:10.4 x86_64:10.5; do
		a="${pair%%:*}"; want="${pair##*:}"
		got="$(otool -arch "$a" -l "$SRBIN" 2>/dev/null \
			| awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/version/{print $2; exit}')"
		is "report app $a slice targets $want" "$want" "$got"
		# Compare against the game's Intel floor as a number, so that raising
		# this app's floor fails here with the reason rather than only as a
		# mismatched literal above. 10.4 -> 1004, 10.6 -> 1006.
		n=$( echo "$got" | awk -F. '{ printf "%d", ($1 * 100) + $2 }' )
		if [ -n "$got" ] && [ "$n" -ge 1000 ] && [ "$n" -lt "$GAME_INTEL_FLOOR" ] 2>/dev/null; then
			ok "report app $a floor is below the game's"
		else
			bad "report app $a floor is '$got'" \
			    "not below the game's, so it adds nothing on the machines it exists for"
		fi
	done
	# The PowerPC slice must carry no floor, same as the game's.
	if otool -arch ppc -l "$SRBIN" 2>/dev/null | grep -q LC_VERSION_MIN_MACOSX; then
		bad "report app ppc slice has an LC_VERSION_MIN" "PowerPC slices should carry none"
	else
		ok "report app ppc slice has no LC_VERSION_MIN"
	fi
else
	bad "missing report app binary"
fi

# ---- bundle shape ---------------------------------------------------------
# The payload must sit at the valve/ level. At the rodir root it is
# FS_STATIC_PATH, which Host_CheckGameLibraries cannot see.
VALVE="$APP/Contents/Resources/Half-Life/valve"
[ -d "$VALVE" ] && ok "payload is at the valve/ level" \
                || bad "payload is not at Contents/Resources/Half-Life/valve"
# The unsuffixed pair is i386: COM_GenerateLibraryName special-cases 32-bit x86
# on Apple and gives it no suffix, because that was Half-Life's original
# platform. The engine dlopens all of these BY NAME.
for f in dlls/hl_ppc.dylib dlls/hl_amd64.dylib dlls/hl.dylib \
         cl_dlls/client_ppc.dylib cl_dlls/client_amd64.dylib cl_dlls/client.dylib; do
	[ -f "$VALVE/$f" ] && ok "payload has $f" || bad "payload missing $f"
done
# An arm64 engine with no arm64 game code aborts with "missing game library" on
# exactly the machines the slice was added for.
case "$(archs "$BIN")" in *arm64*)
	for f in dlls/hl_arm64.dylib cl_dlls/client_arm64.dylib; do
		[ -f "$VALVE/$f" ] && ok "payload has $f" || bad "payload missing $f (engine has arm64)"
	done
	# arm64 states its floor via LC_BUILD_VERSION, not LC_VERSION_MIN_MACOSX.
	MINA="$(otool -arch arm64 -l "$BIN" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
	is "arm64 slice targets 11.0" "11.0" "$MINA"
;; esac
# Without this dictionary mainui draws its GameUI_* tokens as their own names,
# because L() returns the key on a miss and retail data supplies no
# resource/*_english.txt at all. See issue #20.
DICT="$VALVE/resource/gameui_english.txt"
if [ -f "$DICT" ]; then
	ok "payload has resource/gameui_english.txt"
	grep -q '"GameUI_PrecachingResources"' "$DICT" \
		&& ok "dictionary defines the map-loading strings" \
		|| bad "dictionary is missing GameUI_PrecachingResources"
else
	bad "payload missing resource/gameui_english.txt" "GameUI_* tokens will render as raw names"
fi
# A gameinfo.txt or liblist.gam at the rodir ROOT would register a phantom
# Custom Game entry in the menu.
for f in gameinfo.txt liblist.gam; do
	[ -e "$APP/Contents/Resources/Half-Life/$f" ] \
		&& bad "rodir root has $f" "this creates a phantom Custom Game entry" \
		|| ok "rodir root has no $f"
done

# ---- BUILD-INFO agrees with the binary ------------------------------------
DECLARED="$(sed -n 's/^Fat slices *: *//p' "$MNT/BUILD-INFO.txt" | sed 's/ *\. */ /g; s/ *$//')"
is "BUILD-INFO slice line matches lipo" "$(archs "$BIN")" "$(printf '%s\n' $DECLARED | sort | tr '\n' ' ' | sed 's/ *$//')"
if grep -q '+dirty' "$MNT/BUILD-INFO.txt"; then
	bad "BUILD-INFO records a dirty tree" "a release must be reproducible from a commit"
else
	ok "BUILD-INFO records a clean tree"
fi

# ---- the mod installer ----------------------------------------------------
# The report app is checked further up, where its slices and its deliberately
# lower floors are asserted together. This one needs the GAME's floors, not
# lower ones, because a machine that cannot run the game has nothing to install
# mods for. That is a statement about the FLOORS and it stayed true; what did
# not was the conclusion once drawn from it, that two slices were therefore
# enough.
#
# They were not. The game grew an i386 slice for the 2006 Core Solo and Core Duo
# Macs and the mod dylibs followed, so on one of those machines the game ran,
# every mod ran, and the app that installs them would not launch. The check that
# should have caught it asserted the shape it already had.
MODSBIN="$MODS/Contents/MacOS/HalfLifeMods"
if [ -f "$MODSBIN" ]; then
	setis "Mods app is ppc i386 x86_64 arm64" "ppc i386 x86_64 arm64" "$MODSBIN"
else
	bad "missing binary: Mods"
fi

# ---- mods ship complete ---------------------------------------------------
MODDIR="$MODS/Contents/Resources/mods"
if [ -d "$MODDIR" ]; then
	EXPECT="$(grep -vc '^[[:space:]]*\(#\|$\)' "$REPO/installer/mods.map")"
	# mods.map is keyed by gamedir but built per branch, so count the branches.
	BRANCHES="$(awk '!/^[[:space:]]*(#|$)/{print $2}' "$REPO/installer/mods.map" | sort -u | wc -l | tr -d ' ')"
	is "mods/ holds one directory per branch" "$BRANCHES" "$(ls "$MODDIR" | wc -l | tr -d ' ')"
	# Four slices, and no ppc750/ppc7400 split: these are dlopened rather than
	# exec'd, and dlopen grades a generic `ppc (ALL)` slice correctly on a 750.
	# Only the engine EXECUTABLE needs exact cpusubtypes.
	WANT_MOD="$(printf '%s\n' arm64 i386 ppc x86_64 | sort | tr '\n' ' ' | sed 's/ *$//')"
	THIN=""
	for m in "$MODDIR"/*/*.dylib; do
		[ -f "$m" ] || continue
		[ "$(archs "$m")" = "$WANT_MOD" ] || THIN="$THIN $(basename "$(dirname "$m")")/$(basename "$m")($(archs "$m"))"
	done
	[ -z "$THIN" ] && ok "every mod dylib is fat ppc i386 x86_64 arm64" \
	                || bad "mod dylibs have the wrong slices:" "$THIN"
	# Artwork and blurbs are what make a mod look installed rather than broken.
	for sub in artwork descriptions; do
		n="$(ls "$MODS/Contents/Resources/$sub" 2>/dev/null | wc -l | tr -d ' ')"
		is "$sub/ covers every mod" "$EXPECT" "$n"
	done
else
	echo "  note  no mods app payload on this image, skipping mod checks"
fi

# ---- README.txt does not contradict the binary -----------------------------
# The v1.4.x README shipped saying Intel needs 10.7, 32-bit Intel is not
# covered, and there is no native Apple Silicon slice, after all three had
# stopped being true. The heredoc in make-dmg.sh is hand-maintained prose, so
# the retracted claims are pinned here the way test-repo.py pins them for the
# apps' shipped strings.
if [ -f "$MNT/README.txt" ]; then
	RETRACTED='no native Apple Silicon|not 10\.6|10\.7 Lion or newer|would need an i386 slice'
	HIT="$(grep -nE "$RETRACTED" "$MNT/README.txt" || true)"
	[ -z "$HIT" ] && ok "README.txt repeats no retracted support claim" \
	              || bad "README.txt repeats a retracted support claim:" "$HIT"
else
	bad "image has no README.txt"
fi

# ---- version labels agree ---------------------------------------------------
# make-dmg.sh prefixes "v" itself, so passing it "v1.4.1" once produced
# Half-Life-OldMac-vv1.4.1.dmg with "vv1.4.1" baked into README.txt.
FILEVER="$(basename "$DMG" .dmg | sed 's/^Half-Life-OldMac-v//')"
INFOVER="$(sed -n '1s/^Half-Life-OldMac  *//p' "$MNT/BUILD-INFO.txt")"
is "disk image name matches BUILD-INFO version" "$INFOVER" "$FILEVER"
case "$FILEVER" in
	v*) bad "version label has a doubled v prefix" "filename says $FILEVER" ;;
	*)  ok "version label has no doubled v prefix" ;;
esac

# ---- versions are consistent ----------------------------------------------
PB=/usr/libexec/PlistBuddy
REF=""
for b in "$APP" "$MODS" "$SR"; do
	[ -d "$b" ] || continue
	v="$($PB -c "Print :CFBundleShortVersionString" "$b/Contents/Info.plist" 2>/dev/null)"
	[ -z "$REF" ] && REF="$v"
	is "$(basename "$b") version is $REF" "$REF" "$v"
done

echo
echo "$PASSED passed, $FAILED failed"
exit "$FAILED"
