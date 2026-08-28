#!/usr/bin/env bash
# Prepare the preview site directory for GitHub Pages deployment.
# Usage: prepare-preview-site.sh <BUILD_DIR> <OUTPUT_DIR>
set -euo pipefail

BUILD_DIR="${1:?Usage: prepare-preview-site.sh <BUILD_DIR> <OUTPUT_DIR>}"
OUTPUT_DIR="${2:?Usage: prepare-preview-site.sh <BUILD_DIR> <OUTPUT_DIR>}"

mkdir -p "$OUTPUT_DIR"
cp "$BUILD_DIR"/index.html "$BUILD_DIR"/style.css "$OUTPUT_DIR/"
cp "$BUILD_DIR"/data.json "$BUILD_DIR"/alerts.json "$OUTPUT_DIR/"
cp "$BUILD_DIR"/*.js "$OUTPUT_DIR/"
cp -r "$BUILD_DIR"/fonts "$OUTPUT_DIR/"
# Include E2E screenshot if available
if [[ -f test-results/preview.png ]]; then
    cp test-results/preview.png "$OUTPUT_DIR/"
fi
