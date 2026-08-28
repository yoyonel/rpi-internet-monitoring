#!/usr/bin/env bash
# Restore an RPi backup into the running sim stack.
# Auto-detects backup type: InfluxDB (influxdb-backup/) or VictoriaMetrics (vm-snapshot/).
#
# Usage: bash scripts/sim-restore-backup.sh <backup-dir>
#   e.g.: bash scripts/sim-restore-backup.sh backups-rpi/20260416-205640
#
# Prerequisites:
#   - Sim stack must be running with the appropriate backend
#   - Backup dir must contain influxdb-backup/ and/or vm-snapshot/
#
# What it does:
#   For InfluxDB backups:
#     1. Validates influxdb-backup/ structure
#     2. Drops existing speedtest/telegraf databases
#     3. Copies backup into container + influxd restore -portable
#     4. Re-grants permissions to telegraf user
#   For VictoriaMetrics backups:
#     1. Validates vm-snapshot/ structure
#     2. Stops VictoriaMetrics, clears storage
#     3. Copies snapshot data into container volume
#     4. Restarts VictoriaMetrics
#   Optionally imports Grafana dashboards from the backup
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

_is_container_running() {
    local name="$1"
    [[ "$("$DOCKER" inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]
}

INFLUX_CONTAINER="rpi-sim-influxdb"
VM_CONTAINER="rpi-sim-victoriametrics"

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

HAS_INFLUX=false
HAS_VM=false
[[ -d "$BACKUP_DIR/influxdb-backup" ]] && HAS_INFLUX=true
[[ -d "$BACKUP_DIR/vm-snapshot" ]] && HAS_VM=true

if ! $HAS_INFLUX && ! $HAS_VM; then
    echo "  ❌ No TSDB backup found (neither influxdb-backup/ nor vm-snapshot/)"
    exit 1
fi

if $HAS_INFLUX; then
    MANIFEST_COUNT=$(find "$BACKUP_DIR/influxdb-backup" -name '*.manifest' | wc -l)
    SHARD_COUNT=$(find "$BACKUP_DIR/influxdb-backup" -name '*.tar.gz' | wc -l)
    echo "  ✅ InfluxDB backup: $MANIFEST_COUNT manifests, $SHARD_COUNT shards"
fi

if $HAS_VM; then
    VM_SNAP_DIR="$BACKUP_DIR/vm-snapshot"
    VM_SNAP_SUB=$(find "$VM_SNAP_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [[ -n "$VM_SNAP_SUB" ]]; then
        VM_FILE_COUNT=$(find "$VM_SNAP_SUB" -type f | wc -l)
        echo "  ✅ VM snapshot: $(basename "$VM_SNAP_SUB") ($VM_FILE_COUNT files)"
    else
        echo "  ⚠️  vm-snapshot/ is empty"
        HAS_VM=false
    fi
fi

DASHBOARD_COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -name 'dashboard-*.json' | wc -l)
if [[ "$DASHBOARD_COUNT" -gt 0 ]]; then
    echo "     Dashboards: $DASHBOARD_COUNT JSON files"
fi

# ── 2. Check sim stack is running ────────────────────────
echo ""
echo "── 2. Check sim stack ──"

if $HAS_INFLUX && _is_container_running "$INFLUX_CONTAINER"; then
    echo "  ✅ $INFLUX_CONTAINER is running"
    # Wait for InfluxDB to be healthy
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
    RESTORE_INFLUX=true
elif $HAS_INFLUX; then
    echo "  ⊘ InfluxDB container not running — skipping InfluxDB restore"
    RESTORE_INFLUX=false
else
    RESTORE_INFLUX=false
fi

if $HAS_VM && _is_container_running "$VM_CONTAINER"; then
    echo "  ✅ $VM_CONTAINER is running"
    RESTORE_VM=true
elif $HAS_VM; then
    # VM container must exist (even if stopped) for docker cp
    if "$DOCKER" inspect "$VM_CONTAINER" >/dev/null 2>&1; then
        echo "  ⚠️  $VM_CONTAINER exists but is stopped (will restart for restore)"
        RESTORE_VM=true
    else
        echo "  ❌ $VM_CONTAINER not found — cannot restore VM snapshot"
        RESTORE_VM=false
    fi
else
    RESTORE_VM=false
fi

if ! $RESTORE_INFLUX && ! $RESTORE_VM; then
    echo "  ❌ No matching backend running for this backup"
    exit 1
fi

# ── 3. Restore InfluxDB (if applicable) ─────────────────
if $RESTORE_INFLUX; then
    echo ""
    echo "── 3. Restore InfluxDB ──"

    echo "  Dropping existing databases..."
    for db in speedtest telegraf; do
        curl -sf -XPOST "http://localhost:8086/query?u=${INFLUX_USER}&p=${INFLUX_PASS}" \
            --data-urlencode "q=DROP DATABASE $db" >/dev/null 2>&1 || true
        echo "  → Dropped '$db' (if existed)"
    done

    echo "  Copying backup into container..."
    "$DOCKER" exec "$INFLUX_CONTAINER" rm -rf /tmp/influxdb-restore 2>/dev/null || true
    "$DOCKER" cp "$BACKUP_DIR/influxdb-backup" "$INFLUX_CONTAINER:/tmp/influxdb-restore"
    echo "  ✅ Copied influxdb-backup/ → $INFLUX_CONTAINER:/tmp/influxdb-restore"

    echo "  Restoring (portable)..."
    "$DOCKER" exec "$INFLUX_CONTAINER" influxd restore -portable /tmp/influxdb-restore
    echo "  ✅ influxd restore completed"

    echo "  Re-granting permissions..."
    for db in speedtest telegraf; do
        curl -sf -XPOST "http://localhost:8086/query?u=${INFLUX_USER}&p=${INFLUX_PASS}" \
            --data-urlencode "q=GRANT ALL ON $db TO \"telegraf\"" >/dev/null 2>&1 || true
        echo "  → GRANT ALL ON $db TO telegraf"
    done

    "$DOCKER" exec "$INFLUX_CONTAINER" rm -rf /tmp/influxdb-restore
fi

# ── 4. Restore VictoriaMetrics (if applicable) ──────────
if $RESTORE_VM; then
    echo ""
    echo "── 4. Restore VictoriaMetrics ──"

    VM_SNAP_DIR="$BACKUP_DIR/vm-snapshot"
    VM_SNAP_SUB=$(find "$VM_SNAP_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)

    # Stop VM to replace storage safely
    echo "  Stopping VictoriaMetrics..."
    "$DOCKER" stop "$VM_CONTAINER" 2>/dev/null || true

    # Tar the snapshot locally, copy into container, extract over storage
    echo "  Preparing restore archive..."
    tar -cf /tmp/vm-restore.tar -C "$VM_SNAP_SUB" .
    "$DOCKER" cp /tmp/vm-restore.tar "$VM_CONTAINER:/tmp/vm-restore.tar"
    rm -f /tmp/vm-restore.tar

    # Start container briefly just for exec (VM will restart later)
    "$DOCKER" start "$VM_CONTAINER" 2>/dev/null || true
    # Wait a moment for container to be ready for exec
    sleep 2

    # Clear existing data and extract backup
    echo "  Replacing storage data..."
    "$DOCKER" exec "$VM_CONTAINER" sh -c '
        rm -rf /storage/data/big /storage/data/small /storage/data/indexdb
        mkdir -p /storage/data
        tar -xf /tmp/vm-restore.tar -C /storage/
        rm -f /tmp/vm-restore.tar
    '

    # Restart VM to pick up new data
    echo "  Restarting VictoriaMetrics..."
    "$DOCKER" restart "$VM_CONTAINER"

    # Wait for health
    echo "  ⏳ Waiting for VictoriaMetrics to be healthy..."
    for i in $(seq 1 24); do
        if curl -sf "http://localhost:8428/health" >/dev/null 2>&1; then
            echo "  ✅ VictoriaMetrics is healthy"
            break
        fi
        if [[ "$i" -eq 24 ]]; then
            echo "  ❌ VictoriaMetrics not healthy after 120s"
            exit 1
        fi
        sleep 5
    done
fi

# ── 5. Import Grafana dashboards (if present) ────────────
if [[ "$DASHBOARD_COUNT" -gt 0 ]]; then
    echo ""
    echo "── 5. Import Grafana dashboards ──"

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
