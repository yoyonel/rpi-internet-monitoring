#!/usr/bin/env bash
# Backup Grafana dashboards, datasources, and InfluxDB data.
# Creates a timestamped directory under backups/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/scripts/lib-common.sh"

detect_container_cli
load_env "$SCRIPT_DIR/.env"

BACKUPS_ROOT="$SCRIPT_DIR/backups"
BACKUP_DIR="$BACKUPS_ROOT/$(date +%Y%m%d-%H%M%S)"
BACKUP_KEEP="${BACKUP_KEEP:-5}"
mkdir -p "$BACKUP_DIR"

# Load credentials
GF_SECURITY_ADMIN_USER="${GF_SECURITY_ADMIN_USER:-$(_read_env GF_SECURITY_ADMIN_USER)}"
GF_SECURITY_ADMIN_PASSWORD="${GF_SECURITY_ADMIN_PASSWORD:-$(_read_env GF_SECURITY_ADMIN_PASSWORD)}"
GRAFANA_URL="http://localhost:3000"
setup_grafana_auth "$GF_SECURITY_ADMIN_USER" "$GF_SECURITY_ADMIN_PASSWORD"

echo "╔══════════════════════════════════════════╗"
echo "║         Backup — $(date -Iseconds)       "
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Grafana dashboards ──
echo "── Grafana dashboards ──"
UIDS=$(_gcurl "$GRAFANA_URL/api/search?type=dash-db" | jq -r '.[].uid')
for uid in $UIDS; do
    TITLE=$(_gcurl "$GRAFANA_URL/api/dashboards/uid/$uid" | jq -r '.dashboard.title // "unknown"')
    SAFE_TITLE=$(echo "$TITLE" | tr ' /' '_-')
    _gcurl "$GRAFANA_URL/api/dashboards/uid/$uid" | jq . >"$BACKUP_DIR/dashboard-${SAFE_TITLE}.json"
    echo "  → dashboard-${SAFE_TITLE}.json ($(wc -c <"$BACKUP_DIR/dashboard-${SAFE_TITLE}.json") bytes)"
done

# ── Grafana datasources ──
echo ""
echo "── Grafana datasources ──"
_gcurl "$GRAFANA_URL/api/datasources" | jq . >"$BACKUP_DIR/datasources.json"
echo "  → datasources.json ($(wc -c <"$BACKUP_DIR/datasources.json") bytes)"

# ── InfluxDB ──
echo ""
echo "── InfluxDB portable backup ──"
"$DOCKER" exec influxdb sh -c "rm -rf /tmp/backup && influxd backup -portable /tmp/backup" 2>&1
"$DOCKER" cp influxdb:/tmp/backup "$BACKUP_DIR/influxdb-backup"
"$DOCKER" exec influxdb rm -rf /tmp/backup
echo "  → influxdb-backup/ ($(du -sh "$BACKUP_DIR/influxdb-backup" | awk '{print $1}'))"

# ── Summary ──
echo ""
echo "── Summary ──"
echo "  Location: $BACKUP_DIR"
echo "  Total:    $(du -sh "$BACKUP_DIR" | awk '{print $1}')"
ls -lh "$BACKUP_DIR/"

# ── Rotation ──
# Keep the N most recent backups (BACKUP_KEEP, default 5), remove older ones.
mapfile -t ALL_BACKUPS < <(find "$BACKUPS_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
if [[ ${#ALL_BACKUPS[@]} -gt $BACKUP_KEEP ]]; then
    echo ""
    echo "── Rotation (keeping $BACKUP_KEEP most recent) ──"
    for old in "${ALL_BACKUPS[@]:$BACKUP_KEEP}"; do
        echo "  🗑  Removing $old"
        rm -rf "${BACKUPS_ROOT:?}/$old"
    done
    echo "  Pruned $((${#ALL_BACKUPS[@]} - BACKUP_KEEP)) old backup(s)"
else
    echo ""
    echo "── Rotation: ${#ALL_BACKUPS[@]}/$BACKUP_KEEP slots used, nothing to prune ──"
fi
