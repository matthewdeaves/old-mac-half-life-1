#!/bin/bash
# Verify deploy-dmg's bounded early-stage diagnostics without a fleet host.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t hl-deploy-stages)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

cat > "$TMP/ssh" <<'SH'
#!/bin/sh
case "${MOCK_FAIL:-}" in
  mkdir) case "$*" in *'mkdir -p ~/Desktop'*) exit 23;; esac ;;
  list) case "$*" in *'ls -1 ~/Desktop/Half-Life-OldMac-'*) exit 24;; esac ;;
  md5) case "$*" in *"md5 'Desktop/Half-Life-OldMac-v1.9.18.dmg'"*) exit 26;; esac ;;
esac
exit 0
SH
cat > "$TMP/scp" <<'SH'
#!/bin/sh
[ "${MOCK_FAIL:-}" = scp ] && exit 25
exit 0
SH
chmod +x "$TMP/ssh" "$TMP/scp"

expect_fail() {
  kind="$1" code="$2" label="$3"
  log="$TMP/$kind.log"
  if PATH="$TMP:$PATH" MOCK_FAIL="$kind" BENCH_NO_LOCK=1 \
      bash "$ROOT/scripts/deploy-dmg.sh" fixture v1.9.18 >"$log" 2>&1; then
    echo "expected $kind fixture to fail" >&2; exit 1
  else
    got=$?
  fi
  [ "$got" = "$code" ] || { echo "$kind exit $got, expected $code" >&2; exit 1; }
  grep -F "FATAL: $label failed (exit $code)" "$log" >/dev/null || {
    echo "missing stage label for $kind" >&2; cat "$log" >&2; exit 1; }
}

expect_fail mkdir 23 "create target Desktop"
expect_fail list 24 "list prior release DMGs"
expect_fail scp 25 "copy candidate DMG"
expect_fail md5 26 "read target DMG checksum"
echo "deploy stage fixtures: exact failures reported"
