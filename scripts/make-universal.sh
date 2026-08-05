#!/bin/bash
# Fuse the per-OS slices into ONE universal flat bundle, then (optionally) wrap it
# as Half-Life.app via make-app.sh. RUN ON THE LION MINI after the three builds:
#   build-ppc-panther.sh  -> dist/ppc-panther-app  (generic ppc,  10.3, SDL static)
#   build-ppc-tiger.sh    -> dist/ppc-tiger-app    (ppc7400,      10.4, SDL static)
#   build-lion.sh         -> dist/lion-x86_64      (x86_64,       10.7, SDL dylib)
#
# EVERY path here is under dist/. Nothing this script reads or writes is ever the
# deployed game folder on somebody's Desktop, which holds only the app bundles and
# the player's own valve/.
#
# WHY THREE SLICES:
#   exec()/dyld pick the best-graded slice for the host CPU, ignoring the OS:
#     G3 (750, no AltiVec) -> ppc        G4 (7400/7450) -> ppc7400
#     G5 (970)             -> ppc7400    Intel          -> x86_64
#   - generic `ppc` (Panther, min-10.3, panther-sdl2): mandatory for the G3. The
#     ppc7400 slice carries 725 AltiVec instructions and the 750 has no AltiVec
#     unit, so it would trap.
#   - ppc7400 (Tiger, min-10.3 in practice, panther-sdl2): the G4s AND the G5.
#   - x86_64 (Lion, min-10.7).
#
# WHY THE G5 NO LONGER HAS ITS OWN ppc970 SLICE (dropped 2026-07-27):
#   Measured 6% slower on the G5 than the G4's slice, and the crash it existed
#   for was never established. Dropping it also lets a G5 on 10.3 or 10.4 work by
#   ordinary dyld grading, which is why make-app.sh no longer ships a ppc-compat
#   fallback. Full evidence and measurements:
#   docs/adr/0001-slices-are-chosen-by-cpu-capability.md.
#
# SDL: both ppc slices link SDL statically (libxash has no SDL load command), so
#   the universal libSDL2 dylib is x86_64-only; the ppc slices never touch it.
#
# GAME DYLIBS: the engine dlopen's dlls/hl_<arch>.dylib + cl_dlls/client_<arch>.dylib
#   by arch NAME (ppc / amd64), so we ship both sets side by side. The generic-`ppc`
#   game dylibs load fine under the ppc7400 engine on G4/G5 (same arch family), so one
#   generic-ppc pair covers all three PPC machines.
#
# NO valve FOLDER IS SHIPPED. Everything we build goes in "gamedata/", which
#   make-app.sh installs as Contents/Resources/Half-Life/valve inside the .app,
#   under the engine's read-only root (fs_rodir). The player drops their OWN
#   untouched retail valve folder next to Half-Life.app and there is nothing to
#   merge. See make-app.sh for why the payload sits at the valve level rather than
#   at the rodir root, and why that does not create a phantom Custom Game entry.
set -euo pipefail

# Lion's stock /usr/bin/{lipo,install_name_tool} are stale stubs that choke on modern
# x86_64 load commands (LC_SEGMENT_64 etc.) - use the Xcode toolchain's cctools, same
# as build-lion.sh.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$DEVELOPER_DIR/usr/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PANTHER="$ROOT/dist/ppc-panther-app"          # generic ppc  (G3, 10.3, panther-sdl2)
TIGER="$ROOT/dist/ppc-tiger-app"              # ppc7400       (G4, 10.4, panther-sdl2)
LION="$ROOT/dist/lion-x86_64"                 # x86_64        (Intel, 10.7)

# --- refuse to fuse slices that were not all built from the same source -------
#
# On 31 July 2026 both PowerPC slices shipped code that was not in the source
# tree. waf reused an object across a commit change, the link ran, the output
# carried a fresh timestamp, and the fused binary went out to three machines
# before anybody noticed. Every check in build-verification.md passed, because
# they all look at mtimes and architectures, and both of those were correct.
#
# So each driver now records the engine commit it built from, and this refuses to
# fuse unless all three agree with each other and with build-pins.sh. A slice left
# behind by an earlier run, or a driver that was never re-run, stops the release
# here instead of reaching a bench machine.
. "$ROOT/scripts/build-pins.sh"

