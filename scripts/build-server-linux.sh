#!/usr/bin/env bash
# Build the Linux dedicated-server release from the SAME PINS as the Mac fat
# binary. Runs on this box, in a container. It is not a mini job: no mini has
# a Linux toolchain, and none is needed.
#
# usage: scripts/build-server-linux.sh [--arch x86_64|aarch64] [--version V]
# output: dist/server/half-life-server-<version>-linux-<arch>.tar.gz
#
# Requires Docker (or Colima).
#
# WHY THIS IS SAFE TO SHIP AGAINST THE MAC CLIENTS
#
# The port changes nothing on the wire. Against the upstream base, our engine
# branch leaves net_buffer.c, net_chan.c, net_encode.c and the delta tables
# untouched; the only edits under engine/common/net* are host-local behaviour
# (hostname resolution off the frame loop, taking our own address from the
# interface list, a thread_t rename for Panther's mach headers), and the two
# net headers gain nothing but #ifndef typedef guards for old compilers.
#
# So the Mac clients speak stock Xash3D FWGS PROTOCOL_VERSION 49, and a server
# built from these pins is protocol-identical to them by construction rather
# than by testing. Building from the pins is what keeps that true: it is the
# same guarantee build-pins.sh gives the five Mach-O slices.
#
# The hlsdk side is even simpler. Our fork is three commits, two of them build
# flags and one client-side, so the SERVER game library is stock hlsdk at the
# pin. The server needs its own build of it because the game logic runs on the
# server, as native code for the server's CPU, not the players'.
#
# WHAT GETS BUILT
#
#   xash                     the engine, configured --dedicated
#   filesystem_stdio.so      the filesystem module the engine dlopens
#   valve/dlls/hl_amd64.so   the game logic, server side
#   valve/cl_dlls/...        the client library, carried but never loaded here
#
# The client library is included only to silence a "missing game library"
# warning the engine prints at startup when it cannot find one for this
# platform. A dedicated server never loads it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# The single source of truth for what we build, shared with every Mac slice.
# shellcheck source=scripts/build-pins.sh
. "$REPO_ROOT/scripts/build-pins.sh"

ARCH="x86_64"
VERSION=""

while [ $# -gt 0 ]; do
	case "$1" in
		--arch)    ARCH="${2:?--arch needs a value}"; shift 2 ;;
		--version) VERSION="${2:?--version needs a value}"; shift 2 ;;
		-h|--help) sed -n '2,10p' "$0"; exit 0 ;;
		*) echo "$0: unknown argument: $1" >&2; exit 2 ;;
	esac
done

case "$ARCH" in
	x86_64)  DOCKER_PLATFORM="linux/amd64"; GAME_SUFFIX="amd64" ;;
	aarch64) DOCKER_PLATFORM="linux/arm64"; GAME_SUFFIX="arm64" ;;
	*) echo "$0: unsupported arch: $ARCH (expected x86_64 or aarch64)" >&2; exit 2 ;;
esac

[ -n "$VERSION" ] || VERSION="$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo unknown)"
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY=""
git diff --quiet 2>/dev/null || GIT_DIRTY="+dirty"
BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"

IMAGE="oldmac-halflife-server-build:deb11"
OUT_DIR="$REPO_ROOT/dist/server"
WORK="$REPO_ROOT/dist/server-build-$ARCH"

echo "[server] half-life dedicated server"
echo "[server]   arch     : $ARCH ($DOCKER_PLATFORM)"
echo "[server]   version  : $VERSION"
echo "[server]   our git  : $GIT_COMMIT$GIT_DIRTY"
echo "[server]   engine   : $(short "$PIN_ENGINE_COMMIT")"
echo "[server]   hlsdk    : $(short "$PIN_HLSDK_COMMIT")"

command -v docker >/dev/null 2>&1 || {
	echo "$0: docker not found. Start Colima or Docker Desktop first." >&2; exit 1; }
docker info >/dev/null 2>&1 || {
	echo "$0: the Docker daemon is not responding. Try: colima start" >&2; exit 1; }

mkdir -p "$WORK" "$OUT_DIR"

