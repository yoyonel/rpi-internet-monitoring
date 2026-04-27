#!/usr/bin/env bash
# Smoke tests for the monitoring stack (production & simulation).
# Run BEFORE and AFTER any upgrade to detect regressions.
#
# Usage: test-stack.sh [--mode prod|sim]  (default: prod)
#   prod  — production stack (requires RPi or local stack)
#   sim   — RPi4 simulation stack (QEMU/ARM64)
set -uo pipefail

MODE="prod"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        prod | sim)
            MODE="$1"
            shift
            ;;
        *)
            echo "Usage: $0 [--mode prod|sim]" >&2
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/scripts/lib-common.sh"

detect_container_cli

# ── Mode-specific configuration ───────────────────────────────
case "$MODE" in
    prod)
        load_env "$SCRIPT_DIR/.env"
        INFLUXDB_CONTAINER="influxdb"
        CONTAINERS=(grafana influxdb chronograf telegraf)
        DATASOURCE_NAMES=("InfluxDB" "Telegraf")
        DASHBOARDS=("Ha9ke1iRk:SpeedTest" "000000128:System")
        SPEEDTEST_MIN_COUNT=122000
        TELEGRAF_WINDOW="2m"
        INFLUX_WAIT_ATTEMPTS=1
        ;;
    sim)
        load_env "$SCRIPT_DIR/sim/.env.sim"
        INFLUXDB_CONTAINER="rpi-sim-influxdb"
        INFLUXDB_URL="http://localhost:8086"
        CONTAINERS=(rpi-sim-grafana rpi-sim-influxdb rpi-sim-chronograf rpi-sim-telegraf rpi-sim-docker-socket-proxy rpi-sim-speedtest-cron)
        DATASOURCE_NAMES=("InfluxDB" "InfluxDB-Speedtest")
        DASHBOARDS=(
            "speedtest-dashboard:Internet Speedtest"
            "rpi-docker-dashboard:Docker Containers"
            "rpi-alerts-dashboard:RPi Alerts Overview"
            "system-metrics-dashboard:System Metrics"
        )
        SPEEDTEST_MIN_COUNT=0
        TELEGRAF_WINDOW="5m"
        INFLUX_WAIT_ATTEMPTS=12
        ;;
    *)
        echo "Usage: $0 [--mode prod|sim]" >&2
        exit 1
        ;;
esac

# ── Credentials ───────────────────────────────────────────────
_user=$(_read_env GF_SECURITY_ADMIN_USER)
_pass=$(_read_env GF_SECURITY_ADMIN_PASSWORD)
_influx_admin=$(_read_env INFLUXDB_ADMIN_USER)
_influx_admin_pass=$(_read_env INFLUXDB_ADMIN_PASSWORD)
GRAFANA_URL="http://localhost:3000"
CHRONOGRAF_URL="http://localhost:8888"
setup_grafana_auth "$_user" "$_pass"

# Test harness provided by lib-common.sh (pass/fail/warn/test_summary)

# ── InfluxDB query helpers ────────────────────────────────────
# influx_query returns raw output: text (prod/docker exec) or JSON (sim/curl).
influx_query() {
    local query="$1" database="${2:-}"
    if [[ "$MODE" == "sim" ]]; then
        curl -sfG \
            -u "${_influx_admin:-admin}:${_influx_admin_pass}" \
            --data-urlencode "q=$query" \
            ${database:+--data-urlencode "db=$database"} \
            "$INFLUXDB_URL/query"
    else
        "$DOCKER" exec "$INFLUXDB_CONTAINER" influx \
            -username "${_influx_admin:-admin}" -password "${_influx_admin_pass}" \
            -execute "$query" -database "${database:-}" 2>/dev/null
    fi
}

# Extract a scalar count from query output.
influx_count_value() {
    local output="$1"
    if [[ "$MODE" == "sim" ]]; then
        echo "$output" | jq -r '.results[]?.series[]?.values[]?[1] // empty' | tail -1
    else
        echo "$output" | tail -1 | awk '{print $2}'
    fi
}

# Check if a database name appears in SHOW DATABASES output.
influx_has_database() {
    local output="$1" db="$2"
    if [[ "$MODE" == "sim" ]]; then
        echo "$output" | jq -r '.results[]?.series[]?.values[]?[0] // empty' | grep -qx "$db"
    else
        echo "$output" | grep -q "^${db}$"
    fi
}

# Count measurements in SHOW MEASUREMENTS output.
influx_count_measurements() {
    local output="$1"
    if [[ "$MODE" == "sim" ]]; then
        echo "$output" | jq -r '.results[]?.series[]?.values[]?[0] // empty' | grep -c '^[a-z]' || echo 0
    else
        echo "$output" | grep -c '^[a-z]' || echo 0
    fi
}

