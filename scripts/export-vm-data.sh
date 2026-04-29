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
python3 - "$TMPDIR_EXPORT" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone

tmpdir = sys.argv[1]

def parse_export(path):
    merged = {}
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return merged, []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            data = json.loads(line)
            ts_ms = data.get('timestamps', [])
            vals = data.get('values', [])
            for t, v in zip(ts_ms, vals):
                merged[t] = v
    return merged, sorted(merged.keys())

dl_map, dl_ts = parse_export(os.path.join(tmpdir, 'dl.jsonl'))
ul_map, ul_ts = parse_export(os.path.join(tmpdir, 'ul.jsonl'))
ping_map, ping_ts = parse_export(os.path.join(tmpdir, 'ping.jsonl'))

all_ts = sorted(set(dl_ts + ul_ts + ping_ts))

if not all_ts:
    print(json.dumps({'results': [{'series': []}]}))
    sys.exit(0)

values = []
for ts in all_ts:
    dt = datetime.fromtimestamp(ts / 1000, tz=timezone.utc)
    time_str = dt.strftime('%Y-%m-%dT%H:%M:%SZ')
    dl = dl_map.get(ts)
    ul = ul_map.get(ts)
    ping = ping_map.get(ts)
    if dl is None and ul is None and ping is None:
        continue
    values.append([time_str, dl, ul, ping])

result = {
    'results': [{
        'series': [{
            'name': 'speedtest',
            'columns': ['time', 'download_bandwidth', 'upload_bandwidth', 'ping_latency'],
            'values': values
        }]
    }]
}

print(json.dumps(result))
PYEOF
