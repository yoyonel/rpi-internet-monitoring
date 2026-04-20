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
DOCKER=${CONTAINER_CLI:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/sim/.env.sim"

# Read credentials from sim/.env.sim
_read_env() { grep "^$1=" "$ENV_FILE" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//"; }

_user=$(_read_env GF_SECURITY_ADMIN_USER)
_pass=$(_read_env GF_SECURITY_ADMIN_PASSWORD)
_influx_admin=$(_read_env INFLUXDB_ADMIN_USER)
_influx_admin_pass=$(_read_env INFLUXDB_ADMIN_PASSWORD)

GRAFANA_URL="http://localhost:3000"
GRAFANA_CREDS="${_user:-admin}:${_pass}"
# Helper: pass creds via process substitution (not visible in /proc cmdline)
_gcurl() { curl -sf -K <(printf 'user = "%s"\n' "$GRAFANA_CREDS") "$@"; }
CHRONOGRAF_URL="http://localhost:8888"
INFLUXDB_URL="http://localhost:8086"
INFLUXDB_CONTAINER="rpi-sim-influxdb"

PASS=0
FAIL=0
WARN=0

pass() {
    echo "  ✅ $1"
    ((PASS++))
}
fail() {
    echo "  ❌ $1"
    ((FAIL++))
}
warn() {
    echo "  ⚠️  $1"
    ((WARN++))
}

influx_query() {
    "$DOCKER" exec "$INFLUXDB_CONTAINER" influx \
        -username "${_influx_admin:-admin}" \
        -password "${_influx_admin_pass}" \
        -execute "$1" -database "${2:-}" 2>/dev/null
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

if influx_query "SHOW DATABASES" | grep -q speedtest; then
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

for db in speedtest telegraf; do
    if influx_query "SHOW DATABASES" | grep -q "^${db}$"; then
        pass "Database '$db' exists"
    else
        fail "Database '$db' missing"
    fi
done

GRANTS=$(influx_query "SHOW GRANTS FOR \"telegraf\"" 2>/dev/null)
for db in speedtest telegraf; do
    if echo "$GRANTS" | grep -q "$db.*ALL"; then
        pass "User 'telegraf' has ALL on '$db'"
    else
        fail "User 'telegraf' missing privileges on '$db'"
    fi
done

echo ""

# ── 5. Telegraf Pipeline ─────────────────────────────────────
echo "── 5. Telegraf Pipeline ──"

TELEGRAF_COUNT=$(influx_query "SELECT COUNT(usage_idle) FROM cpu WHERE time > now() - 5m" telegraf 2>/dev/null | tail -1 | awk '{print $2}')
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
QUERY_COUNT=$(influx_query "SELECT COUNT(download_bandwidth) FROM speedtest WHERE \"result_id\" = 'ci-smoke-test'" speedtest 2>/dev/null | tail -1 | awk '{print $2}')
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

for svc in grafana influxdb chronograf telegraf docker-socket-proxy speedtest-cron; do
    if "$DOCKER" ps --format '{{.Names}}' 2>/dev/null | grep -qi "$svc"; then
        pass "Container '$svc' running"
    else
        fail "Container '$svc' not running"
    fi
done

echo ""

# ── Summary ───────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════╗"
printf "║  Results: ✅ %-3d passed  ❌ %-3d failed  ⚠️  %-3d warnings ║\n" "$PASS" "$FAIL" "$WARN"
echo "╚══════════════════════════════════════════════════════════╝"

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
