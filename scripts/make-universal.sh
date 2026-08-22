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
LION="$ROOT/dist/lion-x86_64"                 # x86_64        (Intel, 10.6)
LION32="$ROOT/dist/lion-i386"                 # i386          (Core Solo/Duo, 10.6)
ARM64="$ROOT/dist/arm64"                      # arm64         (Apple Silicon, 11.0)

# The i386 slice is OPTIONAL. It exists only for the 2006 Core Solo and Core Duo
# machines, which have no 64-bit mode, and it is built by a separate run of
# build-lion.sh with OLDMAC_INTEL_ARCH=i386. Fuse it when it is there and say so
# when it is not, rather than either requiring it or silently dropping it: a
# release that quietly lost a slice looks exactly like one that never had it.
DYN_ARCHES=( x86_64 )
DYN_DIRS=( "$LION" )
# The game dylib FILE NAMES, not arch tokens. COM_GenerateLibraryName
# (3rdparty/library_suffix) special-cases 32-bit x86 on Apple, Windows and
# Linux and gives it NO suffix, because that was Half-Life's original
# platform: i386 is hl.dylib and client.dylib, while ppc, amd64 and arm64 all
# take the _<arch> form. The engine dlopen's these by name, so a suffixed
# i386 pair would simply never be found.
DYN_GAMECL=( client_amd64.dylib )
DYN_GAMESV=( hl_amd64.dylib )
if [ -d "$LION32" ]; then
	DYN_ARCHES+=( i386 )
	DYN_DIRS+=( "$LION32" )
	DYN_GAMECL+=( client.dylib )
	DYN_GAMESV+=( hl.dylib )
	echo "==> i386 slice present, it will be fused in"
else
	echo "==> no i386 slice at $LION32, building without it"
	echo "    (OLDMAC_INTEL_ARCH=i386 scripts/build-lion.sh makes one)"
fi

# arm64 is optional in the same way, but arrives differently: it is the one slice
# that CANNOT be built on this machine, because Xcode 4.6 predates arm64 by seven
# years. It is built on the Apple Silicon box with scripts/build-arm64.sh and
# carried here by scripts/push-arm64-slice.sh, which verifies the copy by
# checksum. Everything after this point treats it exactly like the others.
#
# Lion's lipo can fuse it. It cannot NAME the slice, printing "cputype
# (16777228)" instead of arm64, which is the same cosmetic quirk as Panther's
# lipo and x86_64; the fat it writes is correct, and was verified on the dev box
# and by running the arm64 slice natively.
if [ -d "$ARM64" ]; then
	DYN_ARCHES+=( arm64 )
	DYN_DIRS+=( "$ARM64" )
	DYN_GAMECL+=( client_arm64.dylib )
	DYN_GAMESV+=( hl_arm64.dylib )
	echo "==> arm64 slice present, it will be fused in"
else
	echo "==> no arm64 slice at $ARM64, building without it"
	echo "    (build it on the Apple Silicon box, then scripts/push-arm64-slice.sh HOST)"
fi

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

# The two PPC staging dirs moved from the repo root (dist-ppc-*-app) into
# dist/. A build host synced mid-release can still be holding the old ones, and
# stopping a release to rename a directory helps nobody, so accept the legacy
# path and say so. This remap has to run BEFORE the stamp check below: it used
# to sit after it, where stamp_of had already exited on the missing new-path
# dir, so the fallback could never fire and the host got the wrong message.
for v in PANTHER TIGER; do
	eval "cur=\$$v"
	# shellcheck disable=SC2154 # cur is assigned by the eval above
	[ -d "$cur" ] && continue
	legacy="$ROOT/dist-ppc-$(echo "$v" | tr 'A-Z' 'a-z')-app"
	if [ -d "$legacy" ]; then
		echo "NOTE: using legacy staging dir $legacy (the new path is $cur)"
		eval "$v=\$legacy"
	fi
done

