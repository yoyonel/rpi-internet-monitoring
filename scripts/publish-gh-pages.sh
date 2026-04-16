#!/usr/bin/env bash
# Export speedtest data from InfluxDB and publish a static monitoring page.
#
# Usage: bash scripts/publish-gh-pages.sh [--preview] [days]
#   --preview  Build locally and serve on http://localhost:8080 (no push)
#   days       Number of days of history to export (default: 30)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../" && pwd)"
TEMPLATE="$SCRIPT_DIR/gh-pages/index.template.html"

# Parse args
PREVIEW=false
DAYS=30
for arg in "$@"; do
    case "$arg" in
        --preview) PREVIEW=true ;;
        *) DAYS="$arg" ;;
    esac
done

NOW=$(date -Iseconds)
REPO_URL=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "https://github.com/yoyonel/rpi-internet-monitoring.git")

echo "╔══════════════════════════════════════════╗"
echo "║  Publish GitHub Pages — $NOW"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Export data from InfluxDB ──────────────────────────
echo "── Exporting last ${DAYS}d of speedtest data from InfluxDB ──"

QUERY="SELECT download_bandwidth, upload_bandwidth, ping_latency FROM speedtest WHERE time > now() - ${DAYS}d ORDER BY time ASC"

JSON_DATA=$(docker exec influxdb influx \
    -execute "$QUERY" \
    -database speedtest \
    -precision rfc3339 \
    -format json 2>/dev/null)

POINT_COUNT=$(echo "$JSON_DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
s = d.get('results', [{}])[0].get('series', [{}])
print(len(s[0].get('values', [])) if s else 0)
")
echo "  → $POINT_COUNT data points exported"

if [[ "$POINT_COUNT" -eq 0 ]]; then
    echo "ERROR: No data found. Aborting."
    exit 1
fi

# ── 1b. Export alert status from Grafana ──────────────────
echo ""
echo "── Exporting alert status from Grafana ──"

# Load Grafana credentials
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    _gf_user=$(grep '^GF_SECURITY_ADMIN_USER=' "$SCRIPT_DIR/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    _gf_pass=$(grep '^GF_SECURITY_ADMIN_PASSWORD=' "$SCRIPT_DIR/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
fi
GF_CREDS="${_gf_user:-admin}:${_gf_pass:?GF_SECURITY_ADMIN_PASSWORD not set}"

ALERTS_JSON=$(curl -sf -u "$GF_CREDS" "http://localhost:3000/api/prometheus/grafana/api/v1/rules" 2>/dev/null || echo '{}')

ALERTS_DATA=$(echo "$ALERTS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
alerts = []
for g in d.get('data', {}).get('groups', []):
    for r in g.get('rules', []):
        val = ''
        for a in r.get('alerts', []):
            s = a.get('annotations', {}).get('summary', '')
            if s: val = s
        alerts.append({
            'name': r['name'],
            'state': r['state'],
            'health': r.get('health', ''),
            'severity': r.get('labels', {}).get('severity', ''),
            'summary': val
        })
print(json.dumps(alerts))
")
ALERT_COUNT=$(echo "$ALERTS_DATA" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
echo "  → $ALERT_COUNT alert rules exported"

# ── 2. Build the static page ─────────────────────────────
echo ""
echo "── Building static page ──"

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

# Write data to temp files, then inject into template
echo "$JSON_DATA" > "$BUILD_DIR/data.json"
echo "$ALERTS_DATA" > "$BUILD_DIR/alerts.json"

python3 "$SCRIPT_DIR/scripts/render-template.py" "$TEMPLATE" "$BUILD_DIR/data.json" "$BUILD_DIR/alerts.json" "$BUILD_DIR/index.html"

# Copy static assets
cp "$SCRIPT_DIR/gh-pages/style.css" "$SCRIPT_DIR/gh-pages/app.js" "$BUILD_DIR/"

# ── 3. Preview or Push ────────────────────────────────────
if [[ "$PREVIEW" == "true" ]]; then
    echo ""
    echo "── Preview mode ──"
    echo "  Serving on http://localhost:8080"
    echo "  Press Ctrl+C to stop"
    echo ""
    cd "$BUILD_DIR"
    python3 -m http.server 8080
else
    echo ""
    echo "── Pushing to gh-pages branch ──"

    cd "$BUILD_DIR"
    git init -q
    git config user.email "gh-pages-bot@users.noreply.github.com"
    git config user.name "GitHub Pages Bot"
    git checkout -q -b gh-pages
    git add index.html style.css app.js
    git commit -q -m "Update monitoring data — $NOW"
    git remote add origin "$REPO_URL"
    git push -f -q origin gh-pages

    echo "  → Pushed to gh-pages branch"
    echo ""
    echo "── Done! ──"
    echo "  Page will be available at:"
    echo "  https://yoyonel.github.io/rpi-internet-monitoring/"
fi
