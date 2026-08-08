#!/bin/bash
# Canonical pins - the SINGLE SOURCE OF TRUTH for both reproduction
# (scripts/bootstrap-vendor.sh sources this) and release provenance
# (scripts/make-dmg.sh stamps these into the build string and BUILD-INFO.txt, so a
# shipped .app records exactly what it was built from).
#
# Bumping a pin: change it HERE only, then re-run bootstrap, build and the fleet
# test, then cut a release. The build string updates itself from these values.
#
# This file is meant to be *sourced*, not executed.
#
# HOW THE PORT IS CARRIED
#
# Every change this port makes is a commit on the `oldmac` branch of our own fork
# of the relevant upstream, with a real diff and a commit message explaining the
# fault it fixes. The build checks out a pin and compiles it. Nothing rewrites a
# source tree on the way past.
#
# It used to work the other way: the drivers cloned upstream and then ran a pile
# of scripts/patch-*.py over the result. That built the same binaries, but the
# port was unreadable, the per-driver patch lists silently drifted apart, and
# there was no way to see what the port actually changed without running it.
#
# Each fork below is a real fork of the upstream named beside it, so the whole
# history is present and `git log upstream/master..oldmac` is exactly our work.

# Base engine marketing version (what Xash3D FWGS reports as its own version).
XASH_VERSION="0.21"

# --- engine: all three slices build from this one branch ---------------------
# Fork of FWGS/xash3d-fwgs, branched at f0ea3a19.
PIN_ENGINE_URL="https://github.com/matthewdeaves/xash3d-fwgs.git"
PIN_ENGINE_BRANCH="oldmac"
PIN_ENGINE_COMMIT="2584d6f89e27b80026c61dd0f81d67cc75bbec30"
PIN_ENGINE_UPSTREAM="FWGS/xash3d-fwgs@f0ea3a19"

# --- menu: submodule of the engine, re-pointed by our engine branch ----------
# Fork of FWGS/mainui_cpp, branched at 510c30c5.
PIN_MENU_URL="https://github.com/matthewdeaves/mainui_cpp.git"
PIN_MENU_BRANCH="oldmac"
PIN_MENU_COMMIT="06aceb1320c1164aa9e0d82c05a0a4b1a4f1d9cd"
PIN_MENU_UPSTREAM="FWGS/mainui_cpp@510c30c5"

# --- miniutl: submodule of the menu ------------------------------------------
# Fork of FWGS/miniutl, branched at 048a416f.
PIN_MINIUTL_URL="https://github.com/matthewdeaves/MiniUTL.git"
PIN_MINIUTL_BRANCH="oldmac"
PIN_MINIUTL_COMMIT="912342dbfd53dc7673351fe60637ddac13be47f9"
PIN_MINIUTL_UPSTREAM="FWGS/miniutl@048a416f"

# --- libbacktrace: submodule of the engine -----------------------------------
# Fork of ianlancetaylor/libbacktrace, branched at b9e40069. One commit: a
# portable byte swap, because Tiger's GCC 4.0 has no __builtin_bswap32.
PIN_LIBBACKTRACE_URL="https://github.com/matthewdeaves/libbacktrace.git"
PIN_LIBBACKTRACE_BRANCH="oldmac"
PIN_LIBBACKTRACE_COMMIT="f23b35ca0959c8881cb98a56bfdcad25972fae03"
PIN_LIBBACKTRACE_UPSTREAM="ianlancetaylor/libbacktrace@b9e40069"

# --- game dylibs: all slices, PowerPC included -------------------------------
# Fork of FWGS/hlsdk-portable, branched at 8c5b2846. Note the licence: this tree
# is Valve's Half-Life 1 SDK licence, NOT GPL, whoever forks it. docs/LICENSING.md.
PIN_HLSDK_URL="https://github.com/matthewdeaves/hlsdk-portable.git"
PIN_HLSDK_BRANCH="oldmac"
PIN_HLSDK_COMMIT="28380b10e62dab6673e02b98e0234926bf5fbebb"
PIN_HLSDK_UPSTREAM="FWGS/hlsdk-portable@8c5b2846"

# --- SDL: PowerPC only, linked statically ------------------------------------
# Fork of alex-free/panther-sdl2 (SDL 2.0.3, targeting 10.3 and 10.4). The Intel
# slice builds stock SDL 2.0.22 as a dylib and needs none of this. docs/adr/0004.
PIN_SDL_URL="https://github.com/matthewdeaves/panther-sdl2.git"
PIN_SDL_BRANCH="oldmac"
PIN_SDL_COMMIT="1e4b81c596199c314328b6d42080d37c2e24971a"
PIN_SDL_UPSTREAM="alex-free/panther-sdl2@bd33187"