echo "==> checking every slice was built from the same commit"
for d in "$PANTHER" "$TIGER" "${DYN_DIRS[@]}"; do
	got="$( stamp_of "$d" )"
	if [ "$got" != "$PIN_ENGINE_COMMIT" ]; then
		echo "!! $d was built from $got" >&2
		echo "   build-pins.sh says   $PIN_ENGINE_COMMIT" >&2
		echo "   re-run that slice's build driver before fusing." >&2
		exit 1
	fi
done
echo "    ok  every slice at $( short "$PIN_ENGINE_COMMIT" )"
# Carry the agreed stamp forward. Up to now it lived only in the per-slice
# staging dirs, so once the fat bundle was assembled there was nothing left in
# the artifact itself saying what it came from, and make-dmg.sh had to take the
# build on trust. The value written is the one just READ BACK from the slices and
# checked against build-pins.sh, not the pin copied straight out of the file.
FUSED_STAMP="$( stamp_of "$LION" )"

# --- which SDL? ASK THE BINARY, do not assume a prefix -----------------------
# This used to be hardcoded to $ROOT/sdl2-x86_64. When build-lion.sh gained a
# selectable deployment floor it started linking $ROOT/sdl2-snow-x86_64 for the
# 10.6 build, and every one of the three things below went wrong at once, silently:
#   * the 10.7 libSDL2 was copied into a 10.6 bundle, so it could not load on the
#     one OS the floor had just been lowered for
#   * install_name_tool -change was given the OLD path, matched nothing, and
#     exited 0, leaving libxash naming an absolute build-box path
#   * the guard below grepped for the OLD path, correctly did not find it, and
#     therefore PASSED - a check that reported success precisely because it was
#     looking for the wrong string
# Reading the reference out of libxash cannot desync from what was linked,
# because it IS what was linked.
# One SDL per architecture, each derived from the slice that links it.
#
# EXCEPT arm64, which arrives pre-staged and already rewritten. This machine is
# Lion, and its otool has no arm64 in its -arch table at all:
#     otool: unknown architecture specification flag: -arch arm64
# so it cannot select that slice out of a fat, and neither can its
# install_name_tool. build-arm64.sh therefore does all the arm64 Mach-O surgery
# on the Apple Silicon box, verifies the result depends on nothing outside /usr
# and /System, and ships a libSDL2 already carrying @loader_path in its own
# directory. All that is left to do here is lipo it in, which Lion's lipo can do.
vmin_of() { otool -arch "$1" -l "$2" | awk '/LC_VERSION_MIN_MACOSX/{g=1} g&&/^ *version /{print $2; exit}'; }