stamp_of() {
	if [ ! -f "$1/BUILD-STAMP" ]; then
		echo "!! $1 has no BUILD-STAMP: re-run its build driver" >&2
		exit 1
	fi
	cat "$1/BUILD-STAMP"
}

echo "==> checking all three slices were built from the same commit"
for d in "$PANTHER" "$TIGER" "$LION"; do
	got="$( stamp_of "$d" )"
	if [ "$got" != "$PIN_ENGINE_COMMIT" ]; then
		echo "!! $d was built from $got" >&2
		echo "   build-pins.sh says   $PIN_ENGINE_COMMIT" >&2
		echo "   re-run that slice's build driver before fusing." >&2
		exit 1
	fi
done
echo "    ok  all three at $( short "$PIN_ENGINE_COMMIT" )"
# Carry the agreed stamp forward. Up to now it lived only in the per-slice
# staging dirs, so once the fat bundle was assembled there was nothing left in
# the artifact itself saying what it came from, and make-dmg.sh had to take the
# build on trust. The value written is the one just READ BACK from the slices and
# checked against build-pins.sh, not the pin copied straight out of the file.
FUSED_STAMP="$( stamp_of "$LION" )"
SDLX86="$ROOT/sdl2-x86_64/lib/libSDL2-2.0.0.dylib"
OUT="$ROOT/dist/universal"                    # flat fat bundle (feed to make-app.sh)

ENGINE_DYLIBS="libxash.dylib libref_gl.dylib libref_soft.dylib libmenu.dylib filesystem_stdio.dylib"

# The two PPC staging dirs moved from the repo root (dist-ppc-*-app) into dist/.
# A build host synced mid-release can still be holding the old ones, and stopping a
# release to rename a directory helps nobody, so accept the legacy path and say so.
for v in PANTHER TIGER; do
	eval "cur=\$$v"
	[ -d "$cur" ] && continue
	legacy="$ROOT/dist-ppc-$(echo "$v" | tr 'A-Z' 'a-z')-app"
	if [ -d "$legacy" ]; then
		echo "NOTE: using legacy staging dir $legacy (the new path is $cur)"
		eval "$v=\$legacy"
	fi
done

for d in "$PANTHER" "$TIGER" "$LION"; do
	[ -d "$d" ] || { echo "MISSING slice dir: $d - run the matching build first" >&2; exit 1; }
done

rm -rf "$OUT"; mkdir -p "$OUT/gamedata/cl_dlls" "$OUT/gamedata/dlls"

echo "==> lipo engine executable (ppc + ppc7400 + x86_64)"
lipo -create "$PANTHER/xash3d" "$TIGER/xash3d" "$LION/xash3d" -output "$OUT/xash3d"

echo "==> lipo engine dylibs"
for d in $ENGINE_DYLIBS; do
	lipo -create "$PANTHER/$d" "$TIGER/$d" "$LION/$d" -output "$OUT/$d"
done

echo "==> SDL2 (x86_64-only; ppc is static)"
cp "$SDLX86" "$OUT/libSDL2-2.0.0.dylib"
chmod u+w "$OUT/libSDL2-2.0.0.dylib" "$OUT/libxash.dylib"
# Make the x86_64 slice self-contained: reference SDL next to the binary, not by the
# build-box absolute path. install_name_tool touches only the x86_64 slice (the ppc
# slices have no SDL load command, so they are left untouched).
install_name_tool -id @loader_path/libSDL2-2.0.0.dylib "$OUT/libSDL2-2.0.0.dylib"
# NOT optional, and NOT silenced. build-lion.sh rewrites the SDL install name only
# on the copy it stages into dist/lion-play; the libxash.dylib fused here still
# carries the build box's absolute path to libSDL2. If this fails, the shipped
# x86_64 slice references a path that exists on no user machine, and nothing
# downstream looks: make-dmg.sh md5s the file but never reads its load commands.
install_name_tool -change "$SDLX86" @loader_path/libSDL2-2.0.0.dylib "$OUT/libxash.dylib"
if otool -L "$OUT/libxash.dylib" | grep -q "$SDLX86"; then
	echo "!! libxash.dylib still references the build path $SDLX86" >&2
	echo "   The Intel slice would fail to load SDL on any other machine." >&2
	exit 1
