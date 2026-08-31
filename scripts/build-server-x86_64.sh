#!/usr/bin/env bash
# Build the Linux x86_64 dedicated server on whichever host actually has it free
# right now, preferring imac-2019 for speed but never depending on it alone.
#
# usage: scripts/build-server-x86_64.sh [--version V]
#   HOST=imac-2019 or HOST=workstation forces one path; unset picks automatically.
# output: dist/server/half-life-server-<version>-linux-x86_64.tar.gz, same as a
#         direct build-server-linux.sh run - callers should not need to know
#         which host actually built it.
#
# WHY THIS EXISTS, and why imac-2019 is PREFERRED, never REQUIRED
#
# build-server-linux.sh --arch x86_64 runs `docker build --platform linux/amd64`.
# On imac-2019 (Intel) that is native; on this arm64 workstation it is emulated.
# Issue #22, measured 2026-08-30: built the server on both from the same pins and
# diffed every shipped binary (xash, filesystem_stdio.so, hl_amd64.so,
# client_amd64.so) with sha256 - byte-for-byte identical. So the only difference
# is build speed, not correctness, which is exactly the condition under which a
# "prefer the fast one" default is safe. imac-2019 is one Mac mini shared with
# every other port's build/bench work; if it is busy, off or unreachable, this
# falls back to building right here rather than blocking on it. Never make it
# the only path - the user's own words, asking for this script.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION=""
while [ $# -gt 0 ]; do
	case "$1" in
		--version) VERSION="${2:?--version needs a value}"; shift 2 ;;
		-h|--help) sed -n '2,10p' "$0"; exit 0 ;;
		*) echo "$0: unknown argument: $1" >&2; exit 2 ;;
	esac
done

_PICK="$REPO_ROOT/scripts/pick-bench-host.sh"

build_locally() {
	echo "[build-server-x86_64] building here (emulated linux/amd64)"
	"$REPO_ROOT/scripts/build-server-linux.sh" --arch x86_64 ${VERSION:+--version "$VERSION"}
}

# Auto-pick, once, before any locking: is imac-2019 actually free right now?
# `--status` alone, never `--acquire` here - deciding which host to use must
# not itself claim one, or an auto-pick that falls back would leave a stale
# claim on the host it chose NOT to use.
if [ -z "${HOST:-}" ]; then
	if [ -x "$_PICK" ] && "$_PICK" --status imac-2019 2>/dev/null | tail -n +2 | awk '{print $2}' | grep -qx "free"; then
		HOST=imac-2019
	else
		echo "[build-server-x86_64] imac-2019 not free right now (see: scripts/pick-bench-host.sh --status imac-2019) - falling back to this box" >&2
		HOST=workstation
	fi
fi

case "$HOST" in
	workstation|local)
		build_locally
		;;
	imac-2019)
		# Same claim-by-re-exec idiom as deploy-dmg.sh/make-dmg.sh: --run makes the
		# lock a property of the invocation, released however this exits, and the
		# RETRO_BENCH_LOCK guard stops this branch re-wrapping itself once claimed.
		# HOST is exported through so the re-invocation skips auto-pick entirely -
		# by the time it runs, --run has already claimed imac-2019, so a fresh
		# --status check here would see it as busy (itself) and wrongly fall back.
		if [ "${RETRO_BENCH_LOCK:-}" != "imac-2019" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
			export RETRO_BENCH_LOCK="imac-2019" HOST="imac-2019"
			if [ -n "$VERSION" ]; then
				exec "$_PICK" --run imac-2019 "build-server-x86_64" -- "$0" --version "$VERSION"
			else
				exec "$_PICK" --run imac-2019 "build-server-x86_64" -- "$0"
			fi
		fi
		echo "[build-server-x86_64] building on imac-2019 (native linux/amd64)"
		"$REPO_ROOT/scripts/sync-build-host.sh" imac-2019
		[ -n "$VERSION" ] || VERSION="$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo unknown)"
		ssh imac-2019 "cd oldmac && scripts/build-server-linux.sh --arch x86_64 --version $VERSION"
		# Pull the artifact back so it lands in dist/server/ here too, whichever
		# host actually built it - the caller should not need to know or care.
		# Named explicitly rather than a remote glob: a glob with no local match
		# happens to pass through literally under default bash settings, which is
		# not something to depend on.
		TARBALL="half-life-server-$VERSION-linux-x86_64.tar.gz"
		mkdir -p "$REPO_ROOT/dist/server"
		scp -q "imac-2019:oldmac/dist/server/$TARBALL" "$REPO_ROOT/dist/server/$TARBALL"
		echo "[build-server-x86_64] fetched: $REPO_ROOT/dist/server/$TARBALL"
		;;
	*)
		echo "$0: HOST must be imac-2019, workstation, or unset for auto-pick" >&2
		exit 2
		;;
esac
