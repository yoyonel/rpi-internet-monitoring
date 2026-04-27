#!/usr/bin/env bash
# Restore an RPi backup into the running sim stack.
#
# Usage: bash scripts/sim-restore-backup.sh <backup-dir>
#   e.g.: bash scripts/sim-restore-backup.sh backups-rpi/20260416-205640
#
# Prerequisites:
#   - Sim stack must be running (`just sim-up`) with InfluxDB healthy
#   - Backup dir must contain influxdb-backup/ and optionally dashboard-*.json
#
# What it does:
#   1. Validates the backup directory structure
#   2. Drops existing speedtest/telegraf databases in sim InfluxDB
#   3. Copies influxdb-backup/ into the container
#   4. Runs `influxd restore -portable` to restore both databases
#   5. Re-grants permissions to the telegraf user
#   6. Optionally imports Grafana dashboards from the backup
set -euo pipefail

# ── CLI ──────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <backup-dir>"
    echo "  e.g.: $0 backups-rpi/20260416-205640"
    exit 1
fi

BACKUP_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

# Resolve relative paths from project root
if [[ ! "$BACKUP_DIR" = /* ]]; then
    BACKUP_DIR="$PROJECT_DIR/$BACKUP_DIR"
fi

# ── Detect container CLI ─────────────────────────────────
detect_container_cli

INFLUX_CONTAINER="rpi-sim-influxdb"

# ── Read sim credentials ─────────────────────────────────
load_env "$PROJECT_DIR/sim/.env.sim"
INFLUX_USER=$(_read_env INFLUXDB_ADMIN_USER)
INFLUX_PASS=$(_read_env INFLUXDB_ADMIN_PASSWORD)
GRAFANA_URL="http://localhost:3000"
setup_grafana_auth

echo "╔══════════════════════════════════════════════════════════╗"
echo "║     Sim Stack — Restore RPi Backup                       ║"
echo "║     $(date -Iseconds)                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Validate backup dir ───────────────────────────────
echo "── 1. Validate backup ──"
if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "  ❌ Directory not found: $BACKUP_DIR"
    exit 1
fi
if [[ ! -d "$BACKUP_DIR/influxdb-backup" ]]; then
    echo "  ❌ No influxdb-backup/ subdirectory in $BACKUP_DIR"
    exit 1
fi
MANIFEST_COUNT=$(find "$BACKUP_DIR/influxdb-backup" -name '*.manifest' | wc -l)
SHARD_COUNT=$(find "$BACKUP_DIR/influxdb-backup" -name '*.tar.gz' | wc -l)
echo "  ✅ Backup dir: $BACKUP_DIR"
echo "     Manifests: $MANIFEST_COUNT, Shards: $SHARD_COUNT"

DASHBOARD_COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -name 'dashboard-*.json' | wc -l)
if [[ "$DASHBOARD_COUNT" -gt 0 ]]; then
    echo "     Dashboards: $DASHBOARD_COUNT JSON files"
fi

# ── 2. Check sim stack is running ────────────────────────
echo ""
echo "── 2. Check sim stack ──"
if ! "$DOCKER" inspect --format '{{.State.Running}}' "$INFLUX_CONTAINER" 2>/dev/null | grep -q 'true'; then
    echo "  ❌ Container $INFLUX_CONTAINER is not running. Run 'just sim-up' first."
    exit 1
fi
echo "  ✅ $INFLUX_CONTAINER is running"

# Wait for InfluxDB to be healthy (up to 60s for already-running stack)
echo "  ⏳ Waiting for InfluxDB to be healthy..."
for i in $(seq 1 12); do
    if curl -sf "http://localhost:8086/ping" >/dev/null 2>&1; then
        echo "  ✅ InfluxDB is healthy"
        break
    fi
    if [[ "$i" -eq 12 ]]; then
        echo "  ❌ InfluxDB not healthy after 60s"
        exit 1
    fi
    sleep 5
done

# ── 3. Drop existing databases ───────────────────────────
echo ""
echo "── 3. Drop existing databases ──"
for db in speedtest telegraf; do
    curl -sf -XPOST "http://localhost:8086/query?u=${INFLUX_USER}&p=${INFLUX_PASS}" \
        --data-urlencode "q=DROP DATABASE $db" >/dev/null 2>&1 || true
    echo "  → Dropped '$db' (if existed)"
done

# ── 4. Copy backup into container ────────────────────────
echo ""
echo "── 4. Copy backup into container ──"
"$DOCKER" exec "$INFLUX_CONTAINER" rm -rf /tmp/influxdb-restore 2>/dev/null || true
"$DOCKER" cp "$BACKUP_DIR/influxdb-backup" "$INFLUX_CONTAINER:/tmp/influxdb-restore"
echo "  ✅ Copied influxdb-backup/ → $INFLUX_CONTAINER:/tmp/influxdb-restore"

# ── 5. Restore InfluxDB ─────────────────────────────────
echo ""
echo "── 5. Restore InfluxDB (portable) ──"
"$DOCKER" exec "$INFLUX_CONTAINER" influxd restore -portable /tmp/influxdb-restore
echo "  ✅ influxd restore completed"

# ── 6. Re-grant permissions ──────────────────────────────
echo ""
echo "── 6. Re-grant permissions ──"
for db in speedtest telegraf; do
    curl -sf -XPOST "http://localhost:8086/query?u=${INFLUX_USER}&p=${INFLUX_PASS}" \
        --data-urlencode "q=GRANT ALL ON $db TO \"telegraf\"" >/dev/null 2>&1 || true
    echo "  → GRANT ALL ON $db TO telegraf"
done

# ── 7. Cleanup temp files in container ───────────────────
"$DOCKER" exec "$INFLUX_CONTAINER" rm -rf /tmp/influxdb-restore

# ── 8. Import Grafana dashboards (if present) ────────────
if [[ "$DASHBOARD_COUNT" -gt 0 ]]; then
    echo ""
    echo "── 7. Import Grafana dashboards ──"

    # Wait for Grafana to be ready
    for i in $(seq 1 12); do
        if _gcurl "$GRAFANA_URL/api/health" 2>/dev/null | jq -e '.database == "ok"' >/dev/null 2>&1; then
            break
        fi
        if [[ "$i" -eq 12 ]]; then
            echo "  ⚠️  Grafana not ready — skipping dashboard import"
            DASHBOARD_COUNT=0
            break
        fi
        sleep 5
    done

    if [[ "$DASHBOARD_COUNT" -gt 0 ]]; then
        for f in "$BACKUP_DIR"/dashboard-*.json; do
            TITLE=$(jq -r '.dashboard.title // "unknown"' "$f" 2>/dev/null)
            # Strip meta fields for import: set id=null.
            # Fix null datasources on speedtest panels: RPi backups may have
            # datasource=null (uses Grafana default), but in sim the default
            # points to telegraf, not speedtest. Patch them to use the explicit
            # InfluxDB-Speedtest datasource UID.
            PAYLOAD=$(jq '
              {
                dashboard: (
                  .dashboard
                  | .id = null
                  | .panels |= [.[] |
                      if .targets then
                        .targets |= [.[] |
                          if .measurement == "speedtest" and (.datasource == null or .datasource == "")
                          then .datasource = {"type": "influxdb", "uid": "influxdb-speedtest"}
                          else . end
                        ]
                        | if .datasource == null and any(.targets[]; .measurement == "speedtest")
                          then .datasource = {"type": "influxdb", "uid": "influxdb-speedtest"}
                          else . end
                      else . end
                    ]
                ),
                folderId: 0,
                overwrite: true
              }' "$f" 2>/dev/null)
            if [[ -n "$PAYLOAD" ]]; then
                RESULT=$(_gcurl -X POST -H "Content-Type: application/json" \
                    -d "$PAYLOAD" "$GRAFANA_URL/api/dashboards/db" 2>/dev/null || echo '{}')
                STATUS=$(echo "$RESULT" | jq -r '.status // "error"')
                if [[ "$STATUS" == "success" ]]; then
                    echo "  ✅ Imported: $TITLE"
                else
                    echo "  ⚠️  Import issue for '$TITLE': $(echo "$RESULT" | jq -r '.message // "unknown"')"
                fi
            fi
        done
    fi
fi

echo ""
echo "── Restore complete ──"
echo "  Backup: $(basename "$BACKUP_DIR")"
echo "  Run 'just sim-verify-backup' to validate data integrity."