fi

echo "==> game dylibs (both arch sets; generic-ppc pair serves G3/G4/G5)"
cp "$PANTHER/valve/cl_dlls/client_ppc.dylib" "$OUT/gamedata/cl_dlls/"
cp "$PANTHER/valve/dlls/hl_ppc.dylib"        "$OUT/gamedata/dlls/"
cp "$LION/valve/cl_dlls/client_amd64.dylib"  "$OUT/gamedata/cl_dlls/"
cp "$LION/valve/dlls/hl_amd64.dylib"         "$OUT/gamedata/dlls/"

echo "==> sticky fleet config (blocky-texture fix + single-pass)"
cp "$ROOT/configs/userconfig.cfg" "$OUT/gamedata/userconfig.cfg"

# Menu dictionary for the GameUI_* tokens. mainui's L() returns the key itself on
# a miss, so without this every coded token was DRAWN as its own name: checkbox
# and slider labels throughout Options, the column headings in Controls, Load Game
# and Custom Game, and "GameUI_PrecachingResources" on every level change. Retail
# data ships no resource/*_english.txt and mainui does not bundle one, so nothing
# supplied these. See configs/gameui_english.txt and GitHub issue #20.
mkdir -p "$OUT/gamedata/resource"
cp "$ROOT/configs/gameui_english.txt" "$OUT/gamedata/resource/gameui_english.txt"

# Custom Game menu artwork for all 25 mods, shipped INSIDE the app rather than
# copied into the player's game data at install time. While the engine is running
# `valve` a mod's own folder is not on the search path, so the menu cannot read
# bshift/game.tga; gfx/shell is where the menu's own art lives and the rodir is on
# the search path for every gamedir, so these resolve from here. Present whether or
# not the mod installer ever ran, and for mods installed by hand.
# (See scripts/gen-mod-artwork.py and scripts/patch-mainui-modart.py.)
if [ -d "$ROOT/installer/artwork" ]; then
	mkdir -p "$OUT/gamedata/gfx/shell/mods"
	cp "$ROOT/installer/artwork"/*.tga      "$OUT/gamedata/gfx/shell/mods/" 2>/dev/null || true
	cp "$ROOT/installer/descriptions"/*.txt "$OUT/gamedata/gfx/shell/mods/" 2>/dev/null || true
	echo "    mod artwork: $(ls "$OUT/gamedata/gfx/shell/mods" | wc -l | tr -d ' ') files"
fi

# Record what this fat bundle was fused from, beside the binaries, so the
# artifact carries its own provenance rather than relying on staging dirs that
# the next build overwrites.
printf '%s\n' "$FUSED_STAMP" > "$OUT/BUILD-STAMP"

echo
echo "== universal flat bundle ready: $OUT =="
echo -n "   xash3d          : "; lipo -info "$OUT/xash3d" | sed 's/.*: //'
for d in $ENGINE_DYLIBS; do
	printf '   %-16s: ' "${d%.dylib}"; lipo -info "$OUT/$d" | sed 's/.*are: //;s/.*is architecture: //'
done
echo
# Wrap it into dist/universal-app/, which is where make-dmg.sh looks for it (SRC_APP).
# NOT onto the Desktop: on a build mini the Desktop also holds ~/Desktop/Half-Life,
# the deployed game with the player's valve/ beside it, and build output has no
# business landing next to it.
echo "Next: ./scripts/make-app.sh '$OUT' '$ROOT/dist/universal-app/Half-Life.app' [icon.icns]"
