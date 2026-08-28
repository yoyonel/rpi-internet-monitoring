#!/usr/bin/env bash
# Full backup test pipeline: nuke → start fresh → wait healthy → restore → verify.
# Usage: sim-test-backup.sh <backup_dir> <compose_command>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${1:?Usage: sim-test-backup.sh <backup_dir> <compose_command...>}"
shift
COMPOSE=("$@")

echo "── Step 0/5: Offline integrity check ──"
bash "$SCRIPT_DIR/scripts/backup-check.sh" "$DIR"
echo ""

echo "── Step 1/5: Nuke sim stack ──"
"${COMPOSE[@]}" down -v 2>/dev/null || true
echo ""

echo "── Step 2/5: Start fresh sim stack ──"
"${COMPOSE[@]}" up -d
echo ""

echo "── Step 3/5: Wait for TSDB healthy ──"
# Try InfluxDB first, then VictoriaMetrics
if curl -sf "http://localhost:8086/ping" >/dev/null 2>&1 || [[ -n "${INFLUXDB_ADMIN_PASSWORD:-}" ]]; then
    bash "$SCRIPT_DIR/scripts/wait-for-health.sh" "http://localhost:8086/ping" "InfluxDB" 300
elif curl -sf "http://localhost:8428/health" >/dev/null 2>&1; then
    bash "$SCRIPT_DIR/scripts/wait-for-health.sh" "http://localhost:8428/health" "VictoriaMetrics" 120
else
    # Neither is up yet, wait for whichever comes first
    echo "Waiting for any TSDB backend..."
    ELAPSED=0
    while true; do
        if curl -sf "http://localhost:8086/ping" >/dev/null 2>&1; then
            echo "  InfluxDB healthy after ~${ELAPSED}s ✓"
            break
        fi
        if curl -sf "http://localhost:8428/health" >/dev/null 2>&1; then
            echo "  VictoriaMetrics healthy after ~${ELAPSED}s ✓"
            break
        fi
        ELAPSED=$((ELAPSED + 5))
        if [[ "$ELAPSED" -ge 300 ]]; then
            echo "  No TSDB backend responded within 300s ✗"
            exit 1
        fi
        sleep 5
    done
fi
echo ""

echo "── Step 4/5: Restore ──"
bash "$SCRIPT_DIR/scripts/sim-restore-backup.sh" "$DIR"
echo ""

echo "── Step 5/5: Verify ──"
bash "$SCRIPT_DIR/scripts/sim-verify-backup.sh"