SDL_PATHS=()
SDL_REWRITE=()          # paths install_name_tool must still fix in the fused libxash
for i in "${!DYN_ARCHES[@]}"; do
	a="${DYN_ARCHES[$i]}"; d="${DYN_DIRS[$i]}"

	if [ "$a" = arm64 ]; then
		[ -f "$d/libSDL2-2.0.0.dylib" ] || {
			echo "!! the arm64 slice has no staged libSDL2-2.0.0.dylib" >&2
			echo "   Re-run scripts/build-arm64.sh on the Apple Silicon box; it stages one." >&2
			exit 1
		}
		echo "    SDL for arm64: pre-staged in the slice, already @loader_path"
		SDL_PATHS+=( "$d/libSDL2-2.0.0.dylib" )
		continue
	fi

	s="$( otool -arch "$a" -L "$d/libxash.dylib" | awk '/libSDL2/ { print $1; exit }' )"
	case "$s" in
		/*) ;;
		*)  echo "!! $a libxash.dylib names no absolute libSDL2 path (got '${s:-nothing}')" >&2
		    echo "   Expected the build-box path that install_name_tool must rewrite." >&2
		    exit 1 ;;
	esac
	[ -f "$s" ] || { echo "!! $a libxash was linked against $s, which is not there now" >&2; exit 1; }

	# The SDL and the engine slice must agree on the floor. A 10.7 libSDL2 beside
	# a 10.6 engine links fine, installs fine, and fails to load on 10.6.
	sdlmin="$( vmin_of "$a" "$s" )"
	engmin="$( vmin_of "$a" "$d/libxash.dylib" )"
	if [ "$sdlmin" != "$engmin" ]; then
		echo "!! $a floor mismatch: libxash targets $engmin but its libSDL2 targets $sdlmin" >&2
		echo "   Rebuild SDL for $engmin, or that slice cannot load it there." >&2
		exit 1
	fi
	# And it must really be that architecture. Two same-arch SDLs would fail at
	# lipo with "duplicate architecture", which names neither the cause nor the
	# prefix that produced it.
	sdlarch="$( lipo -info "$s" | sed 's/.*: //' | tr -d ' ' )"
	if [ "$sdlarch" != "$a" ]; then
		echo "!! SDL at $s is $sdlarch, expected $a" >&2
		exit 1
	fi
	echo "    SDL for $a: $s (version-min $sdlmin)"
	SDL_PATHS+=( "$s" )
	SDL_REWRITE+=( "$s" )
done
OUT="$ROOT/dist/universal"                    # flat fat bundle (feed to make-app.sh)

ENGINE_DYLIBS="libxash.dylib libref_gl.dylib libref_soft.dylib libmenu.dylib filesystem_stdio.dylib"

for d in "$PANTHER" "$TIGER" "${DYN_DIRS[@]}"; do
	[ -d "$d" ] || { echo "MISSING slice dir: $d - run the matching build first" >&2; exit 1; }
done

rm -rf "$OUT"; mkdir -p "$OUT/gamedata/cl_dlls" "$OUT/gamedata/dlls"

ALL_SLICES=( "$PANTHER" "$TIGER" "${DYN_DIRS[@]}" )

echo "==> lipo engine executable (ppc750 + ppc7400 + ${DYN_ARCHES[*]})"
lipo -create "${ALL_SLICES[@]/%//xash3d}" -output "$OUT/xash3d"

# --- every install_name_tool edit happens BEFORE the fuse, on thin files ------
#
# Lion's install_name_tool cannot parse a fat that contains arm64:
#
#   install_name_tool: for architecture cputype (16777228) cpusubtype (0)
#     object: .../libSDL2-2.0.0.dylib malformed object (unknown load command 9)
#
# It has no arm64 in its architecture table, so it chokes on the whole file even
# though the edit it was asked for concerns a different slice. lipo has no such
# problem: it copies slices around without reading their load commands, which is
# why the fuse can still be done here at all.
#
# So the order is inverted: fix each THIN slice first, then fuse. The arm64 thin
# files are already correct, rewritten by build-arm64.sh on the Apple Silicon
# box, which is the only machine that can read them.
STAGE="$OUT/.stage"
mkdir -p "$STAGE"

echo "==> SDL2 (per-arch install name, then fuse; ppc links it statically)"
sdl_thin=()
for i in "${!DYN_ARCHES[@]}"; do
	a="${DYN_ARCHES[$i]}"
	t="$STAGE/libSDL2-$a.dylib"
	cp "${SDL_PATHS[$i]}" "$t"; chmod u+w "$t"
	if [ "$a" != arm64 ]; then
		install_name_tool -id @loader_path/libSDL2-2.0.0.dylib "$t"
	fi
	sdl_thin+=( "$t" )
done
lipo -create "${sdl_thin[@]}" -output "$OUT/libSDL2-2.0.0.dylib"

echo "==> libxash (rewrite each slice's SDL reference, then fuse)"
# NOT optional and NOT silenced. Each slice was linked against its OWN SDL prefix
# and carries a different absolute build-box path, so this is per slice. If it
# were skipped the shipped binary would name a path that exists on no user
# machine, and nothing downstream looks: make-dmg.sh md5s the file but never
# reads its load commands.
xash_thin=( "$PANTHER/libxash.dylib" "$TIGER/libxash.dylib" )
for i in "${!DYN_ARCHES[@]}"; do
	a="${DYN_ARCHES[$i]}"; d="${DYN_DIRS[$i]}"
	t="$STAGE/libxash-$a.dylib"
	cp "$d/libxash.dylib" "$t"; chmod u+w "$t"
	if [ "$a" != arm64 ]; then
		install_name_tool -change "${SDL_PATHS[$i]}" \
			@loader_path/libSDL2-2.0.0.dylib "$t"
		if otool -arch "$a" -L "$t" | grep -q "${SDL_PATHS[$i]}"; then
			echo "!! $a libxash still references ${SDL_PATHS[$i]}" >&2
			exit 1
		fi
	fi
	xash_thin+=( "$t" )
done
lipo -create "${xash_thin[@]}" -output "$OUT/libxash.dylib"

echo "==> lipo the remaining engine dylibs"
for d in $ENGINE_DYLIBS; do
	[ "$d" = libxash.dylib ] && continue      # done above, with its rewrite
	lipo -create "${ALL_SLICES[@]/%//$d}" -output "$OUT/$d"
done

rm -rf "$STAGE"

echo "==> checking no Intel binary depends on a build-box path"
dep_bad=0
for a in "${DYN_ARCHES[@]}"; do
	# arm64 cannot be inspected here: Lion's otool has no arm64 -arch. It was
	# checked for exactly this property by build-arm64.sh on the machine that
	# built it, which is the only machine that can read it.
	[ "$a" = arm64 ] && { echo "    arm64: checked upstream by build-arm64.sh"; continue; }
	for f in "$OUT/xash3d" "$OUT"/*.dylib; do
		# libSDL2 is Intel-only and every other file here is fat, so skip anything
		# that has no slice for this architecture rather than reporting a fault.
		lipo -info "$f" 2>/dev/null | grep -q "$a" || continue
		# -arch matters: these are fat, and otool -D on a fat prints a stanza per
		# architecture, so an unqualified read would not give one clean value.
		own="$( otool -arch "$a" -D "$f" 2>/dev/null | sed 1d )"
		while read -r dep; do
			case "$dep" in
				""|@*|/usr/*|/System/*) continue ;;
				"$own") continue ;;
			esac
			echo "    !! [$a] $(basename "$f") depends on $dep"
			dep_bad=1
		# Process substitution, not a pipe: a pipe would run the loop in a subshell
		# and dep_bad would not survive it, so a real fault would be found and then
		# discarded.
		done < <( otool -arch "$a" -L "$f" 2>/dev/null | sed 1d | awk '{print $1}' )
	done
done
if [ "$dep_bad" -ne 0 ]; then
	echo "!! the Intel slice references paths that exist only on the build box." >&2
	echo "   It would fail to load on any other machine." >&2
	exit 1
fi
echo "    ok  every dependency is @loader_path, /usr or /System"

echo "==> game dylibs (both arch sets; generic-ppc pair serves G3/G4/G5)"
cp "$PANTHER/valve/cl_dlls/client_ppc.dylib" "$OUT/gamedata/cl_dlls/"
cp "$PANTHER/valve/dlls/hl_ppc.dylib"        "$OUT/gamedata/dlls/"
# These stay THIN and side by side rather than being lipo'd together, because the
# engine dlopen's them by architecture NAME (3rdparty/library_suffix): hl_ppc,
# hl_amd64, hl_i386. A fat game dylib would be looked for under a name nothing
# generates.
for i in "${!DYN_ARCHES[@]}"; do
	d="${DYN_DIRS[$i]}"; cl="${DYN_GAMECL[$i]}"; sv="${DYN_GAMESV[$i]}"
	cp "$d/valve/cl_dlls/$cl" "$OUT/gamedata/cl_dlls/"
	cp "$d/valve/dlls/$sv"    "$OUT/gamedata/dlls/"
	echo "    ${DYN_ARCHES[$i]}: $cl, $sv"
done

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
# (See scripts/gen-mod-artwork.py, which generates it.)
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
