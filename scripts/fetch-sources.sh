#!/usr/bin/env bash
# fetch-sources.sh - put every source tree at exactly the commit build-pins.sh names.
#
# RUN THIS ON A BUILD MINI, before any build driver. It does no ssh of its own.
#
#     scripts/fetch-sources.sh            # everything
#     scripts/fetch-sources.sh engine     # just one, by name
#     scripts/fetch-sources.sh --status   # what is checked out right now
#
# WHY THIS REPLACED reset-vendor-trees.sh
#
# The port used to be applied by running scripts/patch-*.py over a fresh upstream
# checkout at build time. Those scripts are marker-guarded, which is right for
# re-applying a fix and wrong for replacing one: a file holding a SUPERSEDED body
# still carries the marker, so the script reports "already patched" and skips it.
# Withdrawing a fix from the repo did not withdraw it from a build host that
# already had it, and nothing in .claude/rules/build-verification.md could see it,
# because every check there looks at the OUTPUT. That was issue #39, and it needed
# a whole script whose only job was to undo the damage.
#
# The port is now commits on our own branches instead, so a tree is either at the
# pinned commit or it is not, and `git checkout` settles it. There is no state to
# get wrong and nothing to un-apply. A hard reset to the pin is the whole story.
#
# The reset IS hard, deliberately: local edits in these trees are discarded. That
# is the point. Anything worth keeping belongs in a commit on the fork, and then
# in a bumped pin here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OLDMAC="${OLDMAC:-$HOME/oldmac}"
SRC="$OLDMAC/vendor"

. "$ROOT/scripts/build-pins.sh"

# Lion's own git is Xcode 4's 1.7, whose OpenSSL cannot negotiate TLS 1.2, so it
# cannot reach GitHub at all. A modern git under ~/local can. Prefer it silently
# where it exists, so this script works unchanged on the minis and on the dev box.
GIT=git
for cand in "$HOME/local/bin/git" /usr/local/bin/git /opt/homebrew/bin/git; do
	[ -x "$cand" ] && { GIT="$cand"; break; }
done

# name | url | branch | commit | destination directory
trees() {
	cat <<EOF
engine|$PIN_ENGINE_URL|$PIN_ENGINE_BRANCH|$PIN_ENGINE_COMMIT|$SRC/xash3d-fwgs
hlsdk|$PIN_HLSDK_URL|$PIN_HLSDK_BRANCH|$PIN_HLSDK_COMMIT|$SRC/hlsdk-portable
sdl|$PIN_SDL_URL|$PIN_SDL_BRANCH|$PIN_SDL_COMMIT|$SRC/panther-sdl2
mbedtls|$PIN_MBEDTLS_URL|$PIN_MBEDTLS_BRANCH|$PIN_MBEDTLS_COMMIT|$SRC/mbedtls-installer
zlib|$PIN_ZLIB_URL|$PIN_ZLIB_BRANCH|$PIN_ZLIB_COMMIT|$SRC/zlib-installer
lzma|$PIN_LZMA_URL|$PIN_LZMA_BRANCH|$PIN_LZMA_COMMIT|$SRC/lzma-installer
EOF
}

status() {
	printf '%-10s %-12s %s\n' NAME STATE DIRECTORY
	trees | while IFS='|' read -r name url branch commit dir; do
		if [ ! -d "$dir/.git" ]; then
			printf '%-10s %-12s %s\n' "$name" "absent" "$dir"
			continue
		fi
		have="$( cd "$dir" && $GIT rev-parse HEAD 2>/dev/null || echo '?' )"
		dirty="$( cd "$dir" && $GIT status --porcelain 2>/dev/null | head -1 )"
		if [ "$have" != "$commit" ]; then state="WRONG-PIN"
		elif [ -n "$dirty" ];      then state="DIRTY"
		else                            state="ok"; fi
		printf '%-10s %-12s %s\n' "$name" "$state" "${have:0:12}"
	done
}

