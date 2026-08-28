#!/usr/bin/env bash
# Show data statistics: databases, retention policies, counts, disk usage.
# Auto-detects which TSDB backend is running (InfluxDB, VictoriaMetrics, or both).
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../" && pwd)"
# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/scripts/lib-common.sh"

detect_container_cli
load_env "$SCRIPT_DIR/.env"

_is_container_running() {
    local name="$1"
    [[ "$("$DOCKER" inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]
}

# ── InfluxDB stats ───────────────────────────────────────
if _is_container_running influxdb; then
    _influx_admin=$(_read_env INFLUXDB_ADMIN_USER)
    _influx_admin_pass=$(_read_env INFLUXDB_ADMIN_PASSWORD)
    INFLUX_AUTH="-username ${_influx_admin:-admin} -password ${_influx_admin_pass}"

    echo "══ InfluxDB ══"
    echo ""
    echo "── Databases ──"
    # shellcheck disable=SC2086
    "$DOCKER" exec influxdb influx $INFLUX_AUTH -execute "SHOW DATABASES"
    echo ""

    echo "── Retention Policies ──"
    for db in speedtest telegraf _internal; do
        echo "  $db:"
        # shellcheck disable=SC2086
        "$DOCKER" exec influxdb influx $INFLUX_AUTH -execute "SHOW RETENTION POLICIES ON $db" 2>/dev/null | tail -2 || echo "    (not available)"
        echo ""
    done

    echo "── Data Counts ──"
    # shellcheck disable=SC2086
    printf "  Speedtest points: %s\n" "$("$DOCKER" exec influxdb influx $INFLUX_AUTH -execute "SELECT COUNT(download_bandwidth) FROM speedtest" -database speedtest 2>/dev/null | tail -1 | awk '{print $2}')"
    # shellcheck disable=SC2086
    printf "  Telegraf (last 1h): %s cpu points\n" "$("$DOCKER" exec influxdb influx $INFLUX_AUTH -execute "SELECT COUNT(usage_idle) FROM cpu WHERE time > now() - 1h" -database telegraf 2>/dev/null | tail -1 | awk '{print $2}')"
    echo ""

    echo "── Disk Usage ──"
    "$DOCKER" exec influxdb du -sh /var/lib/influxdb/data/speedtest /var/lib/influxdb/data/telegraf /var/lib/influxdb/data/_internal 2>/dev/null || true
    echo ""
fi

# ── VictoriaMetrics stats ────────────────────────────────
if _is_container_running victoriametrics; then
    VM_URL="${VICTORIA_METRICS_URL:-http://localhost:8428}"

    echo "══ VictoriaMetrics ══"
    echo ""
    echo "── Metric Names ──"
    METRICS=$(curl -sf "$VM_URL/api/v1/label/__name__/values" | jq -r '.data[]' 2>/dev/null)
    METRIC_COUNT=$(echo "$METRICS" | wc -l)
    echo "  $METRIC_COUNT metric(s)"
    echo "$METRICS" | head -20 | sed 's/^/  /'
    if [[ "$METRIC_COUNT" -gt 20 ]]; then
        echo "  ... ($((METRIC_COUNT - 20)) more)"
    fi
    echo ""

    echo "── Data Counts ──"
    SPEEDTEST_COUNT=$(curl -sf "$VM_URL/api/v1/query" \
        --data-urlencode 'query=count(speedtest_download_bandwidth)' |
        jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
    printf "  Speedtest series: %s\n" "$SPEEDTEST_COUNT"

    CPU_COUNT=$(curl -sf "$VM_URL/api/v1/query" \
        --data-urlencode 'query=count(cpu_usage_idle)' |
        jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
    printf "  CPU idle series: %s\n" "$CPU_COUNT"
    echo ""

    echo "── Storage Size ──"
    STORAGE_BYTES=$(curl -sf "$VM_URL/api/v1/query" \
        --data-urlencode 'query=sum(vm_data_size_bytes)' |
        jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
    echo "$STORAGE_BYTES" | awk '{printf "  %.2f MB\n", $1/1048576}'
    echo ""
fi

# ── No backend found ─────────────────────────────────────
if ! _is_container_running influxdb && ! _is_container_running victoriametrics; then
    echo "❌ No TSDB backend running (neither influxdb nor victoriametrics)"
    exit 1
fi

echo "── Docker ──"
"$DOCKER" system df
