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

while getopts "l:r:W:H:f:n:w:t:m:s:" opt; do
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
		*) echo "usage: fleet-bench.sh [-l label] [-r gl|soft] [-W w] [-H h] [-f frames] [-n runs] [-w warmups] [-t timeout] [-m map] [-s fullscreen|borderless|windowed] [host ...]" >&2; exit 2 ;;
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

for h in $HOSTS; do
	if ! $SSH "$h" true 2>/dev/null; then
		echo "  [$h] unreachable - skipped" >&2
		continue
	fi
	# ship the latest bench.sh
	$SCP "$BENCH_SH" "$h:/tmp/bench.sh" >/dev/null 2>&1
	$SSH "$h" 'chmod +x /tmp/bench.sh' 2>/dev/null
	# run it; bench.sh prints one CSV line on stdout (and notes on stderr)
	line=$($SSH "$h" "/tmp/bench.sh -r $REND -W $W -H $H -f $FRAMES -n $RUNS -w $WARMUPS -t $TIMEOUT -m $MAP -s $SCREENMODE" 2>/tmp/fleet_${h}.err)
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
done

echo "== done. appended to $CSV =="
column -s, -t "$CSV" 2>/dev/null | tail -n +1 | tail -20 || tail -20 "$CSV"
