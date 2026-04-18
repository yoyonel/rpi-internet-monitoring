#!/usr/bin/env bash
# Backup Grafana dashboards, datasources, and InfluxDB data.
# Creates a timestamped directory under backups/.
set -euo pipefail
DOCKER=${CONTAINER_CLI:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$SCRIPT_DIR/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Load credentials from .env
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    GF_SECURITY_ADMIN_USER=$(grep '^GF_SECURITY_ADMIN_USER=' "$SCRIPT_DIR/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    GF_SECURITY_ADMIN_PASSWORD=$(grep '^GF_SECURITY_ADMIN_PASSWORD=' "$SCRIPT_DIR/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
fi
GRAFANA_CREDS="${GF_SECURITY_ADMIN_USER:-admin}:${GF_SECURITY_ADMIN_PASSWORD:?GF_SECURITY_ADMIN_PASSWORD not set in .env}"
GRAFANA_URL="http://localhost:3000"
# Helper: pass creds via process substitution (not visible in /proc cmdline)
_gcurl() { curl -sf -K <(printf 'user = "%s"\n' "$GRAFANA_CREDS") "$@"; }

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
