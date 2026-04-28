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

# ── 1. Fetch data from live site or gh-pages branch ───────
DATA_SOURCE="fixtures"

if curl -sfL "${LIVE_URL}data.json" -o "$BUILD_DIR/data.json" &&
    curl -sfL "${LIVE_URL}alerts.json" -o "$BUILD_DIR/alerts.json"; then
    DATA_SOURCE="live"
    echo "── Using live data from GitHub Pages ──"
elif git -C "$SCRIPT_DIR" show origin/gh-pages:data.json >"$BUILD_DIR/data.json" 2>/dev/null &&
    git -C "$SCRIPT_DIR" show origin/gh-pages:alerts.json >"$BUILD_DIR/alerts.json" 2>/dev/null; then
    DATA_SOURCE="gh-pages branch"
    echo "── Using data from gh-pages branch ──"
else
    echo "── Using local fixtures ──"
    cp "$SCRIPT_DIR/tests/fixtures/data.json" "$BUILD_DIR/"
    cp "$SCRIPT_DIR/tests/fixtures/alerts.json" "$BUILD_DIR/"
fi

# ── 2. Build page from local template ────────────────────
echo ""
bash "$SCRIPT_DIR/scripts/build-gh-pages.sh" "$BUILD_DIR" "$BUILD_DIR/data.json" "$BUILD_DIR/alerts.json" "(template update)"

# ── 3. Preview or Push ────────────────────────────────────
if [[ "$PREVIEW" == "true" ]]; then
    echo ""
    echo "── Preview mode ──"
    echo "  Serving on http://localhost:8080"
    echo "  Press Ctrl+C to stop"
    echo ""
    cd "$BUILD_DIR"
    python3 -c "
from http.server import SimpleHTTPRequestHandler
from socketserver import ThreadingTCPServer

class Handler(SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

ThreadingTCPServer.allow_reuse_address = True
with ThreadingTCPServer(('', 8080), Handler) as s:
    s.serve_forever()
"
else
    echo ""
    echo "── Pushing to gh-pages branch ──"

    cd "$BUILD_DIR"
    touch .nojekyll
    git init -q
    git config user.email "gh-pages-bot@users.noreply.github.com"
    git config user.name "GitHub Pages Bot"
    git checkout -q -b gh-pages
    git add index.html style.css ./*.js data.json alerts.json fonts/ .nojekyll
    git commit -q -m "Update template — $NOW (data from $DATA_SOURCE)"
    git remote add origin "$REPO_URL"
    git push --force-with-lease -q origin gh-pages

    echo "  → Pushed to gh-pages branch"
    echo ""
    echo "── Done! ──"
    echo "  Page will be available shortly at:"
    echo "  $LIVE_URL"
fi
