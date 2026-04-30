#!/usr/bin/env bash
# Start VictoriaMetrics in Docker and wait for readiness.
# Usage: start-victoriametrics.sh [--network NETWORK] [--influx-listen-addr ADDR]
set -euo pipefail

NETWORK=""
INFLUX_ADDR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --network)
            NETWORK="$2"
            shift 2
            ;;
        --influx-listen-addr)
            INFLUX_ADDR="$2"
            shift 2
            ;;
        *)
            echo "Unknown arg: $1"
            exit 1
            ;;
    esac
done

DOCKER_ARGS=(
    run -d --name victoriametrics
    -p 8428:8428
)
[[ -n "$NETWORK" ]] && DOCKER_ARGS+=(--network "$NETWORK")

VM_ARGS=(
    -search.latencyOffset=0s
    -httpListenAddr=:8428
)
[[ -n "$INFLUX_ADDR" ]] && VM_ARGS+=("-influxListenAddr=$INFLUX_ADDR")

DOCKER_ARGS+=(victoriametrics/victoria-metrics:v1.142.0 "${VM_ARGS[@]}")

docker "${DOCKER_ARGS[@]}"

echo "Waiting for VictoriaMetrics..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:8428/health >/dev/null 2>&1; then
        echo "VM healthy after ${i}s"
        break
    fi
    if [[ "$i" -eq 30 ]]; then
        echo "VM timeout"
        docker logs victoriametrics
        exit 1
    fi
    sleep 1
done
