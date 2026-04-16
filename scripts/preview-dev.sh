#!/usr/bin/env bash
# Preview the monitoring page locally using data from the live GitHub Pages.
# Usage: bash scripts/preview-dev.sh [port]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$SCRIPT_DIR/gh-pages/index.template.html"
PORT="${1:-8080}"

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "╔══════════════════════════════════════════╗"
echo "║  Preview Dev — GitHub Pages Monitoring   ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Fetch live data ────────────────────────────────────
echo "── Fetching data from live GitHub Pages ──"

curl -sf "https://yoyonel.github.io/rpi-internet-monitoring/" -o "$BUILD_DIR/live.html" \
    || { echo "ERROR: Could not fetch live page. Check your connection."; exit 1; }

python3 << PYEOF
import re, json

with open("$BUILD_DIR/live.html") as f:
    html = f.read()

m = re.search(r'(?:var|const)\s+RAW_DATA\s*=\s*({.*?});', html, re.DOTALL)
if not m:
    print("  ERROR: Could not extract speedtest data"); exit(1)
with open("$BUILD_DIR/data.json", "w") as f:
    f.write(m.group(1))
pts = len(json.loads(m.group(1)).get('results', [{}])[0].get('series', [{}])[0].get('values', []))

m2 = re.search(r'(?:var|const)\s+ALERTS\s*=\s*(\[.*?\]);', html, re.DOTALL)
if not m2:
    print("  ERROR: Could not extract alerts data"); exit(1)
with open("$BUILD_DIR/alerts.json", "w") as f:
    f.write(m2.group(1))
alerts_count = len(json.loads(m2.group(1)))

print(f"  → {pts} data points, {alerts_count} alerts")
PYEOF

# ── 2. Build page from template ──────────────────────────
echo ""
echo "── Building page from template ──"

python3 << PYEOF
from datetime import datetime

with open("$TEMPLATE") as f:
    html = f.read()
with open("$BUILD_DIR/data.json") as f:
    data = f.read()
with open("$BUILD_DIR/alerts.json") as f:
    alerts = f.read()

now = datetime.now().strftime('%d/%m/%Y %H:%M')
gen = datetime.now().strftime('%d/%m/%Y à %H:%M:%S')

html = html.replace('"__SPEEDTEST_DATA__"', data)
html = html.replace('"__ALERTS_DATA__"', alerts)
html = html.replace('__LAST_UPDATE__', now)
html = html.replace('__GENERATED_AT__', gen)

with open("$BUILD_DIR/index.html", "w") as f:
    f.write(html)
print(f"  → index.html ({len(html):,} bytes)")

assert '__SPEEDTEST_DATA__' not in html, "Data injection failed"
assert '__ALERTS_DATA__' not in html, "Alerts injection failed"
PYEOF

# ── 3. Serve ─────────────────────────────────────────────
echo ""
echo "── Serving on http://localhost:${PORT} ──"
echo "  Press Ctrl+C to stop"
echo ""
cd "$BUILD_DIR" && python3 -m http.server "$PORT"
