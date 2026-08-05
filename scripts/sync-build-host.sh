#!/bin/sh
# sync-build-host.sh - put THIS repo's build scripts on a build mini, and prove
# they arrived, before anything is built with them.
#
#   scripts/sync-build-host.sh HOST [--check]
#
# --check reports drift and changes nothing (exit 1 if anything differs).
#
# WHY THIS EXISTS
#
# The build drivers run ON the mini, and ~/oldmac there is a hand-managed tree,
# not a clone: there is no git on the path that owns it and nothing pulls. So the
# repo and the machine that builds from it drift silently, and the drift is
# invisible in the build output because every driver still runs and still says ok.
#
# Measured on 2026-08-05, mini-intel against this repo. Five files differed and
# the repo was newer in every case, so a full universal build had just run with:
#   * build-lion.sh that never cleared its destdir, so a waf task that failed
#     while still exiting 0 would leave the PREVIOUS run's binaries in place
#   * build-lion.sh with no artifact existence check after install
#   * make-universal.sh that ran install_name_tool with `2>/dev/null || true`, so
#     an Intel slice still naming the build box's absolute libSDL2 path would
#     ship and nothing downstream would look
#   * both PowerPC drivers writing BUILD-STAMP from $PIN_ENGINE_COMMIT, i.e. a
#     restatement of what we asked for rather than a record of what was built
#   * a stale VERSION, so the app bundle claimed 1.4.3 while the repo said 1.5.0
#
# None of that showed up as a failure. The stamp in particular is supposed to be
# the evidence that catches a stale build, and it was itself stale.
#
# So: sync first, verify by checksum, and only then build.
set -u

HOST="${1:-}"
MODE="${2:-}"
if [ -z "$HOST" ]; then
	echo "usage: sync-build-host.sh HOST [--check]" >&2
	exit 2
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

# Only what the build reads. Deliberately NOT vendor/ (hand-modified trees live
# there, and an rsync --delete once came within one command of destroying the
# SDL2 tree that is statically linked into both shipped PowerPC slices) and NOT
# dist/ (that is output, and it is where the previous build's artifacts live).
FILES="VERSION
scripts/driver-manifest.md5
scripts/build-all.sh
scripts/build-pins.sh
scripts/fetch-sources.sh
scripts/build-lion.sh
scripts/build-ppc-tiger.sh
scripts/build-ppc-panther.sh
scripts/make-universal.sh
scripts/make-app.sh"

# md5 is the one digest spelling present on 10.3 through modern macOS. `md5 -q`
# exists on all of them; md5sum does not exist on any of them by default.
remote_md5 () {
	ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "md5 -q ~/oldmac/$1 2>/dev/null" 2>/dev/null
}

drift=0
for f in $FILES; do
	[ -f "$f" ] || { echo "!! $f missing from this repo" >&2; drift=1; continue; }
	l=$(md5 -q "$f" 2>/dev/null)
	r=$(remote_md5 "$f")
	if [ "$l" = "$r" ]; then
		printf '%-34s same\n' "$f"
		continue
	fi
	drift=1
	if [ "$MODE" = "--check" ]; then
		if [ -z "$r" ]; then
			printf '%-34s MISSING on %s\n' "$f" "$HOST"
		else
			printf '%-34s DIFFERS from %s\n' "$f" "$HOST"
		fi
		continue
	fi
	if scp -q "$f" "$HOST:oldmac/$f"; then
		# Verify the copy rather than trusting scp's exit code.
		r2=$(remote_md5 "$f")
		if [ "$l" = "$r2" ]; then
			printf '%-34s updated\n' "$f"
		else
			printf '%-34s COPY DID NOT TAKE\n' "$f"
			exit 1
		fi
	else
		printf '%-34s SCP FAILED\n' "$f"
		exit 1
	fi
done

if [ "$MODE" = "--check" ]; then
	[ "$drift" -eq 0 ] && echo "== $HOST matches this repo ==" || echo "== $HOST HAS DRIFTED, run without --check ==" >&2
	exit "$drift"
fi

echo "== $HOST now matches this repo =="
