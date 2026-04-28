#!/usr/bin/env bash
# Preview the monitoring page locally using data from the live GitHub Pages
# or local test fixtures as fallback.
# Usage: bash scripts/preview-dev.sh [port]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-8080}"

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "╔══════════════════════════════════════════╗"
echo "║  Preview Dev — GitHub Pages Monitoring   ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Fetch data ─────────────────────────────────────────
# Try live site first, fall back to local fixtures
if curl -sfL "https://yoyonel.github.io/rpi-internet-monitoring/data.json" -o "$BUILD_DIR/data.json" &&
    curl -sfL "https://yoyonel.github.io/rpi-internet-monitoring/alerts.json" -o "$BUILD_DIR/alerts.json"; then
    echo "── Using live data from GitHub Pages ──"
else
    echo "── Live site unavailable, using local fixtures ──"
    cp "$SCRIPT_DIR/tests/fixtures/data.json" "$BUILD_DIR/"
    cp "$SCRIPT_DIR/tests/fixtures/alerts.json" "$BUILD_DIR/"
fi

# ── 2. Build page from template ──────────────────────────
bash "$SCRIPT_DIR/scripts/build-gh-pages.sh" "$BUILD_DIR" "$BUILD_DIR/data.json" "$BUILD_DIR/alerts.json"

# ── 3. Serve ─────────────────────────────────────────────
echo ""
echo "── Serving on http://localhost:${PORT} ──"
echo "  Press Ctrl+C to stop"
echo ""
cd "$BUILD_DIR" && python3 -c "
from http.server import SimpleHTTPRequestHandler
from socketserver import ThreadingTCPServer

class Handler(SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

ThreadingTCPServer.allow_reuse_address = True
with ThreadingTCPServer(('', $PORT), Handler) as s:
    s.serve_forever()
"
