#!/usr/bin/env bash
# Write test data to VictoriaMetrics for smoke tests.
# Outputs TS_SEC to stdout (caller should capture it).
set -euo pipefail

VM_URL="${VM_URL:-http://localhost:8428}"

TS=$(date +%s)000000000

curl -sf -d "cpu,cpu=cpu-total,host=ci usage_idle=95.2,usage_system=2.1 $TS" \
    "$VM_URL/write?db=telegraf"
curl -sf -d "mem,host=ci used_percent=42.5 $TS" \
    "$VM_URL/write?db=telegraf"

SPD="speedtest,result_id=test-001"
SPD="$SPD ping_latency=11.6"
SPD="$SPD,download_bandwidth=941000000"
SPD="$SPD,upload_bandwidth=681000000"
SPD="$SPD $TS"
curl -sf -d "$SPD" \
    "$VM_URL/write?db=speedtest"

echo "✓ Line protocol writes accepted"
# Output timestamp in seconds for query steps
echo "TS_SEC=$(date +%s)" >>"${GITHUB_ENV:-/dev/null}"
