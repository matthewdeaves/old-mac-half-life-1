#!/bin/sh
# deploy-rollback.sh - save and restore exactly the paths deploy-dmg.sh owns.
#
# The game folder is the player's.  A deployment may replace our bundles and
# remove the small set of pre-v1.2 runtime files that shadow those bundles, but
# it must never turn that into permission to copy or remove retail data, saves,
# mods, or arbitrary configuration.  This helper records the before-state of
# every path the deployer can touch and writes a self-contained RESTORE.sh.
set -eu

usage() {
	echo "usage: $0 root | backup DEST BACKUP LABEL | restore BACKUP DEST" >&2
	exit 2
}

owned_path() {
	case "$1" in
		"Half-Life.app"|"Half-Life Mods.app"|"Half-Life System Report.app"|\
		"valve/cl_dlls"|"valve/dlls"|"valve/userconfig.cfg"|\
		"valve/last-run.log"|"valve/gfx/shell/mods"|".DS_Store") return 0 ;;
		*) return 1 ;;
	esac
}

items() {
	cat <<'ITEMS'
Half-Life.app
Half-Life Mods.app
Half-Life System Report.app
valve/cl_dlls
valve/dlls
valve/userconfig.cfg
valve/last-run.log
valve/gfx/shell/mods
.DS_Store
ITEMS
}

default_root() {
	: "${HOME:?missing HOME}"
	printf '%s\n' "$HOME/oldmac/halflife/rollback"
}

backup() {
	DEST="$1" BACKUP="$2" LABEL="$3"
	[ ! -e "$BACKUP" ] || { echo "rollback destination already exists: $BACKUP" >&2; exit 1; }
	umask 077
	mkdir -p "$BACKUP/payload"
	: > "$BACKUP/manifest"
	printf 'label %s\nsource %s\n' "$LABEL" "$DEST" > "$BACKUP/INFO.txt"
	items | while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		if [ -e "$DEST/$rel" ] || [ -L "$DEST/$rel" ]; then
			mkdir -p "$BACKUP/payload/$(dirname "$rel")"
			ditto "$DEST/$rel" "$BACKUP/payload/$rel"
			printf 'present\t%s\n' "$rel" >> "$BACKUP/manifest"
		else
			printf 'absent\t%s\n' "$rel" >> "$BACKUP/manifest"
		fi
	done
	ditto "$0" "$BACKUP/deploy-rollback.sh"
	cat > "$BACKUP/RESTORE.sh" <<'RESTORE'
#!/bin/sh
# Restore the exact deploy-owned paths saved before this candidate promotion.
# Usage: ./RESTORE.sh /path/to/Half-Life
BASE="$(cd "$(dirname "$0")" && pwd)"
exec "$BASE/deploy-rollback.sh" restore "$BASE" "${1:?usage: $0 /path/to/Half-Life}"
RESTORE
	chmod 700 "$BACKUP/RESTORE.sh" "$BACKUP/deploy-rollback.sh"
	echo "rollback inventory: $BACKUP/manifest"
	echo "restore command: $BACKUP/RESTORE.sh '$DEST'"
}

preflight_restore() {
	BACKUP="$1"
	[ -f "$BACKUP/manifest" ] || { echo "missing rollback manifest: $BACKUP/manifest" >&2; exit 1; }
	while IFS="$(printf '\t')" read -r state rel; do
		owned_path "$rel" || { echo "refusing unowned rollback path: $rel" >&2; exit 1; }
		case "$state" in
			present)
				[ -e "$BACKUP/payload/$rel" ] || [ -L "$BACKUP/payload/$rel" ] || { echo "missing saved path: $rel" >&2; exit 1; }
				;;
			absent) ;;
			*) echo "bad rollback manifest state: $state" >&2; exit 1 ;;
		esac
	done < "$BACKUP/manifest"
}

restore() {
	BACKUP="$1" DEST="$2"
	# Validate every later input before the first rm -rf. An incomplete backup
	# must fail as a no-op, rather than leaving a half-restored player install.
	preflight_restore "$BACKUP"
	while IFS="$(printf '\t')" read -r state rel; do
		case "$state" in
			present)
				rm -rf "${DEST:?}/$rel"
				mkdir -p "$(dirname "${DEST:?}/$rel")"
				ditto "$BACKUP/payload/$rel" "${DEST:?}/$rel"
				;;
			absent) rm -rf "${DEST:?}/$rel" ;;
		esac
	done < "$BACKUP/manifest"
	echo "rollback restored into $DEST; retail valve data and mod directories were not touched"
}

case "${1:-}" in
	root) [ "$#" = 1 ] || usage; default_root ;;
	backup) [ "$#" = 4 ] || usage; backup "$2" "$3" "$4" ;;
	restore) [ "$#" = 3 ] || usage; restore "$2" "$3" ;;
	*) usage ;;
esac
