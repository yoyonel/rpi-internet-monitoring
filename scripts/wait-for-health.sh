#!/usr/bin/env bash
# Wait for a service health endpoint to respond.
# Usage: wait-for-health.sh <url> <name> [timeout_seconds]
#   timeout_seconds: default 120
set -euo pipefail

URL="${1:?Usage: wait-for-health.sh <url> <name> [timeout_seconds]}"
NAME="${2:?}"
TIMEOUT="${3:-120}"

echo "Waiting for $NAME to respond on $URL..."
INTERVAL=2
ELAPSED=0
while true; do
    if curl -sf "$URL" >/dev/null 2>&1; then
        echo "  $NAME healthy after ~${ELAPSED}s ✓"
        break
    fi
    ELAPSED=$((ELAPSED + INTERVAL))
    if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
        echo "  $NAME did not respond within ${TIMEOUT}s ✗"
        exit 1
    fi
    sleep "$INTERVAL"
done