# Retry an InfluxDB query until results appear (for slow QEMU boot).
wait_for_influx() {
    local query="$1" database="${2:-}" attempts="${3:-$INFLUX_WAIT_ATTEMPTS}"
    local output
    for _ in $(seq 1 "$attempts"); do
        output=$(influx_query "$query" "$database" 2>/dev/null || echo '')
        if [[ -n "$output" ]]; then
            if [[ "$MODE" == "sim" ]]; then
                if echo "$output" | jq -e '.results[]?.series[]?.values[]?' >/dev/null 2>&1; then
                    printf '%s\n' "$output"
                    return 0
                fi
            else
                # Text mode: check we got more than just column headers
                if echo "$output" | grep -qE '^[a-z_]|^[0-9]'; then
                    printf '%s\n' "$output"
                    return 0
                fi
            fi
        fi
        [[ "$attempts" -gt 1 ]] && sleep 5
    done
    printf '%s\n' "${output:-}"
    return 1
}

# ── Banner ────────────────────────────────────────────────────
BANNER=$([[ "$MODE" == "sim" ]] && echo "Sim Stack" || echo "Monitoring Stack")
echo "╔══════════════════════════════════════════════════════════╗"
echo "║     ${BANNER} — Regression Test Suite                    "
echo "║     $(date -Iseconds)                      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Service Health ─────────────────────────────────────────
echo "── 1. Service Health ──"

if curl -sf "$GRAFANA_URL/api/health" | jq -e '.database == "ok"' >/dev/null 2>&1; then
    pass "Grafana responds on :3000"
else
    fail "Grafana not responding on :3000"
fi

DB_OUTPUT=$(wait_for_influx "SHOW DATABASES" "" 3 || echo '')
if influx_has_database "$DB_OUTPUT" "speedtest"; then
    pass "InfluxDB responds (speedtest DB exists)"
else
    fail "InfluxDB not responding or speedtest DB missing"
fi

if curl -sf "$CHRONOGRAF_URL/chronograf/v1/me" >/dev/null 2>&1; then
    pass "Chronograf responds on :8888"
else
    fail "Chronograf not responding on :8888"
fi

echo ""

# ── 2. Grafana Datasources ───────────────────────────────────
echo "── 2. Grafana Datasources ──"

DS_JSON=$(_gcurl "$GRAFANA_URL/api/datasources" 2>/dev/null || echo "[]")
DS_COUNT=$(echo "$DS_JSON" | jq length 2>/dev/null || echo 0)
if [[ "$DS_COUNT" -eq 2 ]]; then
    pass "Grafana has 2 datasources"
else
    fail "Grafana datasources: expected 2, got $DS_COUNT"
fi

for ds_name in "${DATASOURCE_NAMES[@]}"; do
    if echo "$DS_JSON" | jq -e --arg n "$ds_name" '.[] | select(.name == $n)' >/dev/null 2>&1; then
        pass "Datasource '$ds_name' exists"
    else
        fail "Datasource '$ds_name' missing"
    fi
done

for ds_uid in $(echo "$DS_JSON" | jq -r '.[].uid' 2>/dev/null); do
    ds_name=$(echo "$DS_JSON" | jq -r --arg uid "$ds_uid" '.[] | select(.uid == $uid) | .name')
    if _gcurl -X POST "$GRAFANA_URL/api/datasources/uid/$ds_uid/health" 2>/dev/null | jq -e '.status == "OK"' >/dev/null 2>&1; then
        pass "Datasource '$ds_name' connectivity OK"
    else
        fail "Datasource '$ds_name' cannot connect to InfluxDB"
    fi
done

echo ""

# ── 3. Grafana Dashboards ────────────────────────────────────
echo "── 3. Grafana Dashboards ──"

for entry in "${DASHBOARDS[@]}"; do
    uid="${entry%%:*}"
    name="${entry#*:}"
    if _gcurl "$GRAFANA_URL/api/dashboards/uid/$uid" 2>/dev/null | jq -e '.dashboard' >/dev/null 2>&1; then
        pass "Dashboard '$name' (uid=$uid)"
    else
        fail "Dashboard '$name' missing (uid=$uid)"
    fi
done

echo ""

# ── 4. Data Pipeline ─────────────────────────────────────────
echo "── 4. Data Pipeline ──"

TELEGRAF_OUTPUT=$(influx_query "SELECT COUNT(usage_idle) FROM cpu WHERE time > now() - ${TELEGRAF_WINDOW}" telegraf 2>/dev/null || echo '')
TELEGRAF_COUNT=$(influx_count_value "$TELEGRAF_OUTPUT")
if [[ -n "$TELEGRAF_COUNT" && "$TELEGRAF_COUNT" =~ ^[0-9]+$ && "$TELEGRAF_COUNT" -gt 0 ]]; then
    pass "Telegraf → InfluxDB pipeline active ($TELEGRAF_COUNT points in last $TELEGRAF_WINDOW)"
else
    fail "Telegraf → InfluxDB pipeline broken (0 points in last $TELEGRAF_WINDOW)"
fi

