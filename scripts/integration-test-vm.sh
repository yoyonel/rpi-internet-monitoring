#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# integration-test-vm.sh — Prove VictoriaMetrics can fully replace InfluxDB
# ─────────────────────────────────────────────────────────────────────────────
# Automated integration test: starts VM + Telegraf (x86 native, no QEMU),
# verifies the full data pipeline, exports to InfluxDB JSON, and runs E2E.
#
# Usage: bash scripts/integration-test-vm.sh [--skip-e2e] [--keep]
#   --skip-e2e  Skip Playwright E2E tests (faster feedback loop)
#   --keep      Don't cleanup containers on exit (for debugging)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/scripts/lib-common.sh"
detect_container_cli

# ── Options ──────────────────────────────────────────────────
SKIP_E2E=false
KEEP=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-e2e)
            SKIP_E2E=true
            shift
            ;;
        --keep)
            KEEP=true
            shift
            ;;
        *)
            echo "Usage: $0 [--skip-e2e] [--keep]" >&2
            exit 1
            ;;
    esac
done

# ── Isolated test environment (avoids collision with sim/prod) ──
NETWORK="vm-it-net"
VM_CONTAINER="vm-it-victoriametrics"
TELEGRAF_CONTAINER="vm-it-telegraf"
VM_PORT=18428
PREVIEW_PORT=18080
VM_URL="http://localhost:${VM_PORT}"
PREVIEW_PID=""
DATA_FILE=""

# ── Cleanup ──────────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    if [[ "$KEEP" == "true" ]]; then
        echo ""
        echo "── Containers kept (--keep). Manual cleanup:"
        echo "  $DOCKER rm -f $VM_CONTAINER $TELEGRAF_CONTAINER"
        echo "  $DOCKER network rm $NETWORK"
        return "$exit_code"
    fi
    echo ""
    echo "── Cleanup ──"
    [[ -n "$PREVIEW_PID" ]] && kill "$PREVIEW_PID" 2>/dev/null && wait "$PREVIEW_PID" 2>/dev/null || true
    "$DOCKER" rm -f "$VM_CONTAINER" "$TELEGRAF_CONTAINER" 2>/dev/null || true
    "$DOCKER" network rm "$NETWORK" 2>/dev/null || true
    [[ -n "$DATA_FILE" && -f "$DATA_FILE" ]] && rm -f "$DATA_FILE"
    echo "  Done"
    return "$exit_code"
}
trap cleanup EXIT

# ── Pre-flight checks ───────────────────────────────────────
for cmd in curl jq python3; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: $cmd required but not found" >&2
        exit 1
    }
done

if ! "$DOCKER" info >/dev/null 2>&1; then
    echo "ERROR: $DOCKER daemon not running" >&2
    exit 1
fi

# Check ports are free
for port in $VM_PORT $PREVIEW_PORT; do
    if curl -sf --max-time 2 "http://localhost:${port}/" >/dev/null 2>&1; then
        echo "ERROR: Port $port already in use" >&2
        exit 1
    fi
done

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  VM Integration Test — Full InfluxDB Replacement Proof       ║"
echo "║  $(date -Iseconds)                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# ═══════════════════════════════════════════════════════════════
# 1. Start Infrastructure
# ═══════════════════════════════════════════════════════════════
echo "── 1. Infrastructure ──"

"$DOCKER" network create "$NETWORK" >/dev/null 2>&1 || true

# Start VictoriaMetrics (x86 native — instant startup)
"$DOCKER" run -d --name "$VM_CONTAINER" \
    --network "$NETWORK" \
    -p "127.0.0.1:${VM_PORT}:8428" \
    victoriametrics/victoria-metrics:v1.142.0 \
    -search.latencyOffset=0s \
    -retentionPeriod=365d >/dev/null

# Wait for healthy
for i in $(seq 1 30); do
    if curl -sf "${VM_URL}/health" >/dev/null 2>&1; then
        pass "VictoriaMetrics healthy (${i}s)"
        break
    fi
    if [[ "$i" -eq 30 ]]; then
        fail "VictoriaMetrics did not start in 30s"
        "$DOCKER" logs "$VM_CONTAINER"
        exit 1
    fi
    sleep 1
done

# Start Telegraf writing ONLY to VictoriaMetrics (no InfluxDB at all)
"$DOCKER" run -d --name "$TELEGRAF_CONTAINER" \
    --network "$NETWORK" \
    -e "VM_OUTPUT_URL=http://${VM_CONTAINER}:8428" \
    -v "$SCRIPT_DIR/sim/telegraf-vm-only.conf:/etc/telegraf/telegraf.conf:ro" \
    -v /proc:/host/proc:ro \
    -v /sys:/host/sys:ro \
    telegraf:1.38.2 >/dev/null

