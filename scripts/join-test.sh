#!/usr/bin/env bash
# Real-client join test: launch the DMG-installed Half-Life.app exactly as a
# human would (open -> LaunchServices, same as smoke-dmg.sh), and drive the
# connect through a throwaway valve/autoexec.cfg rather than `open --args`.
# `open --args` does not exist on the PowerPC floor: 10.4.11's `open` treats
# an unrecognized flag as a filename ("No such file: ~/--args"), measured on
# yosemite-tiger - so any fleet-wide join test has to go through a config the
# engine execs on its own, the same reason userconfig.cfg drives the other
# headless fleet tests (see docs/BENCHMARKING.md). autoexec.cfg does not ship
# and is never created by any of our own tooling, so it is always safe to
# write and remove: back it up only if a player somehow already has one.
#
# This is a cousin of smoke-dmg.sh, not a replacement: smoke proves the
# production path comes up at all, this proves it can actually join a real
# server across the WAN, which is what a release needs from every
# architecture class, oldest first.
#
# The server address is NEVER hardcoded here or in any commit: infra's
# hosting details do not belong in a public port repo (CLAUDE.md, "Private
# infra details never enter public port repos"). Pass it on the command line
# each time; nothing here remembers it between runs.
#
# usage: scripts/join-test.sh <machine> <server_addr>
#   machine:     same aliases as smoke-dmg.sh
#   server_addr: ip:port, given to you out of band (never committed)
set -euo pipefail
HOST="${1:?usage: $0 <machine> <server_addr>}"
ADDR="${2:?usage: $0 <machine> <server_addr>}"

# Same claim pattern as deploy-dmg.sh/smoke-dmg.sh: see those for the reasoning.
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" --run "$HOST" "join-test" -- "$0" "$@"
fi
DEST_DIR="${DEST_DIR:-/Applications/Half-Life}"
# Seconds the client must stay in the game after loading the map.
HOLD="${HOLD:-60}"
# VOICE=0 (the default) turns voice chat off for this run only. The server's
# svc_voiceinit makes the client open the microphone mid-connect, and on a
# 10.14+ host whose TCC grant does not match this build's ad-hoc signature
# that open blocks on a permission prompt with nobody there to answer it:
# measured on imac-2019 2026-09-22, the log stops at "voice: before capture
# open" and never loads the map. That is a headless-method confound, not a
# server fault. voice_enable is FCVAR_ARCHIVE, so config.cfg is backed up and
# put back afterwards. VOICE=1 keeps the player's own voice setting.
VOICE="${VOICE:-0}"

case "$HOST" in
	workstation) LOCAL=1 ;;
	*)           LOCAL=0 ;;
esac

# Same per-class timing as smoke-dmg.sh, plus the WAN round trip: a real
# connect handshake needs a few seconds longer than the local production
# launch smoke-dmg.sh times, so TIMEOUT here is not copy-pasted from there.
case "$HOST" in
  yosemite|yosemite-tiger|g3-panther|g3-tiger)              TIMEOUT=100 ;;
  sawtooth|quicksilver|mini-g4)                             TIMEOUT=70 ;;
  imac-g5|g5-imac|g5-panther|g5-tiger|g5-leopard|g5-desktop|quad-tiger|quad-leopard) TIMEOUT=70 ;;
  mini-intel|mini-intel2)                                   TIMEOUT=50 ;;
  mini-sl|snow-build1)                                      TIMEOUT=50 ;;
  imac-2019|imac|sequoia-build)                             TIMEOUT=50 ;;
  workstation)                                              TIMEOUT=50 ;;
  *) echo "unknown machine: $HOST" >&2; exit 2 ;;
esac
TIMEOUT="${JOIN_TIMEOUT:-$TIMEOUT}"

