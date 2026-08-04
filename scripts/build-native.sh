#!/bin/bash
# Native host build of engine + game dylibs. NOT a target artifact - this is the
# validation/dev build (e.g. arm64 on an Apple Silicon dev box). Proves the
# three-repo pipeline compiles and links on the current host.
#
# Proven working: arm64, macOS 26, Apple clang 21, SDL2 2.32.70 (brew, pkg-config).
# Requires: brew SDL2 (`brew install sdl2`), python3, cmake, Xcode CLT.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/vendor/xash3d-fwgs-intel"      # FWGS mainline (little-endian hosts)
HLSDK="$ROOT/vendor/hlsdk-portable-intel"
OUT="$ROOT/vendor/bin"

# hlsdk-portable must live as hlsdk/ inside the engine tree (per upstream build_apple.sh)
ln -sfn "../$(basename "$HLSDK")" "$ENGINE/hlsdk"

echo "==> [1/2] game dylibs (hlsdk-portable)"
cd "$ENGINE/hlsdk"
./waf configure build install --destdir="$OUT"

echo "==> [2/2] engine"
cd "$ENGINE"
python3 waf configure --sdl-use-pkgconfig --enable-tests
python3 waf build
python3 waf install --destdir="$OUT"

echo "==> done. artifacts in $OUT"
echo "    launcher : $ENGINE/build/game_launch/xash3d"
echo "    engine   : $ENGINE/build/engine/libxash.dylib"
echo "    renderers: build/ref/gl/libref_gl.dylib, build/ref/soft/libref_soft.dylib"
echo "    game     : $OUT/valve/{dlls,cl_dlls}/*.dylib"
echo
echo "To run you still need retail assets: put a Half-Life 'valve/' data dir next"
echo "to the launcher (maps/, models/, *.wad, sound/, sprites/, gfx/), then:"
echo "    $ENGINE/build/game_launch/xash3d -console"