pass "Telegraf started (sole backend: VictoriaMetrics)"
echo ""

# ═══════════════════════════════════════════════════════════════
# 2. Telegraf → VM Data Pipeline
# ═══════════════════════════════════════════════════════════════
echo "── 2. Telegraf → VM Pipeline ──"

echo "  Waiting for first Telegraf flush (~15s)..."
LABELS=""
for i in $(seq 1 45); do
    LABELS=$(curl -sf "${VM_URL}/api/v1/label/__name__/values" |
        jq -r '.data[]' 2>/dev/null || echo '')
    if echo "$LABELS" | grep -q '^cpu_usage_idle$'; then
        pass "Telegraf data arrived in VM (${i}s)"
        break
    fi
    if [[ "$i" -eq 45 ]]; then
        fail "No Telegraf data after 45s"
        echo "  Telegraf logs:"
        "$DOCKER" logs --tail 15 "$TELEGRAF_CONTAINER"
    fi
    sleep 1
done

# Verify key system metrics
for metric in cpu_usage_idle cpu_usage_system mem_used_percent \
    disk_used_percent system_uptime swap_used_percent; do
    if echo "$LABELS" | grep -q "^${metric}$"; then
        pass "System metric: $metric"
    else
        warn "Missing: $metric (may need more flush cycles)"
    fi
done

