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

# ── 0. Sync local repo ───────────────────────────────────
echo "── Syncing local repo with origin/master ──"
if git -C "$SCRIPT_DIR" pull --ff-only origin master 2>&1; then
    echo "  → Repo updated"
else
    echo "  ⚠ WARNING: git pull failed — continuing with local version"
fi
echo ""

NOW=$(date -Iseconds)
REPO_URL=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "https://github.com/yoyonel/rpi-internet-monitoring.git")

# Load InfluxDB credentials
_influx_admin=$(grep '^INFLUXDB_ADMIN_USER=' "$SCRIPT_DIR/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
_influx_admin_pass=$(grep '^INFLUXDB_ADMIN_PASSWORD=' "$SCRIPT_DIR/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")

echo "╔══════════════════════════════════════════╗"
echo "║  Publish GitHub Pages — $NOW"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Export data from InfluxDB ──────────────────────────
echo "── Exporting last ${DAYS}d of speedtest data from InfluxDB ──"

QUERY="SELECT download_bandwidth, upload_bandwidth, ping_latency FROM speedtest WHERE time > now() - ${DAYS}d ORDER BY time ASC"

JSON_DATA=$(docker exec influxdb influx \
    -username "${_influx_admin:-admin}" -password "${_influx_admin_pass}" \
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

ALERTS_JSON=$(curl -sf -K <(printf 'user = "%s"\n' "$GF_CREDS") "http://localhost:3000/api/prometheus/grafana/api/v1/rules" 2>/dev/null || echo '{}')

ALERTS_DATA=$(echo "$ALERTS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
alerts = []
last_eval = ''
for g in d.get('data', {}).get('groups', []):
    ge = g.get('lastEvaluation', '')
    if ge > last_eval: last_eval = ge
    for r in g.get('rules', []):
        val = ''
        re_val = r.get('lastEvaluation', ge)
        for a in r.get('alerts', []):
            s = a.get('annotations', {}).get('summary', '')
            if s: val = s
        alerts.append({
            'name': r['name'],
            'state': r['state'],
            'health': r.get('health', ''),
            'severity': r.get('labels', {}).get('severity', ''),
            'summary': val,
            'lastEvaluation': re_val
        })
print(json.dumps({'alerts': alerts, 'lastEvaluation': last_eval}))
")
ALERT_COUNT=$(echo "$ALERTS_DATA" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('alerts', d) if isinstance(d, dict) else d))")
echo "  → $ALERT_COUNT alert rules exported"

# ── 2. Build the static page ─────────────────────────────
echo ""
echo "── Building static page ──"

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

# Write data to temp files, then inject into template
echo "$JSON_DATA" >"$BUILD_DIR/data.json"
echo "$ALERTS_DATA" >"$BUILD_DIR/alerts.json"

python3 "$SCRIPT_DIR/scripts/render-template.py" "$TEMPLATE" "$BUILD_DIR/data.json" "$BUILD_DIR/alerts.json" "$BUILD_DIR/index.html"

# Copy static assets
cp "$SCRIPT_DIR/gh-pages/style.css" "$BUILD_DIR/"
if command -v terser &>/dev/null; then
    echo "  → Minifying app.js with terser"
    terser "$SCRIPT_DIR/gh-pages/app.js" --compress --mangle -o "$BUILD_DIR/app.js"
else
    cp "$SCRIPT_DIR/gh-pages/app.js" "$BUILD_DIR/"
fi

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
    touch .nojekyll
    git init -q
    git config user.email "gh-pages-bot@users.noreply.github.com"
    git config user.name "GitHub Pages Bot"
    git checkout -q -b gh-pages
    git add index.html style.css app.js .nojekyll
    git commit -q -m "Update monitoring data — $NOW"
    git remote add origin "$REPO_URL"
    git fetch origin gh-pages --depth=1 2>/dev/null || true
    git push --force-with-lease -q origin gh-pages

    echo "  → Pushed to gh-pages branch"
    echo ""
    echo "── Done! ──"
    echo "  Page will be available at:"
    echo "  https://yoyonel.github.io/rpi-internet-monitoring/"
fi
