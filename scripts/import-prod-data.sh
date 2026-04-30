#!/usr/bin/env bash
# Import production data from GitHub Pages into local sim databases.
# Downloads data.json and writes to both InfluxDB and VictoriaMetrics.
#
# Usage: bash scripts/import-prod-data.sh [data_url]
#   data_url: defaults to https://yoyonel.github.io/rpi-internet-monitoring/data.json
#
# Requires: curl, python3, jq
# Env vars (from sim/.env.sim): INFLUXDB_USER, INFLUXDB_USER_PASSWORD
set -euo pipefail

DATA_URL="${1:-https://yoyonel.github.io/rpi-internet-monitoring/data.json}"
INFLUXDB_URL="http://localhost:8086"
VM_URL="http://localhost:8428"
DB="speedtest"

# Load sim env for credentials
if [[ -f sim/.env.sim ]]; then
    set -a
    # shellcheck disable=SC1091
    . sim/.env.sim
    set +a
fi
INFLUX_USER="${INFLUXDB_USER:-telegraf}"
INFLUX_PASS="${INFLUXDB_USER_PASSWORD:-simpass}"
ADMIN_USER="${INFLUXDB_ADMIN_USER:-admin}"
ADMIN_PASS="${INFLUXDB_ADMIN_PASSWORD:-simpass}"

echo "⬇  Downloading prod data from ${DATA_URL}..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
curl -sf "$DATA_URL" -o "$TMPDIR/data.json"
COUNT=$(jq '.results[0].series[0].values | length' "$TMPDIR/data.json")
echo "   $COUNT data points downloaded"

echo "🔄 Converting to InfluxDB line protocol + Prometheus format..."
python3 "$(dirname "$0")/convert-datajson.py" "$TMPDIR/data.json" "$TMPDIR"

# --- InfluxDB import ---
echo ""
echo "📥 Importing into InfluxDB ($INFLUXDB_URL, db=$DB)..."
# Drop existing measurement to avoid type conflicts
curl -sf -XPOST "$INFLUXDB_URL/query?db=$DB" \
    -u "$ADMIN_USER:$ADMIN_PASS" \
    --data-urlencode 'q=DROP MEASUREMENT speedtest' >/dev/null 2>&1 || true
HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -XPOST "$INFLUXDB_URL/write?db=$DB&precision=ns" \
    -u "$INFLUX_USER:$INFLUX_PASS" \
    --data-binary @"$TMPDIR/influx.line")
if [[ "$HTTP" == "204" ]]; then
    INFLUX_COUNT=$(curl -s -G "$INFLUXDB_URL/query" \
        --data-urlencode "db=$DB" \
        --data-urlencode 'q=SELECT count("download_bandwidth") FROM "speedtest"' \
        -u "$INFLUX_USER:$INFLUX_PASS" | jq '.results[0].series[0].values[0][1]')
    echo "   ✅ InfluxDB: $INFLUX_COUNT points written"
else
    echo "   ❌ InfluxDB write failed (HTTP $HTTP)"
    exit 1
fi

# --- VictoriaMetrics import ---
if curl -sf "$VM_URL/health" >/dev/null 2>&1; then
    echo "📥 Importing into VictoriaMetrics ($VM_URL)..."
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        -XPOST "$VM_URL/api/v1/import/prometheus" \
        --data-binary @"$TMPDIR/vm.prom")
    if [[ "$HTTP" == "204" ]]; then
        VM_COUNT=$(curl -gs "$VM_URL/api/v1/query?query=count_over_time(speedtest_download_bandwidth[60d])" |
            jq '.data.result[0].value[1]' -r)
        echo "   ✅ VictoriaMetrics: $VM_COUNT points written"
    else
        echo "   ❌ VictoriaMetrics write failed (HTTP $HTTP)"
        exit 1
    fi
else
    echo "⏭  VictoriaMetrics not running, skipping"
fi

echo ""
echo "✅ Import complete — $COUNT prod data points in both databases"