echo "[server] building container image"
docker build --platform "$DOCKER_PLATFORM" \
	-t "$IMAGE" -f scripts/docker/server-build.Dockerfile scripts/docker >/dev/null

# ------------------------------------------------------------------- sources
#
# Cloning happens HERE, not in the container: the forks are reached with this
# box's git credentials and ssh rewrite, which a container has no share of.
#
# The engine tree is reused from vendor/ when it is already sitting at the pin,
# because it is 357M and cloning it again to get the same commit is waste. The
# check is on the commit, never on the directory merely existing: a vendor tree
# at the WRONG pin is exactly the failure this has to catch.
prepare_tree() {
	# Split, not one `local` line: bash expands every word on a `local`
	# command before it assigns any of them, so a `dest="$WORK/src/$name"`
	# sharing the line with `name="$1"` reads $name while it is still unset,
	# which under `set -u` aborts the script.
	local name="$1"
	local url="$2"
	local commit="$3"
	local reuse="$4"
	local dest="$WORK/src/$name"

	if [ -d "$dest/.git" ]; then
		local have
		have="$( cd "$dest" && git rev-parse HEAD 2>/dev/null || echo none )"
		if [ "$have" = "$commit" ]; then
			echo "[server] $name: already at $(short "$commit")"
			return 0
		fi
		rm -rf "$dest"
	fi

	if [ -n "$reuse" ] && [ -d "$reuse/.git" ]; then
		local have
		have="$( cd "$reuse" && git rev-parse HEAD 2>/dev/null || echo none )"
		if [ "$have" = "$commit" ]; then
			echo "[server] $name: copying vendor tree at $(short "$commit")"
			mkdir -p "$dest"
			( cd "$reuse" && tar cf - . ) | tar xf - -C "$dest"
			return 0
		fi
		echo "[server] $name: vendor tree is at ${have:0:7}, not the pin, cloning instead"
	fi

	echo "[server] $name: cloning at $(short "$commit")"
	rm -rf "$dest"
	git clone -q --recursive "$url" "$dest"
	( cd "$dest" && git checkout -q "$commit" && git submodule -q update --init --recursive )
}

mkdir -p "$WORK/src"
prepare_tree engine "$PIN_ENGINE_URL" "$PIN_ENGINE_COMMIT" "$REPO_ROOT/vendor/engine-src"
prepare_tree hlsdk  "$PIN_HLSDK_URL"  "$PIN_HLSDK_COMMIT"  ""

# Refuse to build a tree that is not at the pin. This is the same rule the Mac
# drivers follow, and the reason is on record: three drivers once correctly
# refused a wrong-pin tree and the run still finished saying "done".
for t in engine hlsdk; do
	case "$t" in
		engine) want="$PIN_ENGINE_COMMIT" ;;
		hlsdk)  want="$PIN_HLSDK_COMMIT" ;;
	esac
	have="$( cd "$WORK/src/$t" && git rev-parse HEAD )"
	if [ "$have" != "$want" ]; then
		echo "$0: $t is at $have, expected $want" >&2
		exit 1
	fi
done

cat > "$WORK/build-in-container.sh" <<CONTAINER_SCRIPT
#!/bin/sh
set -e

# -8 is not optional. Xash3D FWGS defaults to 32-bit output, because GoldSrc
# mods were 32-bit, and on a 64-bit-only container that fails configure with
# "Compiler can't create 32-bit code!". This picks 64-bit deliberately: the
# server's word size has nothing to do with the clients', which include a
# 32-bit i386 slice and two PowerPC ones.
# Hardening.
#
# This server parses UDP datagrams from strangers, in a 1998 codebase, and is
# meant to sit on the internet permanently. Debian's gcc gives PIE and NX by
# default and nothing else, so a plain build ships with no stack canaries, no
# FORTIFY_SOURCE and only partial RELRO. These are the difference between a
# memory-safety bug being a crash and being a shell.
#
# waf reads these from the environment at CONFIGURE time and bakes them into
# the stored environment, so they must be exported before waf configure, not
# before waf build.
#
# No -pie: this produces shared objects (filesystem_stdio.so, hl_amd64.so) as
# well as an executable, and -shared with -pie is a contradiction the linker
# rejects. Debian's gcc already defaults executables to PIE.
HARDEN="-fstack-protector-strong -D_FORTIFY_SOURCE=2"
export CFLAGS="\$HARDEN"
export CXXFLAGS="\$HARDEN"
export LINKFLAGS="-Wl,-z,relro,-z,now -Wl,-z,noexecstack"
export LDFLAGS="\$LINKFLAGS"

