#!/usr/bin/env bash
# Start InfluxDB in Docker, wait for readiness, create databases.
# Usage: start-influxdb.sh [--network NETWORK]
#
# Env vars: INFLUXDB_ADMIN_USER, INFLUXDB_ADMIN_PASSWORD,
#           INFLUXDB_USER, INFLUXDB_USER_PASSWORD
set -euo pipefail

NETWORK=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --network)
            NETWORK="$2"
            shift 2
            ;;
        *)
            echo "Unknown arg: $1"
            exit 1
            ;;
    esac
done

ADMIN="${INFLUXDB_ADMIN_USER:?}"
ADMIN_PW="${INFLUXDB_ADMIN_PASSWORD:?}"
USER="${INFLUXDB_USER:?}"
USER_PW="${INFLUXDB_USER_PASSWORD:?}"

DOCKER_ARGS=(
    run -d --name influxdb
    -p 8086:8086
    -e INFLUXDB_HTTP_AUTH_ENABLED=true
    -e "INFLUXDB_ADMIN_USER=$ADMIN"
    -e "INFLUXDB_ADMIN_PASSWORD=$ADMIN_PW"
    -e "INFLUXDB_USER=$USER"
    -e "INFLUXDB_USER_PASSWORD=$USER_PW"
)
[[ -n "$NETWORK" ]] && DOCKER_ARGS+=(--network "$NETWORK")
DOCKER_ARGS+=(influxdb:1.8.10)

docker "${DOCKER_ARGS[@]}"

echo "Waiting for InfluxDB..."
for i in $(seq 1 60); do
    if curl -sf http://localhost:8086/ping >/dev/null 2>&1; then
        echo "InfluxDB responding after ${i}s"
        break
    fi
    if [[ "$i" -eq 60 ]]; then
        echo "InfluxDB timeout"
        docker logs influxdb
        exit 1
    fi
    sleep 1
done

# Wait for init to complete (user creation via env vars)
echo "Waiting for InfluxDB init to finish..."
for i in $(seq 1 30); do
    if curl -sf -u "$ADMIN:$ADMIN_PW" \
        'http://localhost:8086/query' \
        --data-urlencode 'q=SHOW USERS' 2>/dev/null |
        grep -q "$USER"; then
        echo "InfluxDB init complete after ${i}s"
        break
    fi
    if [[ "$i" -eq 30 ]]; then
        echo "Init timeout"
        docker logs influxdb
        exit 1
    fi
    sleep 2
done

# Create databases and grant access
for q in \
    "CREATE DATABASE telegraf" \
    "CREATE DATABASE speedtest" \
    "GRANT ALL ON telegraf TO $USER" \
    "GRANT ALL ON speedtest TO $USER"; do
    curl -sf -XPOST 'http://localhost:8086/query' \
        -u "$ADMIN:$ADMIN_PW" \
        --data-urlencode "q=$q"
    echo "  ✓ $q"
done
