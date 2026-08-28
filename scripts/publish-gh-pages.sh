#!/usr/bin/env bash
# Export speedtest data from InfluxDB or VictoriaMetrics and publish a static
# monitoring page.
#
# Usage: bash scripts/publish-gh-pages.sh [--preview] [--backend vm|influxdb] [days]
#   --preview           Build locally and serve on http://localhost:8080 (no push)
#   --backend vm        Use VictoriaMetrics instead of InfluxDB
#   --backend influxdb  Use InfluxDB (default)
#   days                Number of days of history to export (default: 30)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../" && pwd)"
# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/scripts/lib-common.sh"

detect_container_cli
load_env "$SCRIPT_DIR/.env"

# Parse args
PREVIEW=false
DAYS=30
BACKEND="${TSDB_BACKEND:-influxdb}"
for arg in "$@"; do
    case "$arg" in
        --preview) PREVIEW=true ;;
        --backend) : ;; # value handled below
        vm | influxdb) BACKEND="$arg" ;;
        *) DAYS="$arg" ;;
    esac
done

# ── 0. Sync local repo ───────────────────────────────────
echo "── Syncing local repo with origin/master ──"
if git -C "$SCRIPT_DIR" pull --ff-only origin master 2>&1; then
    echo "  → Repo updated"
else
    echo "  ⚠ WARNING: git pull failed — continuing with local version"
fi
echo ""

NOW=$(date -Iseconds)
REPO_URL=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "https://github.com/yoyonel/rpi-internet-monitoring.git")

# Load InfluxDB credentials: prefer env vars (set by Justfile dotenv-load), fallback to .env
_influx_admin=$(_read_env INFLUXDB_ADMIN_USER)
_influx_admin_pass=$(_read_env INFLUXDB_ADMIN_PASSWORD)

echo "╔══════════════════════════════════════════╗"
echo "║  Publish GitHub Pages — $NOW"
echo "║  Backend: $BACKEND"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Export data from TSDB ──────────────────────────────
echo "── Exporting last ${DAYS}d of speedtest data from ${BACKEND} ──"

if [[ "$BACKEND" == "vm" ]]; then
    VM_URL="${VICTORIA_METRICS_URL:-http://localhost:8428}"
    JSON_DATA=$(bash "$SCRIPT_DIR/scripts/export-vm-data.sh" "$VM_URL" "$DAYS")
else
    QUERY="SELECT download_bandwidth, upload_bandwidth, ping_latency FROM speedtest WHERE time > now() - ${DAYS}d ORDER BY time ASC"

    JSON_DATA=$("$DOCKER" exec influxdb influx \
        -username "${_influx_admin:-admin}" -password "${_influx_admin_pass}" \
        -execute "$QUERY" \
        -database speedtest \
        -precision rfc3339 \
        -format json 2>/dev/null)
fi

POINT_COUNT=$(echo "$JSON_DATA" | python3 "$SCRIPT_DIR/scripts/json-count-points.py")
echo "  → $POINT_COUNT data points exported"

if [[ "$POINT_COUNT" -eq 0 ]]; then
    echo "ERROR: No data found. Aborting."
    exit 1
fi

# ── 1b. Export alert status from Grafana ──────────────────
echo ""
echo "── Exporting alert status from Grafana ──"

# Load Grafana credentials: prefer env vars, fallback to .env
_gf_user=$(_read_env GF_SECURITY_ADMIN_USER)
_gf_pass=$(_read_env GF_SECURITY_ADMIN_PASSWORD)
setup_grafana_auth "$_gf_user" "$_gf_pass"

ALERTS_JSON=$(curl -sf -K <(printf 'user = "%s"\n' "$GRAFANA_CREDS") "http://localhost:3000/api/prometheus/grafana/api/v1/rules" 2>/dev/null || echo '{}')

ALERTS_DATA=$(echo "$ALERTS_JSON" | python3 "$SCRIPT_DIR/scripts/extract-alerts.py")
ALERT_COUNT=$(echo "$ALERTS_DATA" | python3 "$SCRIPT_DIR/scripts/extract-alerts.py" --count)
echo "  → $ALERT_COUNT alert rules exported"

# ── 2. Build the static page ─────────────────────────────
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "$JSON_DATA" >"$BUILD_DIR/data.json"
echo "$ALERTS_DATA" >"$BUILD_DIR/alerts.json"

echo ""
bash "$SCRIPT_DIR/scripts/build-gh-pages.sh" "$BUILD_DIR" "$BUILD_DIR/data.json" "$BUILD_DIR/alerts.json"

# ── 3. Preview or Push ────────────────────────────────────
if [[ "$PREVIEW" == "true" ]]; then
    echo ""
    echo "── Preview mode ──"
    echo "  Serving on http://localhost:8080"
    echo "  Press Ctrl+C to stop"
    echo ""
    cd "$BUILD_DIR"
    python3 "$SCRIPT_DIR/scripts/http-server.py" --port 8080
else
    echo ""
    echo "── Pushing to gh-pages branch ──"

    DEPLOY_DIR="/tmp/gh-pages-deploy"
    rm -rf "$DEPLOY_DIR"
    git clone --depth 1 --branch gh-pages "$REPO_URL" "$DEPLOY_DIR" 2>/dev/null || {
        mkdir -p "$DEPLOY_DIR" && cd "$DEPLOY_DIR" && git init -q && git checkout -q -b gh-pages
        git remote add origin "$REPO_URL"
    }
    cd "$DEPLOY_DIR"

    # Update site files (preserves badges/ and other extra content)
    cp "$BUILD_DIR"/index.html "$BUILD_DIR"/style.css .
    cp "$BUILD_DIR"/*.js .
    cp "$BUILD_DIR"/data.json "$BUILD_DIR"/alerts.json .
    cp -r "$BUILD_DIR"/fonts .
    touch .nojekyll

    git config user.email "gh-pages-bot@users.noreply.github.com"
    git config user.name "GitHub Pages Bot"
    git add -A
    if git diff --cached --quiet; then
        echo "  → No changes to push"
    else
        git commit -q -m "Update monitoring data — $NOW"
        git push -q origin gh-pages
        echo "  → Pushed to gh-pages branch"
    fi
    echo ""
    echo "── Done! ──"
    echo "  Page will be available at:"
    echo "  https://yoyonel.github.io/rpi-internet-monitoring/"
fi
