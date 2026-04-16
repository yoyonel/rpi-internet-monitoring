#!/usr/bin/env bash
# Quick health check of the 4 monitoring services.
set -eo pipefail

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

if docker exec influxdb influx -execute "SHOW DATABASES" >/dev/null 2>&1; then
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
