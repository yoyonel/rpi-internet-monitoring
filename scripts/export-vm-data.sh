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

DL_JSON=$(fetch_metric "speedtest_download_bandwidth")
UL_JSON=$(fetch_metric "speedtest_upload_bandwidth")
PING_JSON=$(fetch_metric "speedtest_ping_latency")

if [[ -z "$DL_JSON" && -z "$UL_JSON" && -z "$PING_JSON" ]]; then
    echo "ERROR: No data found in VictoriaMetrics at ${VM_URL}" >&2
    exit 1
fi

# ── Transform to InfluxDB JSON format ─────────────────────
python3 -c "
import json, sys
from datetime import datetime, timezone

# Parse JSONL lines (one per metric)
def parse_export(raw):
    if not raw.strip():
        return {}, []
    data = json.loads(raw)
    ts_ms = data.get('timestamps', [])
    vals = data.get('values', [])
    # Return dict: timestamp_ms -> value
    return dict(zip(ts_ms, vals)), sorted(ts_ms)

dl_map, dl_ts = parse_export('''$DL_JSON''')
ul_map, ul_ts = parse_export('''$UL_JSON''')
ping_map, ping_ts = parse_export('''$PING_JSON''')

# Merge all timestamps
all_ts = sorted(set(dl_ts + ul_ts + ping_ts))

if not all_ts:
    print(json.dumps({'results': [{'series': []}]}))
    sys.exit(0)

# Build InfluxDB-compatible values array
values = []
for ts in all_ts:
    # Convert ms to RFC3339
    dt = datetime.fromtimestamp(ts / 1000, tz=timezone.utc)
    time_str = dt.strftime('%Y-%m-%dT%H:%M:%SZ')
    dl = dl_map.get(ts)
    ul = ul_map.get(ts)
    ping = ping_map.get(ts)
    # Skip rows where all values are None
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
"
