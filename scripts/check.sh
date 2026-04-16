#!/usr/bin/env bash
# Quick health check of the 4 monitoring services.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../" && pwd)"
_influx_admin=$(grep '^INFLUXDB_ADMIN_USER=' "$SCRIPT_DIR/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
_influx_admin_pass=$(grep '^INFLUXDB_ADMIN_PASSWORD=' "$SCRIPT_DIR/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")

PASS=0
FAIL=0

for svc in "Grafana:http://localhost:3000/api/health" "Chronograf:http://localhost:8888/chronograf/v1/me"; do
    name=${svc%%:*}
    url=${svc#*:}
    if curl -sf "$url" >/dev/null 2>&1; then
        printf "  ✅ %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  ❌ %s\n" "$name"
        FAIL=$((FAIL + 1))
    fi
done

if docker exec influxdb influx -username "${_influx_admin:-admin}" -password "${_influx_admin_pass}" -execute "SHOW DATABASES" >/dev/null 2>&1; then
    printf "  ✅ InfluxDB\n"
    PASS=$((PASS + 1))
else
    printf "  ❌ InfluxDB\n"
    FAIL=$((FAIL + 1))
fi

if docker exec telegraf pgrep telegraf >/dev/null 2>&1; then
    printf "  ✅ Telegraf\n"
    PASS=$((PASS + 1))
else
    printf "  ❌ Telegraf\n"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "$PASS/$((PASS + FAIL)) services healthy"
