#!/usr/bin/env bash
# Show VictoriaMetrics internal stats (active series, ingestion rate, storage, metrics).
# Usage: sim-vm-stats.sh [vm_url]
set -euo pipefail

VM_URL="${1:-http://localhost:8428}"

echo "── Active Time Series ──"
curl -sf "$VM_URL/api/v1/query" \
    --data-urlencode 'query=vm_cache_entries{type="storage/hour_metric_ids"}' |
    jq -r '.data.result[0].value[1] // "0"' |
    xargs -I{} echo "  {}"
echo ""

echo "── Ingestion Rate (rows/sec, last 5m) ──"
curl -sf "$VM_URL/api/v1/query" \
    --data-urlencode 'query=rate(vm_rows_inserted_total[5m])' |
    jq -r '[.data.result[].value[1] // "0"] | add // "0"' |
    xargs -I{} echo "  {} rows/sec"
echo ""

echo "── Storage Size ──"
curl -sf "$VM_URL/api/v1/query" \
    --data-urlencode 'query=sum(vm_data_size_bytes)' |
    jq -r '.data.result[0].value[1] // "0"' |
    awk '{printf "  %.2f MB\n", $1/1048576}'
echo ""

echo "── Metric Names ──"
curl -sf "$VM_URL/api/v1/label/__name__/values" |
    jq -r '.data[]' | head -30
