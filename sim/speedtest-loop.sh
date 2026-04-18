#!/usr/bin/env bash
set -euo pipefail

# Periodically run speedtest, mimicking the systemd timer in production.
# Default interval: 600s (10 min), matching speedtest.timer OnCalendar=*:0/10.

interval="${SPEEDTEST_INTERVAL:-600}"

# Trap SIGTERM so "$DOCKER" stop doesn't wait for the full stop timeout.
# Kill the sleep process (if running) and exit cleanly.
sleep_pid=
trap 'echo "[$(date -Iseconds)] Shutting down"; [[ -n "$sleep_pid" ]] && kill "$sleep_pid" 2>/dev/null; exit 0' SIGTERM SIGINT

echo "Speedtest cron started (interval: ${interval}s)"

while true; do
    echo "[$(date -Iseconds)] Running speedtest..."
    timeout --preserve-status --signal=SIGTERM "${TIME_CHECK:-180}" \
        /usr/local/bin/docker-entrypoint.sh &&
        echo "[$(date -Iseconds)] OK" ||
        echo "[$(date -Iseconds)] Failed (exit $?)"
    echo "[$(date -Iseconds)] Next run in ${interval}s"
    sleep "$interval" &
    sleep_pid=$!
    wait "$sleep_pid" || true
    sleep_pid=
done
