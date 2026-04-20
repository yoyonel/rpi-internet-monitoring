#!/usr/bin/env bash
# Rotate old backups, keeping the N most recent.
# Usage: backup-rotate.sh [N]  (default: 5)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUPS_ROOT="$SCRIPT_DIR/backups"
KEEP="${1:-5}"

mapfile -t ALL < <(find "$BACKUPS_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
echo "Found ${#ALL[@]} backup(s), keeping $KEEP"

if [[ ${#ALL[@]} -gt $KEEP ]]; then
    for old in "${ALL[@]:$KEEP}"; do
        echo "  🗑  Removing $old"
        rm -rf "${BACKUPS_ROOT:?}/$old"
    done
    echo "Pruned $((${#ALL[@]} - KEEP)) old backup(s)"
else
    echo "Nothing to prune"
fi
