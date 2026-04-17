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

curl -sfL "https://yoyonel.github.io/rpi-internet-monitoring/" -o "$BUILD_DIR/live.html" ||
    {
        echo "ERROR: Could not fetch live page. Check your connection."
        exit 1
    }

python3 "$SCRIPT_DIR/scripts/extract-live-data.py" "$BUILD_DIR/live.html" "$BUILD_DIR"

# ── 2. Build page from template ──────────────────────────
echo ""
echo "── Building page from template ──"

python3 "$SCRIPT_DIR/scripts/render-template.py" "$TEMPLATE" "$BUILD_DIR/data.json" "$BUILD_DIR/alerts.json" "$BUILD_DIR/index.html"

# Copy static assets
cp "$SCRIPT_DIR/gh-pages/style.css" "$BUILD_DIR/"
cp -r "$SCRIPT_DIR/gh-pages/fonts" "$BUILD_DIR/"
if command -v terser &>/dev/null; then
    terser "$SCRIPT_DIR/gh-pages/app.js" --compress --mangle -o "$BUILD_DIR/app.js"
else
    cp "$SCRIPT_DIR/gh-pages/app.js" "$BUILD_DIR/"
fi

# ── 3. Serve ─────────────────────────────────────────────
echo ""
echo "── Serving on http://localhost:${PORT} ──"
echo "  Press Ctrl+C to stop"
echo ""
cd "$BUILD_DIR" && python3 -m http.server "$PORT"
