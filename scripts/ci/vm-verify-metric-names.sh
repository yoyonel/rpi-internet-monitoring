#!/usr/bin/env bash
# Verify VictoriaMetrics uses {measurement}_{field} naming convention.
set -euo pipefail

VM_URL="${VM_URL:-http://localhost:8428}"

labels=$(curl -sf "$VM_URL/api/v1/label/__name__/values")
echo "$labels" | jq .

EXPECTED=(
    cpu_usage_idle cpu_usage_system
    mem_used_percent
    speedtest_ping_latency
    speedtest_download_bandwidth
    speedtest_upload_bandwidth
)

for metric in "${EXPECTED[@]}"; do
    if echo "$labels" | jq -e ".data | index(\"$metric\")" >/dev/null; then
        echo "✓ $metric exists"
    else
        echo "✗ $metric missing"
        exit 1
    fi
done
