#!/usr/bin/env bash
# uninstall.sh - reverse everything setup.sh did.
#
# Two of the artifacts are genuinely sensitive and are handled separately, with
# a prompt each:
#
#   creds   holds the vCenter password in cleartext
#   map.db  maps every token back to a real name, so it de-anonymises every
#           report the wrapper ever produced
#
# Both are overwritten before unlinking rather than just deleted.
#
# Usage:
#   ./uninstall.sh              prompt before removing the sensitive files
#   ./uninstall.sh --purge      remove everything, no prompts
#   ./uninstall.sh --keep-data  remove tooling only; leave creds and map.db
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${GOVC_SAFE_BIN_DIR:-$HOME/.local/bin}"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/govc-safe"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/govc-safe"
SKILLS="$HOME/.claude/skills"
SETTINGS="$HOME/.claude/settings.json"
PURGE=0
KEEP_DATA=0

while [ $# -gt 0 ]; do
    case "$1" in
        --purge)     PURGE=1 ;;
        --keep-data) KEEP_DATA=1 ;;
        --project)   SETTINGS="$PWD/.claude/settings.json" ;;
        --settings)  SETTINGS="${2:?--settings needs a path}"; shift ;;
        -h|--help)   sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
    shift
done

# Overwrite before unlinking. Not a guarantee on a journalling or COW filesystem
# or on SSD wear-levelled storage, but better than leaving the password intact
# in a freed block.
shred_file() {
    [ -f "$1" ] || return 0
    if command -v shred >/dev/null 2>&1; then
        shred -u "$1" 2>/dev/null || rm -f "$1"
    else
        dd if=/dev/urandom of="$1" bs=1k count=4 conv=notrunc 2>/dev/null || true
        rm -f "$1"
    fi
    echo "  removed $1"
}

confirm() {
    [ "$PURGE" -eq 1 ] && return 0
    printf '  %s [y/N]: ' "$1" >&2
    read -r a
    case "$a" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

echo "[..] unwiring hooks from $SETTINGS"
if [ -f "$SETTINGS" ]; then
    python3 "$SRC/settings-merge.py" --remove "$SETTINGS" || true
else
    echo "  no settings file there - nothing to unwire"
fi

echo "[..] removing tooling"
for f in "$BIN_DIR/govc-safe" "$BIN_DIR/govc-guard.py"; do
    [ -e "$f" ] && { rm -f "$f"; echo "  removed $f"; } || true
done
[ -d "$SKILLS/govc-private" ] && { rm -rf "$SKILLS/govc-private"; echo "  removed $SKILLS/govc-private"; } || true

if [ "$KEEP_DATA" -eq 1 ]; then
    echo "[--] --keep-data: leaving credentials and token map in place"
else
    echo "[..] sensitive data"
    if confirm "remove the credentials file ($CFG_DIR/creds)?"; then
        shred_file "$CFG_DIR/creds"
        rmdir "$CFG_DIR" 2>/dev/null && echo "  removed $CFG_DIR" || true
    fi
    if confirm "remove the token map ($DATA_DIR/map.db)? it de-anonymises past reports"; then
        for f in "$DATA_DIR/map.db" "$DATA_DIR/map.db-wal" "$DATA_DIR/map.db-shm"; do
            shred_file "$f"
        done
        rmdir "$DATA_DIR" 2>/dev/null && echo "  removed $DATA_DIR" || true
    fi
    # Not created by setup.sh, but govc puts a live session token here because
    # the wrapper sets HOME when it shells out.
    if [ -d "$HOME/.govmomi" ] && confirm "remove ~/.govmomi (cached vCenter session tokens)?"; then
        rm -rf "$HOME/.govmomi"; echo "  removed $HOME/.govmomi"
    fi
fi

echo
echo "[ok] uninstalled. Restart Claude Code so it reloads settings."
echo "     govc itself was not touched - only the wrapper around it."
