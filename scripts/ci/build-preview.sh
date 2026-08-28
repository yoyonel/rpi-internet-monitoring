#!/usr/bin/env bash
# Build the GitHub Pages preview from production data.
# Usage: build-preview.sh <BUILD_DIR>
set -euo pipefail

BUILD_DIR="${1:?Usage: build-preview.sh <BUILD_DIR>}"
PROD_URL="https://yoyonel.github.io/rpi-internet-monitoring"

mkdir -p "$BUILD_DIR"

echo "── Fetching data from production site ──"
curl -fsSL "$PROD_URL/data.json" -o "$BUILD_DIR/data.json"
curl -fsSL "$PROD_URL/alerts.json" -o "$BUILD_DIR/alerts.json"
echo "  data.json:   $(wc -c <"$BUILD_DIR/data.json") bytes"
echo "  alerts.json: $(wc -c <"$BUILD_DIR/alerts.json") bytes"

echo "── Verifying extract-live-data.py round-trip ──"
bash scripts/build-gh-pages.sh "$BUILD_DIR" "$BUILD_DIR/data.json" "$BUILD_DIR/alerts.json" "(PR preview)"
python3 scripts/extract-live-data.py "$BUILD_DIR/index.html" "$BUILD_DIR"
