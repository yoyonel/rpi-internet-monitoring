#!/usr/bin/env bash
# Fetch live data and alerts from production (RPi SSH or GitHub Pages)
# and save to tests/fixtures/ for offline local development and testing.
#
# Usage:
#   bash scripts/fetch-live-data.sh [rpi_host]
#   just fetch-live-data [rpi_host]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/tests/fixtures"
mkdir -p "$FIXTURES_DIR"

HOST="${1:-rpi4}"

echo "╔══════════════════════════════════════════╗"
echo "║  Fetch Live Data — Local Development     ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Fetch Speedtest Data ──────────────────────────────
echo "── Fetching speedtest data (source: $HOST) ──"
FETCHED=false

# Try SSH to RPi first if host is reachable
if ssh -q -o BatchMode=yes -o ConnectTimeout=3 "$HOST" exit 2>/dev/null; then
    echo "  → Querying InfluxDB directly on $HOST..."
    ssh "$HOST" "cd '/home/latty/Prog/MONITORER SON DÉBIT INTERNET/RPI' 2>/dev/null || cd ~/rpi-internet-monitoring 2>/dev/null; \
        docker exec influxdb influx \
            -username \"\${INFLUXDB_ADMIN_USER:-admin}\" \
            -password \"\${INFLUXDB_ADMIN_PASSWORD:-ycpU6eTji2W8cIzZuH8B}\" \
            -database speedtest \
            -precision rfc3339 \
            -format json \
            -execute 'SELECT download_bandwidth, upload_bandwidth, ping_latency FROM speedtest WHERE time > now() - 30d ORDER BY time ASC'" \
        >"$FIXTURES_DIR/data-live.json" 2>/dev/null || true

    if [[ -s "$FIXTURES_DIR/data-live.json" ]] && jq -e '.results[0].series[0].values' "$FIXTURES_DIR/data-live.json" >/dev/null 2>&1; then
        FETCHED=true
        COUNT=$(jq '.results[0].series[0].values | length' "$FIXTURES_DIR/data-live.json")
        echo "  ✅ Fetched $COUNT data points from InfluxDB on $HOST"
    fi
fi

# Fallback to GitHub Pages live data
if [[ "$FETCHED" != "true" ]]; then
    echo "  → Fallback: downloading data.json from GitHub Pages..."
    curl -sfL "https://yoyonel.github.io/rpi-internet-monitoring/data.json" -o "$FIXTURES_DIR/data-live.json"
    COUNT=$(jq '.results[0].series[0].values | length' "$FIXTURES_DIR/data-live.json")
    echo "  ✅ Fetched $COUNT data points from GitHub Pages"
fi

# ── 2. Fetch Grafana Alerts ──────────────────────────────
echo ""
echo "── Fetching Grafana alerts (source: $HOST) ──"
ALERTS_FETCHED=false

if ssh -q -o BatchMode=yes -o ConnectTimeout=3 "$HOST" exit 2>/dev/null; then
    echo "  → Querying Grafana rules API on $HOST..."
    ssh "$HOST" "cd '/home/latty/Prog/MONITORER SON DÉBIT INTERNET/RPI' 2>/dev/null || cd ~/rpi-internet-monitoring 2>/dev/null; \
        set -a; [ -f .env ] && . .env; set +a; \
        curl -s -u \"\${GF_SECURITY_ADMIN_USER:-admin}:\${GF_SECURITY_ADMIN_PASSWORD}\" http://localhost:3000/api/prometheus/grafana/api/v1/rules" |
        python3 "$SCRIPT_DIR/scripts/extract-alerts.py" \
            >"$FIXTURES_DIR/alerts-live.json" 2>/dev/null || true

    if [[ -s "$FIXTURES_DIR/alerts-live.json" ]] && jq -e '.alerts' "$FIXTURES_DIR/alerts-live.json" >/dev/null 2>&1; then
        ALERTS_FETCHED=true
        A_COUNT=$(jq '.alerts | length' "$FIXTURES_DIR/alerts-live.json")
        echo "  ✅ Fetched $A_COUNT alert rules from Grafana on $HOST"
    fi
fi

if [[ "$ALERTS_FETCHED" != "true" ]]; then
    echo "  → Fallback: downloading alerts.json from GitHub Pages..."
    curl -sfL "https://yoyonel.github.io/rpi-internet-monitoring/alerts.json" -o "$FIXTURES_DIR/alerts-live.json" || cp "$FIXTURES_DIR/alerts.json" "$FIXTURES_DIR/alerts-live.json"
    A_COUNT=$(jq '.alerts | length' "$FIXTURES_DIR/alerts-live.json")
    echo "  ✅ Fetched $A_COUNT alert rules from GitHub Pages"
fi

echo ""
echo "📁 Files saved:"
echo "  • tests/fixtures/data-live.json   ($COUNT points)"
echo "  • tests/fixtures/alerts-live.json ($A_COUNT alerts)"
echo ""
echo "💡 To preview locally with this data:"
echo "  just preview-live"