fetch_one() {
	name="$1"; url="$2"; branch="$3"; commit="$4"; dir="$5"

	echo "==> $name  $commit"
	if [ ! -d "$dir/.git" ]; then
		mkdir -p "$( dirname "$dir" )"
		rm -rf "$dir"
		# No --depth: we want the upstream history present, so that
		# `git log <upstream>..oldmac` in this tree shows exactly our own work.
		$GIT clone --branch "$branch" "$url" "$dir"
	fi

	# git 1.7 has no `git -C`, so subshell every time.
	( cd "$dir"
	  $GIT remote set-url origin "$url"
	  $GIT fetch origin "$branch"
	  # Hard, and clean: a build must be a pure function of the pin.
	  $GIT checkout -q --detach "$commit" 2>/dev/null || {
	  	echo "!! $name: pinned commit $commit not found after fetch" >&2
	  	exit 1
	  }
	  $GIT reset -q --hard "$commit"
	  # No -x. Ignored files are the waf out directories, and deleting those would
	  # turn every fetch into a full rebuild. Untracked-but-not-ignored is what we
	  # are actually clearing here, which is leftovers from the old way of working.
	  $GIT clean -qfd || true

	  # The engine carries the menu, miniutl and libbacktrace as submodules, and
	  # our branch points those at our own forks. Recorded commits, not branch
	  # tips, so this is reproducible.
	  if [ -f .gitmodules ]; then
	  	$GIT submodule sync --recursive >/dev/null 2>&1 || $GIT submodule sync >/dev/null 2>&1 || true
	  	$GIT submodule update --init --recursive
	  fi )

	have="$( cd "$dir" && $GIT rev-parse HEAD )"
	[ "$have" = "$commit" ] || { echo "!! $name: HEAD is $have, wanted $commit" >&2; exit 1; }

	# Check the submodules too, by commit and not by "did the update run".
	#
	# This exists because of a real failure. The engine's .gitmodules was changed to
	# name our miniutl fork, but the recorded commit was left at upstream's. Every
	# check passed: the top-level tree was at its pin, `git submodule update` ran
	# without error, and the build then compiled unported miniutl and failed on an
	# #error that had supposedly been fixed weeks earlier. Naming the fork is not
	# the same as pointing at it, and only the recorded commit says which.
	if [ "$name" = "engine" ]; then
		check_sub "$dir/3rdparty/mainui"                     "$PIN_MENU_COMMIT"         menu
		check_sub "$dir/3rdparty/mainui/miniutl"             "$PIN_MINIUTL_COMMIT"      miniutl
		check_sub "$dir/3rdparty/libbacktrace/libbacktrace"  "$PIN_LIBBACKTRACE_COMMIT" libbacktrace
	fi

	echo "    ok $dir"
}

# check_sub <directory> <expected-commit> <label>
check_sub() {
	if [ ! -e "$1/.git" ]; then
		echo "!! $3: submodule not checked out at $1" >&2
		exit 1
	fi
	got="$( cd "$1" && $GIT rev-parse HEAD )"
	if [ "$got" != "$2" ]; then
		echo "!! $3: submodule $1" >&2
		echo "   is at $got" >&2
		echo "   want  $2   (scripts/build-pins.sh)" >&2
		echo "   The superproject records the wrong commit for it. Fix the pointer in" >&2
		echo "   the parent repository, do not just edit .gitmodules." >&2
		exit 1
	fi
	echo "    ok   $3 $( printf '%.7s' "$2" )"
}

main() {
	if [ "${1:-}" = "--status" ]; then status; return 0; fi

	want="${*:-}"
	mkdir -p "$SRC"

	# Redirect from a file rather than piping into the loop. A `... | while` runs
	# the loop body in a subshell, so a failed fetch would exit that subshell and
	# the script would carry on and build stale source. This way a failure is the
	# script's own failure, and set -e ends it.
	list="$( mktemp -t oldmac-trees )"
	trap 'rm -f "$list"' EXIT
	trees > "$list"

	while IFS='|' read -r name url branch commit dir; do
		if [ -n "$want" ]; then
			case " $want " in *" $name "*) ;; *) continue ;; esac
		fi
		fetch_one "$name" "$url" "$branch" "$commit" "$dir"
	done < "$list"

	echo
	echo "All trees are at their pins. Nothing patches them on the way to the compiler:"
	echo "the port is the commits on each oldmac branch. scripts/build-pins.sh"
}

main "$@"
