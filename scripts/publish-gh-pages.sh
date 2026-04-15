#!/usr/bin/env bash
# Export last 7 days of speedtest data from InfluxDB and publish
# a static monitoring page to the gh-pages branch on GitHub.
#
# Usage: bash scripts/publish-gh-pages.sh [days]
#   days  Number of days of history to export (default: 7)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$SCRIPT_DIR/gh-pages/index.template.html"
DAYS="${1:-7}"
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

# ── 2. Build the static page ─────────────────────────────
echo ""
echo "── Building static page ──"

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

LAST_UPDATE=$(date '+%d/%m/%Y %H:%M')
GENERATED_AT=$(date '+%d/%m/%Y à %H:%M:%S')

# Write data to temp file, then inject into template
echo "$JSON_DATA" > "$BUILD_DIR/data.json"

python3 << PYEOF
import json

with open("$TEMPLATE") as f:
    html = f.read()

with open("$BUILD_DIR/data.json") as f:
    data = f.read().strip()

html = html.replace('"__SPEEDTEST_DATA__"', data)
html = html.replace('__LAST_UPDATE__', '$LAST_UPDATE')
html = html.replace('__GENERATED_AT__', '$GENERATED_AT')

with open("$BUILD_DIR/index.html", "w") as f:
    f.write(html)

# Validate JSON was injected correctly
with open("$BUILD_DIR/index.html") as f:
    content = f.read()
assert '__SPEEDTEST_DATA__' not in content, "Data injection failed"
print("  → index.html generated ({:,} bytes)".format(len(content)))
PYEOF

# ── 3. Push to gh-pages branch ───────────────────────────
echo ""
echo "── Pushing to gh-pages branch ──"

cd "$BUILD_DIR"
git init -q
git config user.email "gh-pages-bot@users.noreply.github.com"
git config user.name "GitHub Pages Bot"
git checkout -q -b gh-pages
git add index.html
git commit -q -m "Update monitoring data — $NOW"
git remote add origin "$REPO_URL"
git push -f -q origin gh-pages

echo "  → Pushed to gh-pages branch"
echo ""
echo "── Done! ──"
echo "  Page will be available at:"
echo "  https://yoyonel.github.io/rpi-internet-monitoring/"
