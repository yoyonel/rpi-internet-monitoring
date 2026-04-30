#!/usr/bin/env bash
# Show simulation stats: databases, counts, disk usage.
# Auto-detects which TSDB backend is running in the sim stack.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

detect_container_cli
load_env "$PROJECT_DIR/sim/.env.sim"

_is_container_running() {
    local name="$1"
    [[ "$("$DOCKER" inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]
}

INFLUX_CONTAINER="rpi-sim-influxdb"
VM_CONTAINER="rpi-sim-victoriametrics"

# ── InfluxDB stats ───────────────────────────────────────
if _is_container_running "$INFLUX_CONTAINER"; then
    _influx_user=$(_read_env INFLUXDB_ADMIN_USER)
    _influx_pass=$(_read_env INFLUXDB_ADMIN_PASSWORD)
    INFLUX_AUTH="-username ${_influx_user:-admin} -password ${_influx_pass}"

    echo "══ InfluxDB (sim) ══"
    echo ""
    echo "── Databases ──"
    # shellcheck disable=SC2086
    "$DOCKER" exec "$INFLUX_CONTAINER" influx $INFLUX_AUTH -execute "SHOW DATABASES"
    echo ""

    echo "── Retention Policies ──"
    for db in speedtest telegraf; do
        echo "  $db:"
        # shellcheck disable=SC2086
        "$DOCKER" exec "$INFLUX_CONTAINER" influx $INFLUX_AUTH -execute "SHOW RETENTION POLICIES ON $db" 2>/dev/null | tail -2 || echo "    (not available)"
        echo ""
    done

    echo "── Data Counts ──"
    # shellcheck disable=SC2086
    printf "  Speedtest points: %s\n" "$("$DOCKER" exec "$INFLUX_CONTAINER" influx $INFLUX_AUTH -execute "SELECT COUNT(download_bandwidth) FROM speedtest" -database speedtest 2>/dev/null | tail -1 | awk '{print $2}')"
    # shellcheck disable=SC2086
    printf "  Telegraf cpu (last 1h): %s\n" "$("$DOCKER" exec "$INFLUX_CONTAINER" influx $INFLUX_AUTH -execute "SELECT COUNT(usage_idle) FROM cpu WHERE time > now() - 1h" -database telegraf 2>/dev/null | tail -1 | awk '{print $2}')"
    echo ""
fi

# ── VictoriaMetrics stats ────────────────────────────────
if _is_container_running "$VM_CONTAINER"; then
    VM_URL="http://localhost:8428"

    echo "══ VictoriaMetrics (sim) ══"
    echo ""
    echo "── Metric Names ──"
    METRICS=$(curl -sf "$VM_URL/api/v1/label/__name__/values" | jq -r '.data[]' 2>/dev/null)
    METRIC_COUNT=$(echo "$METRICS" | grep -c . 2>/dev/null || echo 0)
    echo "  $METRIC_COUNT metric(s)"
    echo "$METRICS" | head -20 | sed 's/^/  /'
    echo ""

    echo "── Data Counts ──"
    for metric in speedtest_download_bandwidth download_bandwidth; do
        COUNT=$(curl -sf "$VM_URL/api/v1/query" \
            --data-urlencode "query=count($metric)" |
            jq -r '.data.result[0].value[1] // empty' 2>/dev/null)
        if [[ -n "$COUNT" && "$COUNT" != "0" ]]; then
            printf "  Speedtest series (%s): %s\n" "$metric" "$COUNT"
            break
        fi
    done

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
if ! _is_container_running "$INFLUX_CONTAINER" && ! _is_container_running "$VM_CONTAINER"; then
    echo "❌ No TSDB backend running in sim stack"
    exit 1
fi