# Verify actual values make sense (not zeros, not insane)
# Small delay ensures the instant query finds a recent sample
sleep 2
cpu_idle=$(curl -sf "${VM_URL}/api/v1/query" \
    --data-urlencode 'query=cpu_usage_idle{cpu="cpu-total"}' |
    jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
if (($(echo "$cpu_idle > 0 && $cpu_idle <= 100" | bc -l 2>/dev/null || echo 0))); then
    pass "cpu_usage_idle value realistic: ${cpu_idle}%"
else
    fail "cpu_usage_idle value suspicious: ${cpu_idle}"
fi
echo ""

# ═══════════════════════════════════════════════════════════════
# 3. Speedtest Write Path (simulated injection)
# ═══════════════════════════════════════════════════════════════
echo "── 3. Speedtest Write Path ──"

# Inject 150 realistic speedtest points spread over 30 days.
# This simulates what speedtest-cron + docker-entrypoint.sh would do.
# Batch all points in a single HTTP request (line protocol supports multi-line).
TOTAL_POINTS=150
NOW=$(date +%s)
BATCH=""
for i in $(seq 0 $((TOTAL_POINTS - 1))); do
    ts_sec=$((NOW - 30 * 86400 + i * 17280))
    ts_ns="${ts_sec}000000000"
    # Deterministic but varied values based on index
    dl=$((800000000 + (i * 7321 % 200000000)))
    ul=$((300000000 + (i * 4567 % 100000000)))
    ping_int=$((80 + (i * 31 % 200)))
    ping="${ping_int}.$((i % 10))"
    BATCH+="speedtest,result_id=vm-it-$(printf '%03d' "$i") download_bandwidth=${dl},upload_bandwidth=${ul},ping_latency=${ping} ${ts_ns}"$'\n'
done

if curl -sf -d "$BATCH" "${VM_URL}/write?db=speedtest" >/dev/null; then
    pass "Injected $TOTAL_POINTS speedtest points via InfluxDB line protocol (batch)"
else
    fail "Batch write failed"
fi

# Flush and wait for indexing
curl -sf "${VM_URL}/internal/force_flush" >/dev/null
sleep 3

# count_over_time counts data points (not series) — sum across all series
dl_count=$(curl -sf "${VM_URL}/api/v1/query" \
    --data-urlencode 'query=sum(count_over_time(speedtest_download_bandwidth[60d]))' |
    jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
if [[ "$dl_count" == "$TOTAL_POINTS" ]]; then
    pass "All $TOTAL_POINTS points queryable via MetricsQL"
else
    fail "Expected $TOTAL_POINTS queryable points, got $dl_count"
fi

# Verify field separation (VM naming: {measurement}_{field})
for metric in speedtest_download_bandwidth speedtest_upload_bandwidth speedtest_ping_latency; do
    val=$(curl -sf "${VM_URL}/api/v1/query" \
        --data-urlencode "query=last_over_time(${metric}[30d])" |
        jq -r '.data.result[0].value[1] // empty' 2>/dev/null)
    if [[ -n "$val" ]]; then
        pass "Metric $metric queryable (value=$val)"
    else
        fail "Metric $metric not found"
    fi
done
echo ""

# ═══════════════════════════════════════════════════════════════
# 4. VM → InfluxDB JSON Export
# ═══════════════════════════════════════════════════════════════
echo "── 4. Export Pipeline ──"

# Ensure all data is indexed before export
curl -sf "${VM_URL}/internal/force_flush" >/dev/null
sleep 3

DATA_FILE=$(mktemp /tmp/vm-integration-XXXXXX.json)

if bash "$SCRIPT_DIR/scripts/export-vm-data.sh" "$VM_URL" 30 >"$DATA_FILE" 2>/tmp/vm-export-err.log; then
    pass "Export script succeeded"
else
    fail "Export script failed"
    cat /tmp/vm-export-err.log >&2
fi

# Validate InfluxDB JSON structure
columns=$(jq -r '.results[0].series[0].columns | join(",")' "$DATA_FILE" 2>/dev/null || echo "PARSE_ERROR")
if [[ "$columns" == "time,download_bandwidth,upload_bandwidth,ping_latency" ]]; then
    pass "JSON columns match InfluxDB format"
else
    fail "Wrong columns: $columns"
fi

value_count=$(jq '.results[0].series[0].values | length' "$DATA_FILE" 2>/dev/null || echo 0)
EXPORT_MIN=$((TOTAL_POINTS - 2)) # allow for timestamp boundary rounding
if [[ "$value_count" -ge "$EXPORT_MIN" ]]; then
    pass "Exported $value_count data points (≥${EXPORT_MIN})"
else
    fail "Only $value_count points exported (expected ≥${EXPORT_MIN})"
fi

# Spot-check: first row has 4 elements [time, dl, ul, ping]
first_row_len=$(jq '.results[0].series[0].values[0] | length' "$DATA_FILE" 2>/dev/null || echo 0)
if [[ "$first_row_len" -eq 4 ]]; then
    pass "Row format: [time, download, upload, ping] (4 fields)"
else
    fail "Row has $first_row_len fields (expected 4)"
fi

# Spot-check: time field is RFC3339
first_time=$(jq -r '.results[0].series[0].values[0][0]' "$DATA_FILE" 2>/dev/null || echo "")
if [[ "$first_time" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
    pass "Timestamps in RFC3339 format ($first_time)"
else
    fail "Bad timestamp format: $first_time"
fi

# Spot-check: download > 0
first_dl=$(jq '.results[0].series[0].values[0][1]' "$DATA_FILE" 2>/dev/null || echo 0)
if (($(echo "$first_dl > 0" | bc -l 2>/dev/null || echo 0))); then
    pass "download_bandwidth > 0 ($first_dl)"
else
    fail "download_bandwidth suspicious: $first_dl"
fi
echo ""

# ═══════════════════════════════════════════════════════════════
# 5. Frontend E2E Tests
# ═══════════════════════════════════════════════════════════════
if [[ "$SKIP_E2E" == "true" ]]; then
    echo "── 5. Frontend E2E — SKIPPED (--skip-e2e) ──"
    echo ""
else
    echo "── 5. Frontend E2E ──"

    # Kill any orphan process on the preview port from a previous run
    fuser -k "${PREVIEW_PORT}/tcp" 2>/dev/null || true
    sleep 1

    # Start preview server with VM-exported data
    bash "$SCRIPT_DIR/scripts/preview-dev.sh" "$PREVIEW_PORT" --data "$DATA_FILE" &
    PREVIEW_PID=$!

    for i in $(seq 1 15); do
        if curl -sf "http://localhost:${PREVIEW_PORT}/" >/dev/null 2>&1; then
            pass "Preview server on :${PREVIEW_PORT}"
            break
        fi
        if [[ "$i" -eq 15 ]]; then
            fail "Preview server failed to start"
        fi
        sleep 1
    done

    # Run Playwright E2E tests against VM-sourced data
    echo "  Running Playwright..."
    if E2E_BASE_URL="http://localhost:${PREVIEW_PORT}" \
        npx playwright test --reporter=line 2>&1 | tail -5; then
        pass "All E2E tests passed with VM-sourced data"
    else
        fail "Some E2E tests failed"
    fi

    # Stop preview
    kill "$PREVIEW_PID" 2>/dev/null && wait "$PREVIEW_PID" 2>/dev/null || true
    PREVIEW_PID=""
    echo ""
fi

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
test_summary
