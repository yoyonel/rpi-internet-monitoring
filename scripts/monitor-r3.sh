#!/usr/bin/env bash
# monitor-r3.sh — Automated monitoring & analysis for R3 (swappiness + mem_limit validation)
#
# Usage:
#   bash scripts/monitor-r3.sh                    # single snapshot
#   bash scripts/monitor-r3.sh --continuous       # collect every 5 min (Ctrl+C to stop)
#   bash scripts/monitor-r3.sh --report [DAYS]    # analyze last N days (default: 7)
#   bash scripts/monitor-r3.sh --cleanup          # remove monitoring data
#
# See: docs/software-recommendations.md — R3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MONITOR_DIR="${PROJECT_DIR}/.r3-monitoring"
SNAPSHOT_FILE="${MONITOR_DIR}/snapshots.jsonl"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ──────────────────────────────────────────────────────────────────────

snapshot_collect() {
    mkdir -p "$MONITOR_DIR"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local docker_stats
    docker_stats=$(docker stats --no-stream --format '{{json .}}' 2>/dev/null | jq -s '.' || echo '[]')

    local swap_info
    swap_info=$(free -b | awk '/^Swap:/ {print "{\"total\": "$2", \"used\": "$3", \"free\": "$4"}"}')

    local swappiness
    swappiness=$(cat /proc/sys/vm/swappiness)

    local oom_kills
    oom_kills=$(dmesg | grep -ic "killed process\|out of memory")

    local container_restarts
    container_restarts=$(docker events --filter type=container --filter status=start --since "5m" --until now 2>/dev/null | wc -l)

    # Collect into JSON and append to JSONL
    local snapshot
    snapshot=$(jq -n \
        --arg ts "$timestamp" \
        --arg cpu_count "$(nproc)" \
        --argjson docker_stats "$docker_stats" \
        --argjson swap "$swap_info" \
        --arg swappiness "$swappiness" \
        --arg oom_kills "$oom_kills" \
        --arg container_restarts "$container_restarts" \
        '{
            timestamp: $ts,
            cpu_count: $cpu_count | tonumber,
            docker_stats: $docker_stats,
            swap: $swap,
            swappiness: $swappiness | tonumber,
            oom_kills: $oom_kills | tonumber,
            container_restarts: $container_restarts | tonumber
        }')

    echo "$snapshot" >>"$SNAPSHOT_FILE"
    echo "✓ Snapshot collected: $timestamp"
}

# ──────────────────────────────────────────────────────────────────────

display_snapshot() {
    echo -e "${BLUE}━━━ Current Snapshot ━━━${NC}"
    echo ""

    # Docker stats
    echo -e "${YELLOW}Docker Container Stats:${NC}"
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}" 2>/dev/null || echo "  (docker not available)"
    echo ""

    # Memory
    echo -e "${YELLOW}Host Memory:${NC}"
    free -h
    echo ""

    # Swappiness
    echo -e "${YELLOW}Swappiness:${NC}"
    printf "  Current: "
    cat /proc/sys/vm/swappiness
    echo ""

    # OOM kills
    echo -e "${YELLOW}Recent Issues:${NC}"
    local oom_count
    oom_count=$(dmesg | grep -ic "killed process\|out of memory")
    printf "  OOM kills in dmesg: %d\n" "$oom_count"

    local restarts
    restarts=$(docker events --filter type=container --filter status=start --since "1h" --until now 2>/dev/null | wc -l)
    printf "  Container starts (last 1h): %d\n" "$restarts"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────

continuous_monitor() {
    local interval=${1:-300} # default 5 min
    echo -e "${BLUE}Starting continuous monitoring (interval: ${interval}s)${NC}"
    echo "Press Ctrl+C to stop."
    echo ""

    while true; do
        snapshot_collect
        display_snapshot
        sleep "$interval"
    done
}

# ──────────────────────────────────────────────────────────────────────

