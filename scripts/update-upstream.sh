#!/bin/bash
# Fetch upstream for every vendored source repo and report how far behind we are.
# Fetch + report only - never auto-rebases. Rebasing is a
# deliberate act because it may need re-testing on real hardware.
set -u
VENDOR="$(cd "$(dirname "$0")/../vendor" && pwd)"

for repo in "$VENDOR"/*/; do
	[ -d "$repo/.git" ] || continue
	name="$(basename "$repo")"
	echo "=== $name ==="
	cd "$repo" || continue
	for r in $(git remote); do
		git fetch -q "$r" 2>/dev/null && echo "  fetched $r"
	done
	# Report divergence of current branch vs each remote's matching branch
	br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
	for r in $(git remote); do
		if git rev-parse --verify -q "$r/$br" >/dev/null; then
			behind="$(git rev-list --count "HEAD..$r/$br" 2>/dev/null)"
			ahead="$(git rev-list --count "$r/$br..HEAD" 2>/dev/null)"
			echo "  vs $r/$br: behind $behind, ahead $ahead"
		fi
	done
done
