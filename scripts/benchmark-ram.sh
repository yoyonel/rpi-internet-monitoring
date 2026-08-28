#!/usr/bin/env bash
# benchmark-ram.sh — Compare RAM usage: InfluxDB vs VictoriaMetrics
# Usage: bash scripts/benchmark-ram.sh [--wait SECONDS]
#
# Requires the sim stack to be running (just sim-up or just sim-vm-up).
# Collects docker stats for all rpi-sim-* containers and formats a
# Markdown comparison table.
set -euo pipefail

WAIT=${1:-0}
[[ "$WAIT" == "--wait" ]] && WAIT=${2:-600}

CLI=${CONTAINER_CLI:-docker}

# ── Helpers ──────────────────────────────────────────────

die() {
    echo "ERROR: $*" >&2
    exit 1
}

collect_stats() {
    # Outputs: NAME MEM_USAGE MEM_LIMIT MEM_PCT for each container
    $CLI stats --no-stream --format '{{.Name}} {{.MemUsage}} {{.MemPerc}}' |
        grep '^rpi-sim-' |
        sort
}

# ── Wait for stable state ───────────────────────────────

if [[ "$WAIT" -gt 0 ]]; then
    echo "⏳ Waiting ${WAIT}s for stack to reach stable state..."
    sleep "$WAIT"
fi

# ── Collect ──────────────────────────────────────────────

echo "╔══════════════════════════════════════════╗"
echo "║     RAM Benchmark — sim/ containers      ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Date: $(date -Iseconds)"
echo "CLI:  $CLI"
echo ""

# Check at least one sim container is running
if ! $CLI ps --format '{{.Names}}' | grep -q '^rpi-sim-'; then
    die "No rpi-sim-* containers running. Start with 'just sim-up' or 'just sim-vm-up'."
fi

echo "── Raw docker stats ──"
echo ""
printf "%-30s %15s %10s\n" "CONTAINER" "MEM USAGE" "MEM %"
printf "%-30s %15s %10s\n" "─────────" "─────────" "─────"

$CLI stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}' |
    grep '^rpi-sim-' |
    sort |
    while IFS=$'\t' read -r name usage pct; do
        printf "%-30s %15s %10s\n" "$name" "$usage" "$pct"
    done

echo ""
echo "── Per-container cgroup memory (bytes) ──"
echo ""
printf "%-30s %12s %12s %12s\n" "CONTAINER" "RSS" "CACHE" "SWAP"
printf "%-30s %12s %12s %12s\n" "─────────" "───" "─────" "────"

for cid in $($CLI ps -q --filter "name=rpi-sim-"); do
    name=$($CLI inspect --format '{{.Name}}' "$cid" | tr -d '/')
    # Try cgroup v2 first, fall back to v1
    rss=$($CLI exec "$cid" cat /sys/fs/cgroup/memory.current 2>/dev/null ||
        $CLI exec "$cid" cat /proc/meminfo 2>/dev/null | awk '/MemTotal/{print $2*1024}' ||
        echo "n/a")
    cache=$($CLI exec "$cid" cat /sys/fs/cgroup/memory.stat 2>/dev/null |
        awk '/^file /{print $2}' ||
        echo "n/a")
    swap=$($CLI exec "$cid" cat /sys/fs/cgroup/memory.swap.current 2>/dev/null ||
        echo "n/a")

    fmt_val() {
        if [[ "$1" == "n/a" || -z "$1" ]]; then
            echo "n/a"
        elif [[ "$1" -gt 1048576 ]]; then
            awk "BEGIN {printf \"%.1f MB\", $1/1048576}"
        else
            awk "BEGIN {printf \"%.1f KB\", $1/1024}"
        fi
    }
    printf "%-30s %12s %12s %12s\n" "$name" "$(fmt_val "$rss")" "$(fmt_val "$cache")" "$(fmt_val "$swap")"
done

echo ""
echo "── Summary ──"
echo ""

# Total RSS from docker stats (parse MiB/GiB)
total=0
while read -r line; do
    # Format: "123.4MiB / 456.7MiB" or "1.234GiB / ..."
    usage=$(echo "$line" | awk '{print $2}')
    if echo "$usage" | grep -q 'GiB'; then
        val=${usage//GiB/}
        val=$(awk "BEGIN {printf \"%.0f\", $val * 1024}")
    else
        val=${usage//MiB/}
    fi
    total=$(awk "BEGIN {printf \"%.1f\", $total + $val}")
done < <($CLI stats --no-stream --format '{{.Name}} {{.MemUsage}}' | grep '^rpi-sim-')

echo "Total RAM (all sim containers): ${total} MiB"

# Check if VM is present
if $CLI ps --format '{{.Names}}' | grep -q 'rpi-sim-victoriametrics'; then
    vm_mem=$($CLI stats --no-stream --format '{{.MemUsage}}' rpi-sim-victoriametrics | awk '{print $1}')
    echo "VictoriaMetrics:               ${vm_mem}"
fi

# Check if InfluxDB is present
if $CLI ps --format '{{.Names}}' | grep -q 'rpi-sim-influxdb'; then
    influx_mem=$($CLI stats --no-stream --format '{{.MemUsage}}' rpi-sim-influxdb | awk '{print $1}')
    echo "InfluxDB:                      ${influx_mem}"
fi

echo ""
echo "Done. Run with --wait 600 for stable-state measurements."
