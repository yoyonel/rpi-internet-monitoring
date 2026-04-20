#!/usr/bin/env bash
# Verify that a backup restore in the sim stack produced valid data.
#
# Usage: bash scripts/sim-verify-backup.sh
#
# Checks:
#   1. Databases speedtest and telegraf exist
#   2. Count of download_bandwidth in speedtest (expected ~122 968)
#   3. First measurement date (expected ~2022-11-25)
#   4. Last measurement date (expected near backup date)
#   5. Grafana dashboards are loaded and accessible
#   6. Grafana datasource connectivity
#
# Exit code: 0 if all critical checks pass, 1 otherwise
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Detect container CLI ─────────────────────────────────
# shellcheck disable=SC2034  # DOCKER used by future extensions
if [[ -n "${CONTAINER_CLI:-}" ]]; then
    DOCKER="$CONTAINER_CLI"
elif command -v docker >/dev/null 2>&1; then
    DOCKER=docker
elif command -v podman >/dev/null 2>&1; then
    DOCKER=podman
else
    DOCKER=docker
fi

# shellcheck disable=SC2034  # INFLUX_CONTAINER used by future extensions
INFLUX_CONTAINER="rpi-sim-influxdb"
INFLUXDB_URL="http://localhost:8086"
GRAFANA_URL="http://localhost:3000"

# ── Read sim credentials ─────────────────────────────────
ENV_FILE="$PROJECT_DIR/sim/.env.sim"
_read_env() { grep "^$1=" "$ENV_FILE" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//"; }
INFLUX_USER=$(_read_env INFLUXDB_ADMIN_USER)
INFLUX_PASS=$(_read_env INFLUXDB_ADMIN_PASSWORD)
GRAFANA_USER=$(_read_env GF_SECURITY_ADMIN_USER)
GRAFANA_PASS=$(_read_env GF_SECURITY_ADMIN_PASSWORD)
GRAFANA_CREDS="${GRAFANA_USER:-admin}:${GRAFANA_PASS}"
_gcurl() { curl -sf -K <(printf 'user = "%s"\n' "$GRAFANA_CREDS") "$@"; }

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
    local query="$1" database="${2:-}"
    curl -sfG \
        -u "${INFLUX_USER:-admin}:${INFLUX_PASS}" \
        --data-urlencode "q=$query" \
        ${database:+--data-urlencode "db=$database"} \
        "$INFLUXDB_URL/query"
}

echo "╔══════════════════════════════════════════════════════════╗"
echo "║     Sim Stack — Verify Backup Integrity                  ║"
echo "║     $(date -Iseconds)                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
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

# ── 3. First measurement date ────────────────────────────
echo "── 3. Date range ──"
FIRST_JSON=$(influx_query "SELECT download_bandwidth FROM speedtest ORDER BY time ASC LIMIT 1" speedtest)
FIRST_TIME=$(echo "$FIRST_JSON" | jq -r '.results[]?.series[]?.values[]?[0] // empty' | head -1)

if [[ -n "$FIRST_TIME" ]]; then
    echo "  📅 First measurement: $FIRST_TIME"
    # Check if it's in 2022
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
    # Check if it's in 2026
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

# ── 5. Grafana datasources ──────────────────────────────
echo "── 5. Grafana datasources ──"
DS_JSON=$(_gcurl "$GRAFANA_URL/api/datasources" 2>/dev/null || echo "[]")
DS_COUNT=$(echo "$DS_JSON" | jq length 2>/dev/null || echo 0)

if [[ "$DS_COUNT" -ge 2 ]]; then
    pass "Grafana has $DS_COUNT datasource(s)"
else
    warn "Grafana datasources: expected ≥2, got $DS_COUNT"
fi

for ds_uid in $(echo "$DS_JSON" | jq -r '.[].uid' 2>/dev/null); do
    ds_name=$(echo "$DS_JSON" | jq -r --arg uid "$ds_uid" '.[] | select(.uid == $uid) | .name')
    if _gcurl -X POST "$GRAFANA_URL/api/datasources/uid/$ds_uid/health" 2>/dev/null | jq -e '.status == "OK"' >/dev/null 2>&1; then
        pass "Datasource '$ds_name' → InfluxDB connectivity OK"
    else
        fail "Datasource '$ds_name' cannot reach InfluxDB"
    fi
done
echo ""

# ── 6. Grafana dashboards ───────────────────────────────
echo "── 6. Grafana dashboards ──"
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
echo "╔══════════════════════════════════════════════════════════╗"
printf "║  Results: ✅ %-3d passed  ❌ %-3d failed  ⚠️  %-3d warnings ║\n" "$PASS" "$FAIL" "$WARN"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
    echo "🟢 VERDICT: Backup is EXPLOITABLE — data restored successfully."
    exit 0
else
    echo "🔴 VERDICT: Backup has ISSUES — $FAIL check(s) failed."
    exit 1
fi