if [[ "$SPEEDTEST_MIN_COUNT" -gt 0 ]]; then
    SPEEDTEST_OUTPUT=$(influx_query "SELECT COUNT(download_bandwidth) FROM speedtest" speedtest 2>/dev/null || echo '')
    SPEEDTEST_COUNT=$(influx_count_value "$SPEEDTEST_OUTPUT")
    if [[ -n "$SPEEDTEST_COUNT" && "$SPEEDTEST_COUNT" =~ ^[0-9]+$ && "$SPEEDTEST_COUNT" -ge "$SPEEDTEST_MIN_COUNT" ]]; then
        pass "Speedtest data preserved ($SPEEDTEST_COUNT points, ≥${SPEEDTEST_MIN_COUNT})"
    else
        fail "Speedtest data loss (got ${SPEEDTEST_COUNT:-0}, expected ≥${SPEEDTEST_MIN_COUNT})"
    fi
fi

echo ""

# ── 5. Data Integrity ────────────────────────────────────────
echo "── 5. Data Integrity ──"

DB_OUTPUT=$(wait_for_influx "SHOW DATABASES" "" "$INFLUX_WAIT_ATTEMPTS" || echo '')
for db in speedtest telegraf; do
    if influx_has_database "$DB_OUTPUT" "$db"; then
        pass "Database '$db' exists"
    else
        fail "Database '$db' missing"
    fi
done

# Sim-only: verify user grants (prod relies on provisioned credentials)
if [[ "$MODE" == "sim" ]]; then
    GRANTS=$(influx_query "SHOW GRANTS FOR \"telegraf\"" 2>/dev/null || echo '{}')
    GRANT_LINES=$(echo "$GRANTS" | jq -r '.results[]?.series[]?.values[]? | @tsv')
    if ! echo "$GRANT_LINES" | grep -qx $'telegraf\tALL PRIVILEGES'; then
        for _ in $(seq 1 12); do
            sleep 5
            GRANTS=$(influx_query "SHOW GRANTS FOR \"telegraf\"" 2>/dev/null || echo '{}')
            GRANT_LINES=$(echo "$GRANTS" | jq -r '.results[]?.series[]?.values[]? | @tsv')
            if echo "$GRANT_LINES" | grep -qx $'telegraf\tALL PRIVILEGES'; then
                break
            fi
        done
    fi
    for db in speedtest telegraf; do
        if echo "$GRANT_LINES" | grep -qx "$db"$'\t''ALL PRIVILEGES'; then
            pass "User 'telegraf' has ALL on '$db'"
        else
            fail "User 'telegraf' missing privileges on '$db'"
        fi
    done
fi

MEASUREMENTS_OUTPUT=$(influx_query "SHOW MEASUREMENTS" speedtest 2>/dev/null || echo '')
MEASUREMENTS=$(influx_count_measurements "$MEASUREMENTS_OUTPUT")
if [[ "$MEASUREMENTS" -ge 1 ]]; then
    pass "Speedtest DB has $MEASUREMENTS measurement(s)"
else
    fail "Speedtest DB has no measurements"
fi

echo ""

# ── 6. Speedtest Write Path (sim only) ───────────────────────
if [[ "$MODE" == "sim" ]]; then
    echo "── 6. Speedtest Write Path ──"

    INJECT_RESULT=$(curl -sf -o /dev/null -w "%{http_code}" -XPOST \
        "${INFLUXDB_URL}/write?db=speedtest&u=${_influx_admin}&p=${_influx_admin_pass}" \
        --data-binary 'speedtest,result_id=ci-smoke-test ping_latency=10.5,download_bandwidth=1000000.0,upload_bandwidth=500000.0')
    if [[ "$INJECT_RESULT" == "204" ]]; then
        pass "Speedtest write path works (injected test point)"
    else
        fail "Speedtest write path broken (HTTP $INJECT_RESULT)"
    fi

    QUERY_OUTPUT=$(influx_query "SELECT COUNT(download_bandwidth) FROM speedtest WHERE \"result_id\" = 'ci-smoke-test'" speedtest 2>/dev/null || echo '')
    QUERY_COUNT=$(influx_count_value "$QUERY_OUTPUT")
    if [[ -n "$QUERY_COUNT" && "$QUERY_COUNT" =~ ^[0-9]+$ && "$QUERY_COUNT" -ge 1 ]]; then
        pass "Injected test point is queryable ($QUERY_COUNT point(s))"
    else
        fail "Injected test point not found in query results"
    fi

    # Clean up synthetic data
    influx_query "DELETE FROM speedtest WHERE \"result_id\" = 'ci-smoke-test'" speedtest >/dev/null 2>&1

    echo ""
fi

# ── 7. Container State ───────────────────────────────────────
echo "── $([[ "$MODE" == "sim" ]] && echo 7 || echo 6). Container State ──"

for svc in "${CONTAINERS[@]}"; do
    if "$DOCKER" inspect --format '{{.State.Running}}' "$svc" 2>/dev/null | grep -q 'true'; then
        pass "Container '$svc' running"
    else
        fail "Container '$svc' not running"
    fi
done

if [[ "$MODE" == "prod" ]]; then
    STOPPED=$("$DOCKER" ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | wc -l)
    if [[ "$STOPPED" -gt 0 ]]; then
        warn "$STOPPED stopped container(s) (cleanup recommended)"
    else
        pass "No stopped containers"
    fi
fi

echo ""

# ── Summary ───────────────────────────────────────────────────
test_summary