echo "[container] configuring engine (dedicated, 64-bit)"
cd /work/src/engine
python3 waf configure --dedicated -8 -T release > /work/engine-conf.log 2>&1 || {
	echo "[container] engine configure failed:" >&2; tail -25 /work/engine-conf.log >&2; exit 1; }

echo "[container] building engine"
python3 waf build > /work/engine-build.log 2>&1 || {
	echo "[container] engine build failed:" >&2; tail -30 /work/engine-build.log >&2; exit 1; }

# waf exits 0 on a failed task and then installs stale objects, so the exit
# code above is necessary and not sufficient. Check the artifacts exist.
for want in build/engine/xash build/filesystem/filesystem_stdio.so; do
	[ -f "\$want" ] || { echo "[container] engine build produced no \$want" >&2; exit 1; }
done

echo "[container] configuring game libraries"
cd /work/src/hlsdk
python3 waf configure -8 -T release > /work/hlsdk-conf.log 2>&1 || {
	echo "[container] hlsdk configure failed:" >&2; tail -25 /work/hlsdk-conf.log >&2; exit 1; }

echo "[container] building game libraries"
python3 waf build > /work/hlsdk-build.log 2>&1 || {
	echo "[container] hlsdk build failed:" >&2; tail -30 /work/hlsdk-build.log >&2; exit 1; }

GAME_SO=build/dlls/hl_${GAME_SUFFIX}.so
[ -f "\$GAME_SO" ] || { echo "[container] hlsdk build produced no \$GAME_SO" >&2; exit 1; }

mkdir -p /work/out/valve/dlls /work/out/valve/cl_dlls
cp /work/src/engine/build/engine/xash                       /work/out/
cp /work/src/engine/build/filesystem/filesystem_stdio.so    /work/out/
cp /work/src/hlsdk/\$GAME_SO                                 /work/out/valve/dlls/
cp /work/src/hlsdk/build/cl_dll/client_${GAME_SUFFIX}.so    /work/out/valve/cl_dlls/ 2>/dev/null || true
strip /work/out/xash /work/out/filesystem_stdio.so /work/out/valve/dlls/*.so 2>/dev/null || true

echo "[container] verifying"
file /work/out/xash

# Assert the hardening actually landed. waf stores the configure-time
# environment, so a flag that failed to reach it produces a build that looks
# entirely normal and is quietly unprotected.
for f in /work/out/xash /work/out/filesystem_stdio.so /work/out/valve/dlls/hl_${GAME_SUFFIX}.so; do
	readelf -sW "\$f" | grep -q "__stack_chk_fail" || {
		echo "[container] no stack canaries in \$f" >&2; exit 1; }
	readelf -dW "\$f" | grep -q "BIND_NOW" || {
		echo "[container] RELRO is not full in \$f" >&2; exit 1; }
	readelf -lW "\$f" | grep -q "GNU_STACK.*RWE" && {
		echo "[container] executable stack in \$f" >&2; exit 1; }
done
echo "[container] hardening: canaries yes, full RELRO, NX"

# Everything loaded must be part of glibc, or the operator has packages to
# install and the release is not self-contained.
for f in /work/out/xash /work/out/filesystem_stdio.so /work/out/valve/dlls/hl_${GAME_SUFFIX}.so; do
	ldd "\$f" > /work/ldd.txt 2>&1 || true
	BAD=\$(awk '{print \$1}' /work/ldd.txt \\
		| sed 's|.*/||' \\
		| grep -E '\\.so' \\
		| grep -vE '^(linux-vdso|libc|libm|libdl|libpthread|librt|libgcc_s|libstdc\\+\\+|ld-linux.*)\\.so' || true)
	if [ -n "\$BAD" ]; then
		echo "[container] \$f depends on libraries outside glibc:" >&2
		echo "\$BAD" >&2
		exit 1
	fi
