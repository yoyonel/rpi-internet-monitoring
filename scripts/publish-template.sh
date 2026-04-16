#!/usr/bin/env bash
# Publish the monitoring page template to GitHub Pages using live data.
# This works from ANY machine (no RPi / InfluxDB needed).
#
# It fetches the current data from the live GitHub Pages, injects it
# into the local template, and pushes the result to the gh-pages branch.
#
# Usage: bash scripts/publish-template.sh [--preview]
#   --preview  Build locally and serve on http://localhost:8080 (no push)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$SCRIPT_DIR/gh-pages/index.template.html"
LIVE_URL="https://yoyonel.github.io/rpi-internet-monitoring/"
REPO_URL=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "https://github.com/yoyonel/rpi-internet-monitoring.git")

PREVIEW=false
[[ "${1:-}" == "--preview" ]] && PREVIEW=true

NOW=$(date -Iseconds)

echo "╔══════════════════════════════════════════════════╗"
echo "║  Publish Template — using live GH Pages data    ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

# ── 1. Fetch live data from GitHub Pages ──────────────────
echo "── Fetching data from live GitHub Pages ──"

curl -sfL "$LIVE_URL" -o "$BUILD_DIR/live.html" \
    || { echo "ERROR: Could not fetch $LIVE_URL"; exit 1; }

python3 << PYEOF
import re, json, sys

with open("$BUILD_DIR/live.html") as f:
    html = f.read()

m = re.search(r'(?:var|const)\s+RAW_DATA\s*=\s*({.*?});', html, re.DOTALL)
if not m:
    print("  ERROR: Could not extract RAW_DATA from live page"); sys.exit(1)
with open("$BUILD_DIR/data.json", "w") as f:
    f.write(m.group(1))

m2 = re.search(r'(?:var|const)\s+ALERTS\s*=\s*(\[.*?\]);', html, re.DOTALL)
if not m2:
    print("  ERROR: Could not extract ALERTS from live page"); sys.exit(1)
with open("$BUILD_DIR/alerts.json", "w") as f:
    f.write(m2.group(1))

data = json.loads(m.group(1))
pts = len(data.get('results', [{}])[0].get('series', [{}])[0].get('values', []))
alerts = json.loads(m2.group(1))
print(f"  → {pts} data points, {len(alerts)} alerts extracted from live page")
PYEOF

# ── 2. Build page from local template ────────────────────
echo ""
echo "── Building page from local template ──"

LAST_UPDATE=$(date '+%d/%m/%Y %H:%M')
GENERATED_AT=$(date '+%d/%m/%Y à %H:%M:%S')

python3 << PYEOF
with open("$TEMPLATE") as f:
    html = f.read()
with open("$BUILD_DIR/data.json") as f:
    data = f.read().strip()
with open("$BUILD_DIR/alerts.json") as f:
    alerts = f.read().strip()

html = html.replace('"__SPEEDTEST_DATA__"', data)
html = html.replace('"__ALERTS_DATA__"', alerts)
html = html.replace('__LAST_UPDATE__', '$LAST_UPDATE')
html = html.replace('__GENERATED_AT__', '$GENERATED_AT (template update)')

with open("$BUILD_DIR/index.html", "w") as f:
    f.write(html)

assert '__SPEEDTEST_DATA__' not in html, "Data injection failed"
assert '__ALERTS_DATA__' not in html, "Alerts injection failed"
print("  → index.html ({:,} bytes)".format(len(html)))
PYEOF

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
    git commit -q -m "Update template — $NOW (data from live page)"
    git remote add origin "$REPO_URL"
    git push -f -q origin gh-pages

    echo "  → Pushed to gh-pages branch"
    echo ""
    echo "── Done! ──"
    echo "  Page will be available shortly at:"
    echo "  $LIVE_URL"
fi
