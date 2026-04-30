#!/usr/bin/env bash
# Preview the monitoring page locally using data from the live GitHub Pages
# or local test fixtures as fallback.
# Usage: bash scripts/preview-dev.sh [port] [--data <path>]
#   --data <path>  Use a custom data.json file instead of fetching from GH Pages
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="8080"
DATA_PATH=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data)
            DATA_PATH="$2"
            shift 2
            ;;
        --data=*)
            DATA_PATH="${1#--data=}"
            shift
            ;;
        *)
            PORT="$1"
            shift
            ;;
    esac
done

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "╔══════════════════════════════════════════╗"
echo "║  Preview Dev — GitHub Pages Monitoring   ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Fetch data ─────────────────────────────────────────
if [[ -n "$DATA_PATH" ]]; then
    echo "── Using custom data: $DATA_PATH ──"
    cp "$DATA_PATH" "$BUILD_DIR/data.json"
    # Use fixture alerts if no alerts file alongside the data
    ALERTS_PATH="${DATA_PATH%/*}/alerts.json"
    if [[ -f "$ALERTS_PATH" ]]; then
        cp "$ALERTS_PATH" "$BUILD_DIR/alerts.json"
    else
        cp "$SCRIPT_DIR/tests/fixtures/alerts.json" "$BUILD_DIR/"
    fi
elif curl -sfL "https://yoyonel.github.io/rpi-internet-monitoring/data.json" -o "$BUILD_DIR/data.json" &&
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
cd "$BUILD_DIR" && python3 "$SCRIPT_DIR/scripts/http-server.py" --port "$PORT"
