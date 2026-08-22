#!/bin/bash
# fleet-bench.sh - run the deterministic Half-Life timerefresh benchmark across
# the old-Mac fleet from the orchestration box and collect results into a
# rolling CSV (benchmarks/results.csv).
#
# It ships scripts/bench.sh to each reachable machine over SSH, runs it with the
# requested renderer/resolution/frames, and appends one timestamped, labelled
# row per machine. Unreachable machines are skipped with a note.
#
# Usage:
#   scripts/fleet-bench.sh [-l label] [-r gl|soft] [-W w] [-H h]
#                          [-s fullscreen|borderless|windowed]
#                          [-f frames] [-n runs] [-w warmups] [-t timeout]
#                          [-m map] [host ...]
# If no hosts are given, the default fleet is used. `label` tags the run
# (e.g. "baseline", "fix-invalidenum", "vbo-on") so before/after rows are easy
# to compare. Example:
#   scripts/fleet-bench.sh -l baseline -r gl -W 800 -H 600 yosemite
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCHDIR="$ROOT/benchmarks"
CSV="$BENCHDIR/results.csv"
BENCH_SH="$ROOT/scripts/bench.sh"
SSH="ssh -o ConnectTimeout=8 -o BatchMode=yes"
SCP="scp -o ConnectTimeout=8 -o BatchMode=yes"

# ---- defaults ---------------------------------------------------------------
LABEL="adhoc"
REND=gl
W=800
H=600
FRAMES=300
RUNS=3
WARMUPS=1
TIMEOUT=300
MAP=c0a0
SCREENMODE=fullscreen
# Console commands applied after map settle, before the warmup. Lets an A/B of a
# render cvar run through the supported harness instead of a hand-rolled cfg.
EXTRA=""
# Extra LAUNCH arguments handed through to bench.sh -A, for launch-time knobs a
# console cvar cannot reach (-nobpp, -nogldepth16, -noglnostencil, -nobilinear).
LAUNCHARGS=""

while getopts "l:r:W:H:f:n:w:t:m:s:x:A:" opt; do
	case "$opt" in
		l) LABEL=$OPTARG ;;
		r) REND=$OPTARG ;;
		W) W=$OPTARG ;;
		H) H=$OPTARG ;;
		f) FRAMES=$OPTARG ;;
		n) RUNS=$OPTARG ;;
		w) WARMUPS=$OPTARG ;;
		t) TIMEOUT=$OPTARG ;;
		m) MAP=$OPTARG ;;
		s) SCREENMODE=$OPTARG ;;
		x) EXTRA=$OPTARG ;;
		A) LAUNCHARGS=$OPTARG ;;
		*) echo "usage: fleet-bench.sh [-l label] [-r gl|soft] [-W w] [-H h] [-f frames] [-n runs] [-w warmups] [-t timeout] [-m map] [-s fullscreen|borderless|windowed] [-x \"cvar val; cvar val\"] [-A \"launch args\"] [host ...]" >&2; exit 2 ;;
	esac
done
shift $((OPTIND - 1))

# Canonicalise the screen mode here, so the spelling we send to bench.sh, the
# spelling bench.sh writes into the CSV and the spelling we check it against are
# all the same string. Also rejects a typo on this box instead of on five Macs.
case "$SCREENMODE" in
	full|fullscreen)   SCREENMODE=fullscreen ;;
	border|borderless) SCREENMODE=borderless ;;
	window|windowed)   SCREENMODE=windowed ;;
	*) echo "fleet-bench.sh: bad -s mode '$SCREENMODE' (fullscreen|borderless|windowed)" >&2; exit 2 ;;
esac

# default fleet (SSH host aliases). sawtooth is offline -> excluded.
if [ "$#" -gt 0 ]; then
	HOSTS="$*"
else
	HOSTS="yosemite quicksilver mini-g4 imac-g5 mini-intel"
fi

mkdir -p "$BENCHDIR"
if [ ! -f "$CSV" ]; then
	echo "timestamp,label,host,renderer,resolution,screenmode,map,frames,fps_min,fps_med,fps_max,fps_runs" > "$CSV"
fi

TS=$(date "+%Y-%m-%dT%H:%M:%S")
echo "== fleet-bench label=$LABEL renderer=$REND ${W}x${H} $SCREENMODE map=$MAP frames=$FRAMES runs=$RUNS =="

