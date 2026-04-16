#!/usr/bin/env bash
# Smoke tests for the monitoring stack.
# Run BEFORE and AFTER any upgrade to detect regressions.
# Usage: ./test-stack.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_user=$(grep '^GF_SECURITY_ADMIN_USER=' "$SCRIPT_DIR/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
_pass=$(grep '^GF_SECURITY_ADMIN_PASSWORD=' "$SCRIPT_DIR/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
_influx_admin=$(grep '^INFLUXDB_ADMIN_USER=' "$SCRIPT_DIR/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
_influx_admin_pass=$(grep '^INFLUXDB_ADMIN_PASSWORD=' "$SCRIPT_DIR/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
GRAFANA_URL="http://localhost:3000"
GRAFANA_CREDS="${_user:-admin}:${_pass}"
# Helper: pass creds via process substitution (not visible in /proc cmdline)
_gcurl() { curl -sf -K <(printf 'user = "%s"\n' "$GRAFANA_CREDS") "$@"; }
CHRONOGRAF_URL="http://localhost:8888"
INFLUXDB_CONTAINER="influxdb"

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
    docker exec "$INFLUXDB_CONTAINER" influx -username "${_influx_admin:-admin}" -password "${_influx_admin_pass}" -execute "$1" -database "${2:-}" 2>/dev/null
}

echo "╔══════════════════════════════════════════════════════════╗"
echo "║     Monitoring Stack — Regression Test Suite            ║"
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

# ── 2. Grafana Configuration ─────────────────────────────────
echo "── 2. Grafana Configuration ──"

DS_JSON=$(_gcurl "$GRAFANA_URL/api/datasources" 2>/dev/null || echo "[]")
DS_COUNT=$(echo "$DS_JSON" | jq length 2>/dev/null || echo 0)
if [[ "$DS_COUNT" -eq 2 ]]; then
    pass "Grafana has 2 datasources"
else
    fail "Grafana datasources: expected 2, got $DS_COUNT"
fi

if echo "$DS_JSON" | jq -e '.[] | select(.name == "InfluxDB")' >/dev/null 2>&1; then
    pass "Datasource 'InfluxDB' exists"
else
    fail "Datasource 'InfluxDB' missing"
fi

if echo "$DS_JSON" | jq -e '.[] | select(.name == "Telegraf")' >/dev/null 2>&1; then
    pass "Datasource 'Telegraf' exists"
else
    fail "Datasource 'Telegraf' missing"
fi

for ds_uid in $(echo "$DS_JSON" | jq -r '.[].uid' 2>/dev/null); do
    ds_name=$(echo "$DS_JSON" | jq -r --arg uid "$ds_uid" '.[] | select(.uid == $uid) | .name')
    if _gcurl -X POST "$GRAFANA_URL/api/datasources/uid/$ds_uid/health" 2>/dev/null | jq -e '.status == "OK"' >/dev/null 2>&1; then
        pass "Datasource '$ds_name' connectivity OK"
    else
        fail "Datasource '$ds_name' cannot connect to InfluxDB (check credentials)"
    fi
done

if _gcurl "$GRAFANA_URL/api/dashboards/uid/Ha9ke1iRk" 2>/dev/null | jq -e '.dashboard' >/dev/null 2>&1; then
    pass "Dashboard 'SpeedTest' exists (uid=Ha9ke1iRk)"
else
    fail "Dashboard 'SpeedTest' missing"
fi

if _gcurl "$GRAFANA_URL/api/dashboards/uid/000000128" 2>/dev/null | jq -e '.dashboard' >/dev/null 2>&1; then
    pass "Dashboard 'System' exists (uid=000000128)"
else
    fail "Dashboard 'System' missing"
fi

echo ""

# ── 3. Data Pipeline ─────────────────────────────────────────
echo "── 3. Data Pipeline ──"

TELEGRAF_COUNT=$(influx_query "SELECT COUNT(usage_idle) FROM cpu WHERE time > now() - 2m" telegraf 2>/dev/null | tail -1 | awk '{print $2}')
if [[ -n "$TELEGRAF_COUNT" && "$TELEGRAF_COUNT" =~ ^[0-9]+$ && "$TELEGRAF_COUNT" -gt 0 ]]; then
    pass "Telegraf → InfluxDB pipeline active ($TELEGRAF_COUNT points in last 2 min)"
else
    fail "Telegraf → InfluxDB pipeline broken (0 points in last 2 min)"
fi

SPEEDTEST_COUNT=$(influx_query "SELECT COUNT(download_bandwidth) FROM speedtest" speedtest 2>/dev/null | tail -1 | awk '{print $2}')
if [[ -n "$SPEEDTEST_COUNT" && "$SPEEDTEST_COUNT" =~ ^[0-9]+$ && "$SPEEDTEST_COUNT" -ge 122000 ]]; then
    pass "Speedtest data preserved ($SPEEDTEST_COUNT points, ≥122k)"
else
    fail "Speedtest data loss (got ${SPEEDTEST_COUNT:-0}, expected ≥122k)"
fi

echo ""

# ── 4. Data Integrity ────────────────────────────────────────
echo "── 4. Data Integrity ──"

FOUND_SPEEDTEST=$(influx_query "SHOW DATABASES" | grep -c "^speedtest$" || echo 0)
FOUND_TELEGRAF=$(influx_query "SHOW DATABASES" | grep -c "^telegraf$" || echo 0)
if [[ "$FOUND_SPEEDTEST" -ge 1 && "$FOUND_TELEGRAF" -ge 1 ]]; then
    pass "Required databases present (speedtest, telegraf)"
else
    fail "Missing databases — speedtest=$FOUND_SPEEDTEST telegraf=$FOUND_TELEGRAF"
fi

MEASUREMENTS=$(influx_query "SHOW MEASUREMENTS" speedtest 2>/dev/null | grep -c "^[a-z]" || echo 0)
if [[ "$MEASUREMENTS" -ge 1 ]]; then
    pass "Speedtest DB has $MEASUREMENTS measurement(s)"
else
    fail "Speedtest DB has no measurements"
fi

echo ""

# ── 5. Container State ───────────────────────────────────────
echo "── 5. Container State ──"

for svc in grafana influxdb chronograf telegraf; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "$svc"; then
        pass "Container '$svc' running"
    else
        fail "Container '$svc' not running"
    fi
done

STOPPED=$(docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | wc -l)
if [[ "$STOPPED" -gt 0 ]]; then
    warn "$STOPPED stopped container(s) (cleanup recommended)"
else
    pass "No stopped containers"
fi

echo ""

# ── Summary ───────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════╗"
printf "║  Results: ✅ %-3d passed  ❌ %-3d failed  ⚠️  %-3d warnings ║\n" "$PASS" "$FAIL" "$WARN"
echo "╚══════════════════════════════════════════════════════════╝"

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