done

# It has to start. With no game content it stops early, and reaching the
# filesystem stage proves the engine and its filesystem module loaded.
useradd -m -u 1502 hlprobe 2>/dev/null || true
mkdir -p /work/probe
chown -R hlprobe /work/probe /work/out
su hlprobe -c 'cd /work/probe && timeout 10 stdbuf -oL -eL /work/out/xash -dedicated > /work/probe.log 2>&1' || true
if ! grep -qiE "xash|adding directory|game librar" /work/probe.log; then
	echo "[container] the server did not start:" >&2
	cat /work/probe.log >&2
	exit 1
fi
echo "[container] startup probe reached engine init"
CONTAINER_SCRIPT
chmod +x "$WORK/build-in-container.sh"

echo "[server] compiling in container"
rm -rf "$WORK/out"
docker run --rm --platform "$DOCKER_PLATFORM" \
	-v "$WORK:/work" -w /work \
	"$IMAGE" /work/build-in-container.sh

for want in out/xash out/filesystem_stdio.so "out/valve/dlls/hl_$GAME_SUFFIX.so"; do
	[ -f "$WORK/$want" ] || { echo "$0: missing artifact $want" >&2; exit 1; }
done

# ---------------------------------------------------------------------- package
STAGE="$WORK/pkg/half-life-server-$VERSION-linux-$ARCH"
rm -rf "$WORK/pkg"
mkdir -p "$STAGE/systemd" "$STAGE/valve"

cp -R "$WORK/out/valve/." "$STAGE/valve/"
cp "$WORK/out/xash"                     "$STAGE/xash"
cp "$WORK/out/filesystem_stdio.so"      "$STAGE/filesystem_stdio.so"
cp "$REPO_ROOT/server/server.cfg"       "$STAGE/server.cfg"
cp "$REPO_ROOT/server/README.md"        "$STAGE/README.md"
cp "$REPO_ROOT/server/xash-server.service" "$STAGE/systemd/"

cat > "$STAGE/BUILD-INFO.txt" <<EOF
Half-Life dedicated server (old-mac-half-life-1)
================================================
Version      : $VERSION
Our build id : git $GIT_COMMIT$GIT_DIRTY
Built on     : $BUILD_DATE
Target       : linux-$ARCH
Built against: Debian 11, glibc 2.31
Base engine  : Xash3D FWGS $XASH_VERSION

  component   built from                                    branched from
  engine      matthewdeaves/xash3d-fwgs   @ $(short "$PIN_ENGINE_COMMIT")   $PIN_ENGINE_UPSTREAM
  game        matthewdeaves/hlsdk-portable @ $(short "$PIN_HLSDK_COMMIT")   $PIN_HLSDK_UPSTREAM

These are the SAME pins the Mac fat binary is built from, which is what makes
this server protocol-identical to those clients. The port changes nothing on
the wire: net_buffer.c, net_chan.c, net_encode.c and the delta tables are
untouched, so both ends speak stock PROTOCOL_VERSION 49.

Runs on any Linux with glibc 2.31 or newer (Ubuntu 20.04 and up). The only
shared libraries loaded are part of glibc.

Contents:
  xash                       the engine, built --dedicated
  filesystem_stdio.so        the filesystem module the engine loads
  valve/dlls/hl_$GAME_SUFFIX.so       the game logic, server side
  valve/cl_dlls/             the client library, carried but never loaded

No content is included. We ship code, not content: supply your own valve/.

Project: https://github.com/matthewdeaves/old-mac-half-life-1
EOF

TARBALL="$OUT_DIR/half-life-server-$VERSION-linux-$ARCH.tar.gz"
rm -f "$TARBALL"
tar czf "$TARBALL" -C "$WORK/pkg" "$(basename "$STAGE")"
tar tzf "$TARBALL" >/dev/null || { echo "$0: tarball is unreadable" >&2; exit 1; }

echo
echo "[server] done"
echo "[server]   $TARBALL"
echo "[server]   $(du -h "$TARBALL" | cut -f1)  sha256 $(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
echo
tar tzf "$TARBALL" | sed 's/^/[server]   /'
