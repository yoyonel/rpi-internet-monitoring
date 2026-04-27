#!/usr/bin/env bash
# Smoke tests for the RPi4 simulation stack.
# Validates that the sim environment is functional after boot.
#
# Designed to run:
#   - Locally after `just sim-up`
#   - In CI (GitHub Actions nightly workflow)
#
# Prerequisites: sim stack running, jq + curl available.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

detect_container_cli
load_env "$PROJECT_DIR/sim/.env.sim"

_user=$(_read_env GF_SECURITY_ADMIN_USER)
_pass=$(_read_env GF_SECURITY_ADMIN_PASSWORD)
_influx_admin=$(_read_env INFLUXDB_ADMIN_USER)
_influx_admin_pass=$(_read_env INFLUXDB_ADMIN_PASSWORD)

GRAFANA_URL="http://localhost:3000"
setup_grafana_auth "$_user" "$_pass"
CHRONOGRAF_URL="http://localhost:8888"
INFLUXDB_URL="http://localhost:8086"
SIM_CONTAINERS=(
    rpi-sim-grafana
    rpi-sim-influxdb
    rpi-sim-chronograf
    rpi-sim-telegraf
    rpi-sim-docker-socket-proxy
    rpi-sim-speedtest-cron
)

# Test harness provided by lib-common.sh (pass/fail/warn/test_summary)

influx_query() {
    local query="$1" database="${2:-}"

    curl -sfG \
        -u "${_influx_admin:-admin}:${_influx_admin_pass}" \
        --data-urlencode "q=$query" \
        ${database:+--data-urlencode "db=$database"} \
        "$INFLUXDB_URL/query"
}

influx_count_value() {
    local json="$1"
    echo "$json" | jq -r '
        .results[]?.series[]?.values[]?[1] // empty
    ' | tail -1
}

wait_for_influx_values() {
    local query="$1" database="${2:-}"
    local attempts="${3:-12}"
    local json

    for _ in $(seq 1 "$attempts"); do
        json=$(influx_query "$query" "$database" 2>/dev/null || echo '{}')
        if echo "$json" | jq -e '.results[]?.series[]?.values[]?' >/dev/null 2>&1; then
            printf '%s\n' "$json"
            return 0
        fi
        sleep 5
    done

    printf '%s\n' "${json:-{}}"
    return 1
}

check_dashboard() {
    local uid="$1" name="$2"
    if _gcurl "$GRAFANA_URL/api/dashboards/uid/$uid" 2>/dev/null | jq -e '.dashboard' >/dev/null 2>&1; then
        pass "Dashboard '$name' (uid=$uid)"
    else
        fail "Dashboard '$name' missing (uid=$uid)"
    fi
}

echo "╔══════════════════════════════════════════════════════════╗"
echo "║     Sim Stack — E2E Smoke Tests                         ║"
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

DATABASES_JSON=$(wait_for_influx_values "SHOW DATABASES" "" 3 || echo '{}')
DATABASES=$(echo "$DATABASES_JSON" | jq -r '.results[]?.series[]?.values[]?[0] // empty')
if echo "$DATABASES" | grep -qx 'speedtest'; then
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

for ds_name in "InfluxDB" "InfluxDB-Speedtest"; do
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

check_dashboard "speedtest-dashboard" "Internet Speedtest"
check_dashboard "rpi-docker-dashboard" "Docker Containers"
check_dashboard "rpi-alerts-dashboard" "RPi Alerts Overview"
check_dashboard "system-metrics-dashboard" "System Metrics"

echo ""

# ── 4. InfluxDB Schema ───────────────────────────────────────
echo "── 4. InfluxDB Schema ──"

DATABASES_JSON=$(wait_for_influx_values "SHOW DATABASES" "" 12 || echo '{}')
DATABASES=$(echo "$DATABASES_JSON" | jq -r '.results[]?.series[]?.values[]?[0] // empty')

for db in speedtest telegraf; do
    if echo "$DATABASES" | grep -qx "$db"; then
        pass "Database '$db' exists"
    else
        fail "Database '$db' missing"
    fi
done

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

echo ""

# ── 5. Telegraf Pipeline ─────────────────────────────────────
echo "── 5. Telegraf Pipeline ──"

TELEGRAF_COUNT=$(influx_count_value "$(influx_query "SELECT COUNT(usage_idle) FROM cpu WHERE time > now() - 5m" telegraf 2>/dev/null)")
if [[ -n "$TELEGRAF_COUNT" && "$TELEGRAF_COUNT" =~ ^[0-9]+$ && "$TELEGRAF_COUNT" -gt 0 ]]; then
    pass "Telegraf → InfluxDB pipeline active ($TELEGRAF_COUNT cpu points in last 5 min)"
else
    fail "Telegraf → InfluxDB pipeline broken (0 cpu points in last 5 min)"
fi

echo ""

# ── 6. Speedtest Write Path ──────────────────────────────────
echo "── 6. Speedtest Write Path ──"

# Inject a synthetic data point to validate the write path
# without running a real speedtest (avoids network dependency + QEMU slowness).
INJECT_RESULT=$(curl -sf -o /dev/null -w "%{http_code}" -XPOST \
    "${INFLUXDB_URL}/write?db=speedtest&u=${_influx_admin}&p=${_influx_admin_pass}" \
    --data-binary 'speedtest,result_id=ci-smoke-test ping_latency=10.5,download_bandwidth=1000000.0,upload_bandwidth=500000.0')
if [[ "$INJECT_RESULT" == "204" ]]; then
    pass "Speedtest write path works (injected test point)"
else
    fail "Speedtest write path broken (HTTP $INJECT_RESULT)"
fi

# Verify the injected point is queryable
QUERY_COUNT=$(influx_count_value "$(influx_query "SELECT COUNT(download_bandwidth) FROM speedtest WHERE \"result_id\" = 'ci-smoke-test'" speedtest 2>/dev/null)")
if [[ -n "$QUERY_COUNT" && "$QUERY_COUNT" =~ ^[0-9]+$ && "$QUERY_COUNT" -ge 1 ]]; then
    pass "Injected test point is queryable ($QUERY_COUNT point(s))"
else
    fail "Injected test point not found in query results"
fi

# Clean up: remove synthetic data
influx_query "DELETE FROM speedtest WHERE \"result_id\" = 'ci-smoke-test'" speedtest >/dev/null 2>&1

echo ""

# ── 7. Container State ───────────────────────────────────────
echo "── 7. Container State ──"

for svc in "${SIM_CONTAINERS[@]}"; do
    if "$DOCKER" inspect --format '{{.State.Running}}' "$svc" 2>/dev/null | grep -q 'true'; then
        pass "Container '$svc' running"
    else
        fail "Container '$svc' not running"
    fi
done

echo ""

# ── Summary ───────────────────────────────────────────────────
test_summary
