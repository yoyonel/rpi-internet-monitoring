#!/usr/bin/env bash
# Fetch data from gh-pages branch and rebuild the page.
# Usage: fetch-and-build-gh-pages.sh <BUILD_DIR>
set -euo pipefail

BUILD_DIR="${1:?Usage: fetch-and-build-gh-pages.sh <BUILD_DIR>}"

mkdir -p "$BUILD_DIR"

echo "── Fetching data from gh-pages branch ──"
git show origin/gh-pages:data.json >"$BUILD_DIR/data.json" 2>/dev/null ||
    cp tests/fixtures/data.json "$BUILD_DIR/data.json"
git show origin/gh-pages:alerts.json >"$BUILD_DIR/alerts.json" 2>/dev/null ||
    cp tests/fixtures/alerts.json "$BUILD_DIR/alerts.json"

npm install -g terser
bash scripts/build-gh-pages.sh "$BUILD_DIR" "$BUILD_DIR/data.json" "$BUILD_DIR/alerts.json"
