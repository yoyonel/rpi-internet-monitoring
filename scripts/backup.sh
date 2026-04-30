#!/usr/bin/env bash
# Backup Grafana dashboards, datasources, and TSDB data.
# Auto-detects running backends: InfluxDB, VictoriaMetrics, or both.
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

_is_container_running() {
    local name="$1"
    [[ "$("$DOCKER" inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]
}

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

# ── InfluxDB (if running) ──
if _is_container_running influxdb; then
    echo ""
    echo "── InfluxDB portable backup ──"
    "$DOCKER" exec influxdb sh -c "rm -rf /tmp/backup && influxd backup -portable /tmp/backup" 2>&1
    "$DOCKER" cp influxdb:/tmp/backup "$BACKUP_DIR/influxdb-backup"
    "$DOCKER" exec influxdb rm -rf /tmp/backup
    echo "  → influxdb-backup/ ($(du -sh "$BACKUP_DIR/influxdb-backup" | awk '{print $1}'))"
fi

# ── VictoriaMetrics (if running) ──
if _is_container_running victoriametrics; then
    echo ""
    echo "── VictoriaMetrics snapshot ──"
    VM_URL="${VICTORIA_METRICS_URL:-http://localhost:8428}"
    SNAP_RESP=$(curl -sf "$VM_URL/snapshot/create")
    SNAP_STATUS=$(echo "$SNAP_RESP" | jq -r '.status // "error"')
    if [[ "$SNAP_STATUS" == "ok" ]]; then
        SNAP_NAME=$(echo "$SNAP_RESP" | jq -r '.snapshot')
        echo "  Snapshot: $SNAP_NAME"
        # Tar inside the container to follow symlinks, then copy out
        "$DOCKER" exec victoriametrics tar -chf /tmp/vm-snapshot.tar -C "/storage/snapshots/$SNAP_NAME" .
        mkdir -p "$BACKUP_DIR/vm-snapshot/$SNAP_NAME"
        "$DOCKER" cp "victoriametrics:/tmp/vm-snapshot.tar" "$BACKUP_DIR/vm-snapshot/"
        tar -xf "$BACKUP_DIR/vm-snapshot/vm-snapshot.tar" -C "$BACKUP_DIR/vm-snapshot/$SNAP_NAME"
        rm -f "$BACKUP_DIR/vm-snapshot/vm-snapshot.tar"
        "$DOCKER" exec victoriametrics rm -f /tmp/vm-snapshot.tar
        echo "  → vm-snapshot/ ($(du -sh "$BACKUP_DIR/vm-snapshot" | awk '{print $1}'))"
        # Clean up snapshot inside VM to free resources
        curl -sf "$VM_URL/snapshot/delete?snapshot=$SNAP_NAME" >/dev/null 2>&1 || true
    else
        echo "  ⚠ Snapshot creation failed: $SNAP_RESP"
    fi
fi

# ── Summary ──
echo ""
echo "── Summary ──"
echo "  Location: $BACKUP_DIR"
echo "  Total:    $(du -sh "$BACKUP_DIR" | awk '{print $1}')"
ls -lh "$BACKUP_DIR/"

# ── Rotation ──
"$SCRIPT_DIR/scripts/backup-rotate.sh" "$BACKUP_KEEP"
