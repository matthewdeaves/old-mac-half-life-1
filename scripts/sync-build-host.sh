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
	echo "usage: sync-build-host.sh HOST [--check|--all]" >&2
	exit 2
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

# Only what the build reads, INCLUDING the app artwork. make-app.sh stamps the
# icon into the bundle on the build host, so a host with stale MacOSX/*.icns
# produces an app carrying the wrong picture even when every script is current.
# Measured 2026-08-05: a build made minutes after new artwork landed still had
# the previous icon, because this list covered scripts/ and VERSION only.
#
# Deliberately NOT vendor/ (hand-modified trees live
# there, and an rsync --delete once came within one command of destroying the
# SDL2 tree that is statically linked into both shipped PowerPC slices) and NOT
# dist/ (that is output, and it is where the previous build's artifacts live).
FILES="VERSION
MacOSX/Half-Life.icns
MacOSX/Half-Life-Mods.icns
MacOSX/Half-Life-SysReport.icns
compat-include/cinttypes
compat-include/cstdint
configs/userconfig.cfg
configs/gameui_english.txt
scripts/driver-manifest.md5
scripts/build-all.sh
scripts/build-pins.sh
scripts/fetch-sources.sh
scripts/build-lion.sh
scripts/build-ppc-tiger.sh
scripts/build-ppc-panther.sh
scripts/make-universal.sh
scripts/make-app.sh
scripts/build-installer.sh
scripts/build-sysreport.sh
scripts/build-mod.sh
scripts/fuse-mod-arm64.sh
scripts/patch-hlsdk-mod-bugs.py
scripts/patch-hlsdk-mod-gcc4.py
scripts/patch-hlsdk-ppc-darwin.py
scripts/patch-hlsdk-shared-clientbugs.py
scripts/patch-hlsdk-xcompile-ppc.py"

# md5 is the one digest spelling present on 10.3 through modern macOS. `md5 -q`
# exists on all of them; md5sum does not exist on any of them by default.
remote_md5 () {
	ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "md5 -q ~/oldmac/$1 2>/dev/null" 2>/dev/null
}


# --- full tracked-tree mode ------------------------------------------------
#
# The file list below covers what the ENGINE build reads. It does not cover the
# mod installer or the system report app, which are built from installer/ and
# sysreport/ sources and their own artwork, and those drifted too: a deployed
# Half-Life Mods.app was found carrying an About picture weeks older than the
# repo's, because nothing shipped installer/ to the build host and make-dmg only
# refreshes icons.
#
# --all syncs every TRACKED file via git archive. That is exactly the repo
# contents, so it cannot pick up local junk, and it never deletes, so vendor/ and
# dist/ on the host are untouched. vendor/ in particular holds hand-modified
# trees including the SDL2 that is statically linked into both PowerPC slices,
# and an rsync --delete once came within one command of destroying it.
if [ "$MODE" = "--all" ]; then
	echo "== syncing every tracked file to $HOST =="
	tmp="/tmp/oldmac-tree-$$.tar"
	git archive --format=tar HEAD > "$tmp" || { echo "!! git archive failed" >&2; exit 1; }
	if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "mkdir -p oldmac && tar xf - -C oldmac" < "$tmp"; then
		echo "!! failed to unpack the tree on $HOST" >&2
		rm -f "$tmp"; exit 1
	fi
	rm -f "$tmp"
	# Verify the same way the per-file path does: checksum, do not trust exit codes.
	bad=0
	for f in $FILES; do
		l=$(md5 -q "$f" 2>/dev/null)
		r=$(remote_md5 "$f")
		[ "$l" = "$r" ] || { echo "!! $f did not take"; bad=1; }
	done
	[ "$bad" -eq 0 ] && echo "== $HOST now has this repo's tracked tree ==" || exit 1
	exit 0
fi

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
	# The file list is no longer flat (compat-include/, MacOSX/, scripts/), and scp
	# does not create intermediate directories: it fails with "No such file or
	# directory" on a host that has never had that folder. Make it first.
	d=$(dirname "$f")
	if [ "$d" != "." ]; then
		ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "mkdir -p oldmac/$d" || {
			printf '%-34s COULD NOT MAKE oldmac/%s\n' "$f" "$d"; exit 1; }
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

# --- directories a driver reads WHOLESALE ------------------------------------
#
# make-universal.sh copies every file in these into the app bundle (the Custom
# Game artwork and blurbs for all 25 mods). They obey exactly the same rule as
# FILES: read from the repo at build time, therefore able to drift, therefore
# able to ship something nobody chose. This is not hypothetical, it is the fault
# recorded at the top of this file, where a deployed Half-Life Mods.app was found
# carrying an About picture weeks older than the repo's.
#
# They are not listed by name because there are 50 of them and the count grows
# with every mod added. Compared instead by a fingerprint over names AND contents
# in ONE round trip: contents alone would miss a rename, names alone would miss
# an edited blurb.
# installer/ covers artwork/ and descriptions/ as well as the Objective-C source
# that build-installer.sh compiles, so it is listed whole rather than as three
# overlapping entries. Same for sysreport/. Neither app is built by build-all.sh
# yet, which is why their sources went unsynced for so long without it showing.
DIRS="installer
sysreport"

# LC_ALL=C is NOT decoration. sort's collation is locale-dependent, and this box
# and the build minis disagree: with names like Hunger.tga, TheGate.tga and
# Zombie-X-DLE.tga the two orders differ, so the same 25 identical files
# fingerprint differently on each side and the directory reports drift forever.
# A check that cries wolf is worse than no check, because it teaches you to run
# the sync that silences it. Byte order on both sides, always.
fp_local () {
	( cd "$1" 2>/dev/null && find . -type f | LC_ALL=C sort | while read -r f; do
		echo "$f $(md5 -q "$f")"; done ) | md5 -q
}
fp_remote () {
	ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" \
		'cd oldmac/'"$1"' 2>/dev/null && find . -type f | LC_ALL=C sort | while read -r f; do
			echo "$f $(md5 -q "$f")"; done | md5 -q' 2>/dev/null
}

for d in $DIRS; do
	if [ ! -d "$d" ]; then
		echo "!! $d missing from this repo" >&2; drift=1; continue
	fi
	l=$(fp_local "$d")
	r=$(fp_remote "$d")
	n=$(find "$d" -type f | wc -l | tr -d ' ')
	if [ "$l" = "$r" ]; then
		printf '%-34s same (%s files)\n' "$d/" "$n"
		continue
	fi
	drift=1
	if [ "$MODE" = "--check" ]; then
		printf '%-34s DIFFERS from %s\n' "$d/" "$HOST"
		continue
	fi
	# tar, not scp: one connection regardless of file count, and it creates the
	# directory on a host that has never had it. No --delete anywhere near it.
	if tar cf - "$d" | ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "mkdir -p oldmac && tar xf - -C oldmac"; then
		r2=$(fp_remote "$d")
		if [ "$l" = "$r2" ]; then
			printf '%-34s updated (%s files)\n' "$d/" "$n"
		else
			printf '%-34s COPY DID NOT TAKE\n' "$d/"
			exit 1
		fi
	else
		printf '%-34s TAR FAILED\n' "$d/"
		exit 1
	fi
done

if [ "$MODE" = "--check" ]; then
	[ "$drift" -eq 0 ] && echo "== $HOST matches this repo ==" || echo "== $HOST HAS DRIFTED, run without --check ==" >&2
	exit "$drift"
fi

echo "== $HOST now matches this repo =="
