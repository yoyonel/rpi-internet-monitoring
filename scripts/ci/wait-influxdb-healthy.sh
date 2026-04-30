#!/usr/bin/env bash
# Wait for the sim stack InfluxDB container to become healthy.
# Under QEMU emulation this can take 2-3 minutes.
set -euo pipefail

CONTAINER="${1:-rpi-sim-influxdb}"
TIMEOUT="${2:-180}"

echo "Waiting for $CONTAINER healthy (QEMU ~2-3 min)..."
timeout "$TIMEOUT" bash -c "
    until docker inspect $CONTAINER \
        --format '{{.State.Health.Status}}' 2>/dev/null \
        | grep -q healthy; do
        sleep 5
    done
"
echo "$CONTAINER healthy."
