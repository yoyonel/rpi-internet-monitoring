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

python3 "$SCRIPT_DIR/scripts/extract-live-data.py" "$BUILD_DIR/live.html" "$BUILD_DIR"

# ── 2. Build page from local template ────────────────────
echo ""
echo "── Building page from local template ──"

python3 "$SCRIPT_DIR/scripts/render-template.py" "$TEMPLATE" "$BUILD_DIR/data.json" "$BUILD_DIR/alerts.json" "$BUILD_DIR/index.html" "(template update)"

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
