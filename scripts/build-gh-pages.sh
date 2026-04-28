#!/usr/bin/env bash
# Build a complete static monitoring site from template + data.
#
# Usage: build-gh-pages.sh <build_dir> <data_json> <alerts_json> [suffix]
#
# Arguments:
#   build_dir    Directory to write the built site into (must exist)
#   data_json    Path to data.json
#   alerts_json  Path to alerts.json
#   suffix       Optional suffix for render-template.py (e.g. "(PR preview)")
#
# The script renders index.html, copies static assets (CSS, fonts),
# and minifies JS modules with terser when available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$SCRIPT_DIR/gh-pages/index.template.html"

BUILD_DIR="${1:?Usage: build-gh-pages.sh <build_dir> <data_json> <alerts_json> [suffix]}"
DATA_JSON="${2:?Missing data_json argument}"
ALERTS_JSON="${3:?Missing alerts_json argument}"
SUFFIX="${4:-}"

echo "── Building page from template ──"

# Render HTML
python3 "$SCRIPT_DIR/scripts/render-template.py" \
    "$TEMPLATE" "$DATA_JSON" "$ALERTS_JSON" "$BUILD_DIR/index.html" "$SUFFIX"

# Copy static assets
cp "$SCRIPT_DIR/gh-pages/style.css" "$BUILD_DIR/"
cp -r "$SCRIPT_DIR/gh-pages/fonts" "$BUILD_DIR/"

# JS modules — minify with terser when available, plain copy otherwise
JS_MODULES=(app.js lib.js state.js sync-status.js alerts.js charts.js time-controls.js time-picker.js status-bar.js)
if command -v terser &>/dev/null; then
    for f in "${JS_MODULES[@]}"; do
        terser "$SCRIPT_DIR/gh-pages/$f" --compress --mangle --module -o "$BUILD_DIR/$f"
    done
else
    for f in "${JS_MODULES[@]}"; do
        cp "$SCRIPT_DIR/gh-pages/$f" "$BUILD_DIR/"
    done
fi
