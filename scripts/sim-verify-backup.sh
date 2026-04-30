#!/usr/bin/env bash
# Verify that a backup restore in the sim stack produced valid data.
# Auto-detects backend: InfluxDB, VictoriaMetrics, or both.
#
# Usage: bash scripts/sim-verify-backup.sh
#
# Checks (InfluxDB):
#   1. Databases speedtest and telegraf exist
#   2. Count of download_bandwidth in speedtest
#   3. First/last measurement dates
#   4. Telegraf measurements
# Checks (VictoriaMetrics):
#   1. Metric names exist (speedtest_*, cpu_*)
#   2. Speedtest series count
#   3. Time range of data
# Common checks:
#   5. Grafana dashboards are loaded and accessible
#   6. Grafana datasource connectivity
#
# Exit code: 0 if all critical checks pass, 1 otherwise
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

# ── Detect container CLI ─────────────────────────────────
detect_container_cli

_is_container_running() {
    local name="$1"
    [[ "$("$DOCKER" inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]
}

INFLUX_CONTAINER="rpi-sim-influxdb"
VM_CONTAINER="rpi-sim-victoriametrics"
INFLUXDB_URL="http://localhost:8086"
VM_URL="http://localhost:8428"
GRAFANA_URL="http://localhost:3000"

# ── Read sim credentials ─────────────────────────────────
load_env "$PROJECT_DIR/sim/.env.sim"
INFLUX_USER=$(_read_env INFLUXDB_ADMIN_USER)
INFLUX_PASS=$(_read_env INFLUXDB_ADMIN_PASSWORD)
setup_grafana_auth

# Test harness provided by lib-common.sh (pass/fail/warn/test_summary)

influx_query() {
    local query="$1" database="${2:-}"
    curl -sfG \
        -u "${INFLUX_USER:-admin}:${INFLUX_PASS}" \
        --data-urlencode "q=$query" \
        ${database:+--data-urlencode "db=$database"} \
        "$INFLUXDB_URL/query"
}

vm_query() {
    local query="$1"
    curl -sf "$VM_URL/api/v1/query" --data-urlencode "query=$query"
}

echo "╔══════════════════════════════════════════════════════════╗"
echo "║     Sim Stack — Verify Backup Integrity                  ║"
echo "║     $(date -Iseconds)                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

HAS_INFLUX=false
HAS_VM=false
_is_container_running "$INFLUX_CONTAINER" && HAS_INFLUX=true
_is_container_running "$VM_CONTAINER" && HAS_VM=true

if ! $HAS_INFLUX && ! $HAS_VM; then
    echo "❌ No TSDB backend running"
    exit 1
fi

# ── InfluxDB checks ──────────────────────────────────────
if $HAS_INFLUX; then
    echo "══ InfluxDB Verification ══"
    echo ""

    # ── 1. Check databases exist ─────────────────────────────
    echo "── 1. Databases ──"
    DATABASES=$(influx_query "SHOW DATABASES" | jq -r '.results[]?.series[]?.values[]?[0] // empty')

    for db in speedtest telegraf; do
        if echo "$DATABASES" | grep -qx "$db"; then
            pass "Database '$db' exists"
        else
            fail "Database '$db' missing"
        fi
    done
    echo ""

    # ── 2. Speedtest data count ──────────────────────────────
    echo "── 2. Speedtest data count ──"
    COUNT_JSON=$(influx_query "SELECT COUNT(download_bandwidth) FROM speedtest" speedtest)
    COUNT=$(echo "$COUNT_JSON" | jq -r '.results[]?.series[]?.values[]?[1] // empty' | tail -1)

    if [[ -n "$COUNT" && "$COUNT" =~ ^[0-9]+$ ]]; then
        echo "  📊 download_bandwidth count: $COUNT"
        if [[ "$COUNT" -gt 100000 ]]; then
            pass "Count looks healthy (>100k points)"
        elif [[ "$COUNT" -gt 50000 ]]; then
            warn "Count is lower than expected ($COUNT, expected ~122k)"
        else
            fail "Count is too low ($COUNT, expected ~122k)"
        fi
    else
        fail "Could not query download_bandwidth count"
    fi
    echo ""

    # ── 3. Date range ────────────────────────────────────────
    echo "── 3. Date range ──"
    FIRST_JSON=$(influx_query "SELECT download_bandwidth FROM speedtest ORDER BY time ASC LIMIT 1" speedtest)
    FIRST_TIME=$(echo "$FIRST_JSON" | jq -r '.results[]?.series[]?.values[]?[0] // empty' | head -1)

    if [[ -n "$FIRST_TIME" ]]; then
        echo "  📅 First measurement: $FIRST_TIME"
        if [[ "$FIRST_TIME" == 2022* ]]; then
            pass "First measurement is in 2022"
        else
            warn "First measurement year unexpected: $FIRST_TIME"
        fi
    else
        fail "Could not query first measurement date"
    fi

    LAST_JSON=$(influx_query "SELECT download_bandwidth FROM speedtest ORDER BY time DESC LIMIT 1" speedtest)
    LAST_TIME=$(echo "$LAST_JSON" | jq -r '.results[]?.series[]?.values[]?[0] // empty' | head -1)

    if [[ -n "$LAST_TIME" ]]; then
        echo "  📅 Last measurement:  $LAST_TIME"
        if [[ "$LAST_TIME" == 2026* ]]; then
            pass "Last measurement is in 2026"
        else
            warn "Last measurement year unexpected: $LAST_TIME"
        fi
    else
        fail "Could not query last measurement date"
    fi
    echo ""

    # ── 4. Telegraf data ─────────────────────────────────────
    echo "── 4. Telegraf data ──"
    TELEGRAF_MEASUREMENTS=$(influx_query "SHOW MEASUREMENTS" telegraf | jq -r '.results[]?.series[]?.values[]?[0] // empty')
    TELEGRAF_COUNT=$(echo "$TELEGRAF_MEASUREMENTS" | wc -l)

    if [[ "$TELEGRAF_COUNT" -gt 0 && -n "$TELEGRAF_MEASUREMENTS" ]]; then
        pass "Telegraf has $TELEGRAF_COUNT measurement(s)"
        echo "     Measurements: $(echo "$TELEGRAF_MEASUREMENTS" | head -5 | tr '\n' ', ')..."
    else
        warn "Telegraf database has no measurements (may be normal if backup had none)"
    fi
    echo ""
fi

# ── VictoriaMetrics checks ──────────────────────────────
if $HAS_VM; then
    echo "══ VictoriaMetrics Verification ══"
    echo ""

    # ── VM 1. Metric names ───────────────────────────────────
    echo "── VM 1. Metric names ──"
    VM_METRICS=$(curl -sf "$VM_URL/api/v1/label/__name__/values" | jq -r '.data[]' 2>/dev/null)
    VM_METRIC_COUNT=$(echo "$VM_METRICS" | grep -c . 2>/dev/null || echo 0)

    if [[ "$VM_METRIC_COUNT" -gt 0 ]]; then
        pass "VictoriaMetrics has $VM_METRIC_COUNT metric(s)"
        echo "     Sample: $(echo "$VM_METRICS" | head -5 | tr '\n' ', ')..."
    else
        fail "No metrics found in VictoriaMetrics"
    fi
    echo ""

    # ── VM 2. Speedtest data ─────────────────────────────────
    echo "── VM 2. Speedtest data ──"
    # Check for speedtest metrics (may be speedtest_download_bandwidth or download_bandwidth)
    HAS_SPEEDTEST=false
    for metric in speedtest_download_bandwidth download_bandwidth; do
        VM_COUNT=$(vm_query "count($metric)" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
        if [[ "$VM_COUNT" != "0" && -n "$VM_COUNT" ]]; then
            pass "Speedtest metric '$metric' has $VM_COUNT series"
            HAS_SPEEDTEST=true
            break
        fi
    done
    if ! $HAS_SPEEDTEST; then
        # Check if any speedtest-related metric exists
        SPEEDTEST_METRICS=$(echo "$VM_METRICS" | grep -i speedtest || true)
        if [[ -n "$SPEEDTEST_METRICS" ]]; then
            warn "Speedtest metrics exist but have no data: $(echo "$SPEEDTEST_METRICS" | tr '\n' ', ')"
        else
            fail "No speedtest metrics found in VictoriaMetrics"
        fi
    fi
    echo ""

    # ── VM 3. CPU data (telegraf) ────────────────────────────
    echo "── VM 3. CPU/Telegraf data ──"
    HAS_CPU=false
    for metric in cpu_usage_idle usage_idle; do
        VM_CPU=$(vm_query "count($metric)" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
        if [[ "$VM_CPU" != "0" && -n "$VM_CPU" ]]; then
            pass "CPU metric '$metric' has $VM_CPU series"
            HAS_CPU=true
            break
        fi
    done
    if ! $HAS_CPU; then
        warn "No CPU idle metrics found (may be normal for speedtest-only backups)"
    fi
    echo ""
fi

# ── Grafana checks (common to both backends) ────────────
echo "── Grafana datasources ──"
DS_JSON=$(_gcurl "$GRAFANA_URL/api/datasources" 2>/dev/null || echo "[]")
DS_COUNT=$(echo "$DS_JSON" | jq length 2>/dev/null || echo 0)

if [[ "$DS_COUNT" -ge 1 ]]; then
    pass "Grafana has $DS_COUNT datasource(s)"
else
    warn "Grafana datasources: expected ≥1, got $DS_COUNT"
fi

for ds_uid in $(echo "$DS_JSON" | jq -r '.[].uid' 2>/dev/null); do
    ds_name=$(echo "$DS_JSON" | jq -r --arg uid "$ds_uid" '.[] | select(.uid == $uid) | .name')
    ds_type=$(echo "$DS_JSON" | jq -r --arg uid "$ds_uid" '.[] | select(.uid == $uid) | .type')
    if _gcurl -X POST "$GRAFANA_URL/api/datasources/uid/$ds_uid/health" 2>/dev/null | jq -e '.status == "OK"' >/dev/null 2>&1; then
        pass "Datasource '$ds_name' connectivity OK"
    else
        # Only fail if the backend for this datasource is actually running
        if [[ "$ds_type" == "influxdb" ]] && ! $HAS_INFLUX; then
            warn "Datasource '$ds_name' unreachable (InfluxDB not running)"
        elif [[ "$ds_type" == "prometheus" ]] && ! $HAS_VM; then
            warn "Datasource '$ds_name' unreachable (VictoriaMetrics not running)"
        else
            fail "Datasource '$ds_name' cannot reach backend"
        fi
    fi
done
echo ""

echo "── Grafana dashboards ──"
DASHBOARDS=$(_gcurl "$GRAFANA_URL/api/search?type=dash-db" 2>/dev/null || echo "[]")
DASH_COUNT=$(echo "$DASHBOARDS" | jq length 2>/dev/null || echo 0)

if [[ "$DASH_COUNT" -gt 0 ]]; then
    pass "Grafana has $DASH_COUNT dashboard(s)"
    echo "$DASHBOARDS" | jq -r '.[].title' 2>/dev/null | while read -r title; do
        echo "     → $title"
    done
else
    warn "No dashboards found in Grafana"
fi
echo ""

# ── Summary ──────────────────────────────────────────────
test_summary
echo ""

if [[ "$_TEST_FAIL" -eq 0 ]]; then
    echo "🟢 VERDICT: Backup is EXPLOITABLE — data restored successfully."
    exit 0
else
    echo "🔴 VERDICT: Backup has ISSUES — $_TEST_FAIL check(s) failed."
    exit 1
fi