generate_report() {
    local days=${1:-7}

    if [[ ! -f "$SNAPSHOT_FILE" ]]; then
        echo -e "${RED}Error: No monitoring data found (${SNAPSHOT_FILE}).${NC}"
        echo "Run 'just monitor-r3' or 'just monitor-r3 --continuous' first."
        exit 1
    fi

    echo -e "${BLUE}━━━ R3 Validation Report (last $days day(s)) ━━━${NC}"
    echo ""

    # Filter snapshots from last N days
    local cutoff_time
    cutoff_time=$(date -u -d "$days days ago" +"%Y-%m-%dT%H:%M:%SZ")

    local data
    data=$(grep . "$SNAPSHOT_FILE" | jq -s "map(select(.timestamp > \"$cutoff_time\"))")

    if [[ $(echo "$data" | jq 'length') -eq 0 ]]; then
        echo -e "${YELLOW}No data collected in the last $days day(s).${NC}"
        exit 0
    fi

    local snap_count
    snap_count=$(echo "$data" | jq 'length')
    local first_ts
    first_ts=$(echo "$data" | jq -r '.[0].timestamp')
    local last_ts
    last_ts=$(echo "$data" | jq -r '.[-1].timestamp')

    echo -e "${YELLOW}Data Summary:${NC}"
    echo "  Snapshots: $snap_count"
    echo "  Period: $first_ts → $last_ts"
    echo ""

    # ─── Swappiness ───
    echo -e "${YELLOW}✓ Swappiness Analysis:${NC}"
    local swappiness
    swappiness=$(echo "$data" | jq '.[0].swappiness')
    if [[ $swappiness -le 10 ]]; then
        echo -e "  ${GREEN}✓ Set to $swappiness (tuned correctly)${NC}"
    else
        echo -e "  ${RED}✗ Set to $swappiness (not tuned, expected ≤10)${NC}"
    fi
    echo ""

    # ─── Memory Limits ───
    echo -e "${YELLOW}✓ Memory Limits Verification:${NC}"
    local last_docker_stats
    last_docker_stats=$(echo "$data" | jq '.[-1].docker_stats')

    local has_limits=false
    echo "$last_docker_stats" | jq -r '.[] | select(.MemLimit != "") | "\(.Names): \(.MemUsage) / \(.MemLimit)"' | while read -r line; do
        echo "  $line"
        has_limits=true
    done

    if [[ "$has_limits" == "false" ]]; then
        echo -e "  ${RED}✗ No memory limits detected${NC}"
    else
        echo -e "  ${GREEN}✓ Memory limits applied${NC}"
    fi
    echo ""

    # ─── Swap Usage Trend ───
    echo -e "${YELLOW}✓ Swap Usage Trend:${NC}"
    local first_swap_used
    first_swap_used=$(echo "$data" | jq '.[0].swap.used / 1024 / 1024 | floor')
    local last_swap_used
    last_swap_used=$(echo "$data" | jq '.[-1].swap.used / 1024 / 1024 | floor')
    local avg_swap_used
    avg_swap_used=$(echo "$data" | jq '[.[].swap.used] | add / length / 1024 / 1024 | floor')

    echo "  First: ${first_swap_used} MB | Last: ${last_swap_used} MB | Average: ${avg_swap_used} MB"
    if [[ $last_swap_used -lt 500 ]]; then
        echo -e "  ${GREEN}✓ Swap usage is low (<500 MB)${NC}"
    elif [[ $last_swap_used -lt 1000 ]]; then
        echo -e "  ${YELLOW}⚠ Swap usage is moderate (~${last_swap_used} MB)${NC}"
    else
        echo -e "  ${RED}✗ Swap usage is high (>${last_swap_used} MB)${NC}"
    fi
    echo ""

    # ─── OOM Kills ───
    echo -e "${YELLOW}✓ OOM Kill Analysis:${NC}"
    local total_ooms
    total_ooms=$(echo "$data" | jq '[.[].oom_kills] | add')
    if [[ $total_ooms -eq 0 ]]; then
        echo -e "  ${GREEN}✓ No OOM kills detected${NC}"
    else
        echo -e "  ${RED}✗ $total_ooms OOM kills detected${NC}"
    fi
    echo ""

    # ─── Container Restarts ───
    echo -e "${YELLOW}✓ Container Stability:${NC}"
    local total_restarts
    total_restarts=$(echo "$data" | jq '[.[].container_restarts] | add')
    if [[ $total_restarts -eq 0 ]]; then
        echo -e "  ${GREEN}✓ No unexpected restarts detected${NC}"
    else
        echo -e "  ${YELLOW}⚠ $total_restarts container starts detected (may be normal)${NC}"
    fi
    echo ""

    # ─── Final Verdict ───
    echo -e "${BLUE}━━━ Final Verdict ━━━${NC}"

    local pass_count=0
    [[ $swappiness -le 10 ]] && ((pass_count++))
    [[ "$has_limits" == "true" ]] && ((pass_count++))
    [[ $last_swap_used -lt 500 ]] && ((pass_count++))
    [[ $total_ooms -eq 0 ]] && ((pass_count++))

    if [[ $pass_count -eq 4 ]]; then
        echo -e "${GREEN}✓ R3 validation PASSED — All checks OK${NC}"
        echo "  → Ready for production merge"
    elif [[ $pass_count -ge 3 ]]; then
        echo -e "${YELLOW}⚠ R3 validation PARTIAL — 3/4 checks passed${NC}"
        echo "  → Minor tuning may be needed (review above)"
    else
        echo -e "${RED}✗ R3 validation FAILED — <3 checks passed${NC}"
        echo "  → Review memory limits or swappiness setting"
    fi
    echo ""
}

# ──────────────────────────────────────────────────────────────────────

cleanup() {
    if [[ -d "$MONITOR_DIR" ]]; then
        rm -rf "$MONITOR_DIR"
        echo -e "${GREEN}✓ Monitoring data cleaned up.${NC}"
    fi
}

# ──────────────────────────────────────────────────────────────────────

main() {
    case "${1:-}" in
        --continuous)
            continuous_monitor "${2:-300}"
            ;;
        --report)
            generate_report "${2:-7}"
            ;;
        --cleanup)
            cleanup
            ;;
        *)
            snapshot_collect
            display_snapshot
            ;;
    esac
}

main "$@"