# --- installer-only third-party libraries ------------------------------------
# These are linked into "Half-Life Mods.app" ONLY, never into the engine, and are
# separate from anything the engine vendors. The app needs them because each mod
# is fetched from its own publisher rather than from one bundle:
#
#   mbedTLS  every host that publishes a mod answers plain http with a 301 to
#            https, and 10.3 to 10.7's system TLS cannot negotiate what those
#            servers require. This is 3.6 LTS, NOT the 4.x tree with the
#            tf-psa-crypto split: that one routes its clock through the engine's
#            Platform_DoubleTime(), which a Cocoa app does not have.
#   zlib     for the .zip sources. Panther ships libz 1.1.3 from 2003 and has no
#            zlib.h at all, so linking the system copy would mean a decoder fed
#            files off the internet behaving differently per OS version.
#   LZMA     for the .7z sources. There is no system 7z on any macOS.
#
# We patch none of these, so they are pinned straight at their own upstreams.
PIN_MBEDTLS_URL="https://github.com/Mbed-TLS/mbedtls.git"
PIN_MBEDTLS_BRANCH="mbedtls-3.6.7"
PIN_MBEDTLS_COMMIT="068ff080b369adfac81509f9b57b2afabaf82dc5"

PIN_ZLIB_URL="https://github.com/madler/zlib.git"
PIN_ZLIB_BRANCH="v1.3.2"
PIN_ZLIB_COMMIT="da607da739fa6047df13e66a2af6b8bec7c2a498"

PIN_LZMA_URL="https://github.com/ip7z/7zip.git"
PIN_LZMA_BRANCH="26.02"
PIN_LZMA_COMMIT="f9d78aff31a5f2521ae7ddbdc97c4a8855808959"

# short <commit> - first 7 hex chars, for compact build strings
short() { printf '%.7s' "$1"; }

# provenance_oneline <our-git-short> <date> - the compact build string
provenance_oneline() {
	printf 'Xash3D FWGS %s | eng %s | menu %s | hlsdk %s | git:%s | %s' \
		"$XASH_VERSION" "$(short "$PIN_ENGINE_COMMIT")" "$(short "$PIN_MENU_COMMIT")" \
		"$(short "$PIN_HLSDK_COMMIT")" "${1:-unknown}" "${2:-}"
}

# provenance_table <our-git-short> <date> <port-version> - the full BUILD-INFO body
provenance_table() {
	local h="${1:-unknown}" d="${2:-}" ver="${3:-?}"
	cat <<EOF
Half-Life-OldMac ${ver}
=======================
Our build id : old-mac-halflife git ${h} (${d})
Fat slices   : ppc750 . ppc7400 . i386 . x86_64
Base engine  : Xash3D FWGS ${XASH_VERSION}

Every slice is built from our own branch of each upstream. The port is carried as
commits on those branches, not as edits made to a tree at build time.

  component      built from                                    branched from
  engine         matthewdeaves/xash3d-fwgs   @ $(short "$PIN_ENGINE_COMMIT")   ${PIN_ENGINE_UPSTREAM}
  menu           matthewdeaves/mainui_cpp    @ $(short "$PIN_MENU_COMMIT")   ${PIN_MENU_UPSTREAM}
  miniutl        matthewdeaves/MiniUTL       @ $(short "$PIN_MINIUTL_COMMIT")   ${PIN_MINIUTL_UPSTREAM}
  libbacktrace   matthewdeaves/libbacktrace  @ $(short "$PIN_LIBBACKTRACE_COMMIT")   ${PIN_LIBBACKTRACE_UPSTREAM}
  game           matthewdeaves/hlsdk-portable @ $(short "$PIN_HLSDK_COMMIT")   ${PIN_HLSDK_UPSTREAM}
  SDL (PowerPC)  matthewdeaves/panther-sdl2  @ $(short "$PIN_SDL_COMMIT")   ${PIN_SDL_UPSTREAM}

To see exactly what this port changes, in any of them:
    git log --oneline <upstream>..oldmac
    git diff <upstream>..oldmac

Project: https://github.com/matthewdeaves/old-mac-halflife
EOF
}
