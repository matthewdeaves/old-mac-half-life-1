#!/usr/bin/env bash
# scripts/bench-adapter.sh -- Half-Life's port adapter for the shared
# bench-evidence contract (build-host#104). Port-owned, like
# dmg-port.conf/dmg-hooks.sh: never synced from old-mac-build-host, never
# edited there. Contract: old-mac-build-host/docs/bench-evidence.md. Sourced
# by scripts/bench-evidence.sh.
#
# Wraps scripts/bench.sh, which already IS this port's evidence harness
# (docs/BENCHMARKING.md): launcher-only launch, the five run assertions
# (bundled root present, dylib loaded, requested renderer actually loaded, no
# host error, real hardware GL not Apple's software fallback), cfg-restore so
# a benched cvar never becomes a machine's permanent default, and a CSV row
# with per-run samples. bench.sh blocks until timerefresh finishes or its own
# watchdog times it out, so bench_launch here is synchronous and always
# leaves PID empty, same shape as quake3's safebench.sh wrap.

PORT=halflife

# bench-evidence.sh always does "$HOME/$INSTALL_BIN" (old-mac-build-host#107:
# not fixed for a leading '/'). Half-Life installs at /Applications/Half-Life
# (scripts/dmg-port.conf INSTALL_DIR), not under any user's $HOME, so this is
# the same path-traversal value quake3's adapter uses, resolving correctly
# rather than being a real absolute path. $HOME is /Users/<name> (2
# components) on every active bench host, verified for quake3's identical
# trick; switch to a plain absolute path once #107 is fixed.
INSTALL_BIN='../../Applications/Half-Life/Half-Life.app/Contents/MacOS/xash3d.bin'

# bench.sh's own defaults (docs/BENCHMARKING.md); override per invocation.
BENCH_REND="${BENCH_REND:-gl}"
BENCH_W="${BENCH_W:-800}"
BENCH_H="${BENCH_H:-600}"
BENCH_MAP="${BENCH_MAP:-c0a0}"
BENCH_FRAMES="${BENCH_FRAMES:-300}"
BENCH_RUNS="${BENCH_RUNS:-3}"
BENCH_WARMUPS="${BENCH_WARMUPS:-1}"
BENCH_SCREENMODE="${BENCH_SCREENMODE:-fullscreen}"
BENCH_TIMEOUT="${BENCH_TIMEOUT:-300}"

# Half-Life's last-run.log path, per host: the launcher writes it beside the
# app (scripts/bench.sh's $BASE), which is the install dir itself here.
_hl_log_path() { echo /Applications/Half-Life/last-run.log; }

bench_launch() {
	local host="$1" round="$2" workdir="$3"
	local self_dir out rc line samples
	self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	if [ "$host" = workstation ]; then
		cp "$self_dir/bench.sh" /tmp/bench.sh && chmod +x /tmp/bench.sh
		out="$(/tmp/bench.sh -N "$host" -r "$BENCH_REND" -W "$BENCH_W" -H "$BENCH_H" \
			-f "$BENCH_FRAMES" -n "$BENCH_RUNS" -w "$BENCH_WARMUPS" -t "$BENCH_TIMEOUT" \
			-m "$BENCH_MAP" -s "$BENCH_SCREENMODE" 2>&1)"
		rc=$?
	else
		scp -q -o BatchMode=yes -o ConnectTimeout=15 "$self_dir/bench.sh" "$host:/tmp/bench.sh" 2>/dev/null
		ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" 'chmod +x /tmp/bench.sh' 2>/dev/null
		out="$(ssh -o BatchMode=yes -o ConnectTimeout=90 "$host" \
			"/tmp/bench.sh -N $host -r $BENCH_REND -W $BENCH_W -H $BENCH_H -f $BENCH_FRAMES -n $BENCH_RUNS -w $BENCH_WARMUPS -t $BENCH_TIMEOUT -m $BENCH_MAP -s $BENCH_SCREENMODE" 2>&1)"
		rc=$?
	fi
	printf '%s\n' "$out" > "$workdir/log.txt"

	# bench.sh's last stdout line is its CSV row; field 10 (fps_runs) is the
	# pipe-separated measured samples with warmups already dropped -- exactly
	# the per-run numeric series the contract wants in stats.txt.
	line="$(printf '%s\n' "$out" | grep -E "^${host//./\\.},(gl|soft)," | tail -1)"
	samples="$(printf '%s\n' "$line" | awk -F, '{print $10}' | tr '|' '\n' | grep -E '^[0-9.]+$')"
	if [ -n "$samples" ]; then
		printf '%s\n' "$samples" > "$workdir/stats.txt"
	fi
	echo fps > "$workdir/stats.unit"

	# bench.sh prints an ERR row (not a number) on its own assertion failures
	# and exits non-zero to match; belt-and-braces in case a transport hiccup
	# (dropped ssh, empty output) left rc looking clean with no row at all.
	[ -n "$line" ] || rc=1

	echo "EXIT=$rc"
	echo "PID="
}

# bench.sh always blocks until the engine self-quits or its own watchdog
# fires, so bench_launch never leaves PID non-empty and this is never called
# live -- kept only to satisfy the adapter contract.
bench_liveness() {
	:
}

# Read back the engine's own log for the run bench_launch just drove, off the
# host directly (the contract only passes host, not the workdir bench_launch
# used) -- same file bench.sh's own assertions 3 and 5 already parse.
bench_effective_config() {
	local host="$1" raw path
	path="$(_hl_log_path)"
	if [ "$host" = workstation ]; then
		raw="$(cat "$path" 2>/dev/null)"
	else
		raw="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" "cat '$path'" 2>/dev/null)"
	fi
	printf '%s\n' "$raw" | sed -E 's/\x1b\[[0-9;]*m//g' | sed -n \
		-e 's/.*GL_RENDERER: */renderer=/p' \
		-e 's/.*Loading renderer: *\([A-Za-z_0-9]*\).*/ref=\1/p' \
		-e 's/.*MODE: */mode=/p'
}
