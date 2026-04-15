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

# ── 3. Validate JS syntax ────────────────────────────────
echo ""
echo "── Validating JavaScript syntax ──"
python3 << CHECKEOF
import re, sys

with open("$BUILD_DIR/index.html") as f:
    html = f.read()

m = re.search(r'<script>(.*?)</script>', html, re.DOTALL)
if not m:
    print("  ⚠️  No <script> block found"); sys.exit(0)

js = m.group(1)
errors = []

# Check balanced braces/parens/brackets
for open_c, close_c, name in [('(',')', 'parentheses'), ('{','}', 'braces'), ('[',']', 'brackets')]:
    depth = 0
    for ch in js:
        if ch == open_c: depth += 1
        elif ch == close_c: depth -= 1
        if depth < 0: break
    if depth != 0:
        errors.append(f"Unbalanced {name} (depth={depth:+d})")

# Check forEach/function bodies
opens = len(re.findall(r'\.forEach\s*\(\s*function', js))
closes = len(re.findall(r'\}\s*\)', js))
if opens > closes:
    errors.append(f"Possible unclosed forEach callback ({opens} opens, {closes} closes)")

if errors:
    for e in errors:
        print(f"  ❌ {e}")
    sys.exit(1)
else:
    print("  ✅ JS syntax checks passed")
CHECKEOF

# ── 4. Preview or Push ────────────────────────────────────
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
    git add index.html
    git commit -q -m "Update monitoring data — $NOW"
    git remote add origin "$REPO_URL"
    git push -f -q origin gh-pages

    echo "  → Pushed to gh-pages branch"
    echo ""
    echo "── Done! ──"
    echo "  Page will be available at:"
    echo "  https://yoyonel.github.io/rpi-internet-monitoring/"
fi