echo "[join-test $HOST] launching DMG-installed Half-Life.app via LaunchServices, connect $ADDR, hold ${HOLD}s"
JOIN_SCRIPT=$(cat <<'REMOTE_EOF'
set -u
case "$1" in
  /*) DEST="$1" ;;
  *)  DEST="$HOME/$1" ;;
esac
ADDR="$2"; TIMEOUT="$3"; HOLD="${4:-60}"; VOICE="${5:-0}"
BUNDLE="$DEST/Half-Life.app"
APP="$BUNDLE/Contents/MacOS/xash3d"
LOG="$DEST/last-run.log"

[ -x "$APP" ] || { echo "NO_INSTALL"; exit 0; }
[ -f "$DEST/valve/pak0.pak" ] || { echo "NO_DATA"; exit 0; }

killall -TERM xash3d.bin 2>/dev/null || true; sleep 1
killall -KILL xash3d.bin 2>/dev/null || true
[ -f "$LOG" ] && mv -f "$LOG" "$DEST/last-run.prev.log" 2>/dev/null || true
rm -f "$LOG"

# autoexec.cfg never ships and nothing of ours creates one, so it is always
# safe to write - but back it up on the rare chance the player already has
# one, and restore it (or remove ours) no matter how this exits.
AUTOEXEC="$DEST/valve/autoexec.cfg"
HAD_AUTOEXEC=0
if [ -f "$AUTOEXEC" ]; then
	HAD_AUTOEXEC=1
	mv "$AUTOEXEC" "$AUTOEXEC.join-test-backup"
fi
CONFIG="$DEST/valve/config.cfg"
HAD_CONFIG=0
if [ "$VOICE" = 0 ] && [ -f "$CONFIG" ]; then
	HAD_CONFIG=1
	cp -p "$CONFIG" "$CONFIG.join-test-backup"
fi
restore_autoexec() {
	if [ "$HAD_AUTOEXEC" = 1 ]; then
		mv -f "$AUTOEXEC.join-test-backup" "$AUTOEXEC"
	else
		rm -f "$AUTOEXEC"
	fi
	[ "$HAD_CONFIG" = 1 ] && mv -f "$CONFIG.join-test-backup" "$CONFIG"
	return 0
}
trap restore_autoexec EXIT
{
	[ "$VOICE" = 0 ] && echo "voice_enable 0"
	echo "connect $ADDR"
} > "$AUTOEXEC"
echo "VOICE=$VOICE"

# What infra needs to match this run against the server journal: the engines
# do not log the client's address, so time and binary identify the row.
echo "CLIENT=$(hostname) $(uname -m) $(sw_vers -productVersion 2>/dev/null)"
echo "BINARY_MD5=$(md5 -q "$BUNDLE/Contents/MacOS/xash3d.bin" 2>/dev/null)"
echo "LAUNCH_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

OPEN_ERR=$(open "$BUNDLE" 2>&1 >/dev/null) || { echo "OPEN_REJECTED"; echo "OPENERR=$OPEN_ERR"; exit 0; }

# Two phases, like smoke-dmg.sh: `open` only REQUESTS the launch and returns
# immediately, so the process can take a few seconds (longer on PowerPC) to
# actually appear. Checking liveness before it has ever appeared is not the
# same as it dying - conflating the two into one loop declared a G3 that
# simply had not started yet as DIED on the first iteration, before it had
# even reached GL init. Phase 1 waits for the PID to exist at all; only once
# it has do phase 2 treat that PID going away as a real death.
PID=""
i=0
while [ "$i" -lt "$TIMEOUT" ]; do
  PID=$(ps -axww | grep -F "xash3d.bin" | grep -v grep | awk '{print $1; exit}')
  [ -n "$PID" ] && break
  sleep 1; i=$((i+1))
done

# The client log cannot show a spawn, so this does not claim one. "Server
# info" and "Setting up renderer" used to count as JOINED, which is how every
# Half-Life row on retro-server-infra#27 came back "info only". Measured
# 2026-09-22 on imac-g5: a client that the user then played in, in the level
# with mouse look, logged nothing at all after the voice-capture lines, and
# the "has joined the game" broadcast did not appear in the joining client's
# own console in any run (imac-g5, mini-sl). So: CONNECTED is the client parsing the server's serverdata
# ("BUILD n SERVER"), then the client must stay alive for HOLD seconds with no
# drop or timeout in its log. The spawn itself is confirmed from the server's
# journal for the printed UTC window, which is why a clean hold exits 3
# ("confirm server-side"), never 0.
FAILPAT='Connection failed|Server is not responding|Bad Response|Connection timed out|Server connection timed out|Refused by Server|Server issued disconnect|Server disconnected'
utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
RESULT=""
if [ -z "$PID" ]; then
  RESULT="NEVER_STARTED"
else
  while [ "$i" -lt "$TIMEOUT" ]; do
    if grep -aqE 'BUILD -?[0-9]+ SERVER' "$LOG" 2>/dev/null; then
      echo "CONNECTED_UTC=$(utc)"; RESULT="CONNECTED"; break
    fi
    if grep -aqE "$FAILPAT" "$LOG" 2>/dev/null; then
      RESULT="REFUSED"; break
    fi
    kill -0 "$PID" 2>/dev/null || { RESULT="DIED"; break; }
    sleep 1; i=$((i+1))
  done
  [ -z "$RESULT" ] && RESULT="TIMEOUT"
fi

if [ "$RESULT" = CONNECTED ]; then
  h=0
  while [ "$h" -lt "$HOLD" ]; do
    kill -0 "$PID" 2>/dev/null || { RESULT="DIED_IN_GAME"; break; }
    if grep -aqE "$FAILPAT" "$LOG" 2>/dev/null; then RESULT="DROPPED"; break; fi
    sleep 1; h=$((h+1))
  done
  [ "$RESULT" = CONNECTED ] && RESULT="HELD"
  echo "HELD_SECONDS=$h"
fi

echo "QUIT_UTC=$(utc)"
killall -TERM xash3d.bin 2>/dev/null || true; sleep 2
killall -KILL xash3d.bin 2>/dev/null || true

echo "RESULT=$RESULT"
echo "----LOGTAIL----"
[ -f "$LOG" ] && tail -25 "$LOG" 2>/dev/null || true
REMOTE_EOF
)

if [ "$LOCAL" = 1 ]; then
	RAW=$(bash -s "$DEST_DIR" "$ADDR" "$TIMEOUT" "$HOLD" "$VOICE" <<<"$JOIN_SCRIPT")
else
	RAW=$(ssh "$HOST" bash -s "$DEST_DIR" "$ADDR" "$TIMEOUT" "$HOLD" "$VOICE" <<<"$JOIN_SCRIPT")
fi

echo "$RAW" | sed 's/^/  /'

case "$RAW" in
  NO_INSTALL*)    echo "[join-test $HOST] FAIL - Half-Life.app not installed"; exit 1 ;;
  NO_DATA*)       echo "[join-test $HOST] FAIL - no valve/pak0.pak"; exit 1 ;;
  *OPEN_REJECTED*) echo "[join-test $HOST] FAIL - LaunchServices refused the launch"; exit 1 ;;
esac

RESULT=$(printf '%s\n' "$RAW" | sed -n 's/^RESULT=\(.*\)/\1/p' | head -1)
case "$RESULT" in
  HELD)          echo "[join-test $HOST] CONNECTED and held ${HOLD}s with no drop - spawn NOT shown client-side: confirm from the server journal for the UTC window above"; exit 3 ;;
  DROPPED)       echo "[join-test $HOST] FAIL - connected, then the connection dropped"; exit 1 ;;
  DIED_IN_GAME)  echo "[join-test $HOST] FAIL - connected, then the engine exited"; exit 1 ;;
  REFUSED)       echo "[join-test $HOST] FAIL - server refused/rejected the connection"; exit 1 ;;
  DIED)          echo "[join-test $HOST] FAIL - engine exited before joining"; exit 1 ;;
  NEVER_STARTED) echo "[join-test $HOST] FAIL - process never appeared within ${TIMEOUT}s of the launch request"; exit 1 ;;
  *)       echo "[join-test $HOST] FAIL - no join confirmation within ${TIMEOUT}s"; exit 1 ;;
esac