# Claim each machine before touching it, and let it go the moment we are done.
#
# Without this, two sessions benching different ports on the same G5 interleave
# their engine launches and BOTH sets of numbers are wrong, with nothing in the
# CSV to say so. The lock lives on the target, so it is visible to every repo and
# every workstation, not just this one. `pick-bench-host.sh` also refuses a host
# booted into an OS its alias does not name, which is the failure that would
# otherwise write a row labelled "tiger" from a Leopard-booted quad.
PICK="$ROOT/scripts/pick-bench-host.sh"
HELD=""
release_held() {
	for r in $HELD; do "$PICK" --release "$r" >/dev/null 2>&1; done
	HELD=""
}
# Release on interrupt too: a killed sweep must not wedge half the fleet.
trap 'release_held' EXIT INT TERM

for h in $HOSTS; do
	if ! $SSH "$h" true 2>/dev/null; then
		echo "  [$h] unreachable - skipped" >&2
		continue
	fi
	if [ -x "$PICK" ]; then
		if ! "$PICK" --acquire "$h" "bench:$LABEL" >/dev/null; then
			echo "  [$h] busy or wrong OS - skipped (scripts/pick-bench-host.sh --status $h)" >&2
			continue
		fi
		HELD="$HELD $h"
	fi
	# ship the latest bench.sh
	$SCP "$BENCH_SH" "$h:/tmp/bench.sh" >/dev/null 2>&1
	$SSH "$h" 'chmod +x /tmp/bench.sh' 2>/dev/null
	# run it; bench.sh prints one CSV line on stdout (and notes on stderr)
	# -N "$h": label the row with the ssh ALIAS, not the machine's own hostname.
	# The alias is the only unique name here, because the G3 and the G5 each
	# multi-boot several OSes from one IP and every partition answers `hostname`
	# identically. Without this the G3 records as "macs-computer" whichever OS it
	# is running, and two rows that look like the same machine are not.
	line=$($SSH "$h" "/tmp/bench.sh -N $h -r $REND -W $W -H $H -f $FRAMES -n $RUNS -w $WARMUPS -t $TIMEOUT -m $MAP -s $SCREENMODE -x '$EXTRA' -A '$LAUNCHARGS'" 2>/tmp/fleet_${h}.err)
	# bench.sh emits an ERR row rather than a number when its own assertions fail.
	# Surface the reason here: an ERR row that scrolls past unexplained is how a
	# broken harness gets mistaken for a broken build.
	case "$line" in
		*,ERR,ERR,ERR,*)
			echo "  [$h] !! BENCH FAILED, no number produced:" >&2
			sed 's/^/  [/'"$h"'] /' /tmp/fleet_${h}.err >&2
			;;
	esac
	if [ -n "$line" ]; then
		# bench.sh writes the mode it actually ran in field 4 of its CSV line, so
		# the row is always honest about the run. If it disagrees with what we
		# asked for, the request was lost somewhere between here and the engine:
		# say so loudly rather than banking a row nobody asked for.
		ran=$(echo "$line" | cut -d, -f4)
		if [ "$ran" != "$SCREENMODE" ]; then
			echo "  [$h] !! SCREENMODE MISMATCH: asked for '$SCREENMODE', bench.sh ran '$ran'" >&2
			echo "  [$h] !! the row below is recorded as '$ran'; it is NOT a '$SCREENMODE' measurement" >&2
		fi
		echo "$TS,$LABEL,$line" >> "$CSV"
		echo "  $line"
	else
		echo "  [$h] no result (see /tmp/fleet_${h}.err)" >&2
	fi
	# Hand the machine back straight away rather than at the end of the sweep, so
	# a long fleet run does not hold every box it has already finished with.
	if [ -x "$PICK" ]; then
		"$PICK" --release "$h" >/dev/null 2>&1
		# Drop $h from HELD by exact token. Not sed: BSD sed has no \b, so a
		# word-boundary pattern silently never matches and HELD only ever grows.
		_kept=""
		for _r in $HELD; do [ "$_r" = "$h" ] || _kept="$_kept $_r"; done
		HELD="$_kept"
	fi
done

echo "== done. appended to $CSV =="
column -s, -t "$CSV" 2>/dev/null | tail -n +1 | tail -20 || tail -20 "$CSV"
