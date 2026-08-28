#!/usr/bin/env bash
# Export speedtest data from VictoriaMetrics in InfluxDB JSON format.
# Produces the same data.json format as publish-gh-pages.sh does from InfluxDB.
#
# Usage: bash scripts/export-vm-data.sh [vm_url] [days]
#   vm_url  VictoriaMetrics base URL (default: http://localhost:8428)
#   days    Number of days of history to export (default: 30)
#
# Output: JSON to stdout (pipe to file or preview script)
set -euo pipefail

VM_URL="${1:-http://localhost:8428}"
DAYS="${2:-30}"

# Remove trailing slash
VM_URL="${VM_URL%/}"

# ── Query each metric via VM export API ───────────────────
START=$(date -d "-${DAYS} days" +%s 2>/dev/null || date -v-"${DAYS}"d +%s)
END=$(date +%s)

fetch_metric() {
    local metric="$1"
    curl -sf "${VM_URL}/api/v1/export?match=${metric}&start=${START}&end=${END}" 2>/dev/null || echo ""
}

# Write JSONL to temp files (avoids ARG_MAX with large datasets)
TMPDIR_EXPORT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_EXPORT"' EXIT

fetch_metric "speedtest_download_bandwidth" >"$TMPDIR_EXPORT/dl.jsonl"
fetch_metric "speedtest_upload_bandwidth" >"$TMPDIR_EXPORT/ul.jsonl"
fetch_metric "speedtest_ping_latency" >"$TMPDIR_EXPORT/ping.jsonl"

if [[ ! -s "$TMPDIR_EXPORT/dl.jsonl" && ! -s "$TMPDIR_EXPORT/ul.jsonl" && ! -s "$TMPDIR_EXPORT/ping.jsonl" ]]; then
    echo "ERROR: No data found in VictoriaMetrics at ${VM_URL}" >&2
    exit 1
fi

# ── Transform to InfluxDB JSON format ─────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/vm-to-datajson.py" "$TMPDIR_EXPORT"
