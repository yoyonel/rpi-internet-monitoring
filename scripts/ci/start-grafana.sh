#!/usr/bin/env bash
# Start Grafana in Docker with provisioned datasources and dashboards.
# Usage: start-grafana.sh [--network NETWORK]
#
# Env vars: GF_SECURITY_ADMIN_USER, GF_SECURITY_ADMIN_PASSWORD,
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

ADMIN="${GF_SECURITY_ADMIN_USER:?}"
ADMIN_PW="${GF_SECURITY_ADMIN_PASSWORD:?}"
INFLUX_USER="${INFLUXDB_USER:?}"
INFLUX_PW="${INFLUXDB_USER_PASSWORD:?}"

DOCKER_ARGS=(
    run -d --name grafana
    -p 3000:3000
    -e "GF_SECURITY_ADMIN_USER=$ADMIN"
    -e "GF_SECURITY_ADMIN_PASSWORD=$ADMIN_PW"
    -e GF_USERS_ALLOW_SIGN_UP=false
    -e GF_AUTH_DISABLE_LOGIN_FORM=false
    -e GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION=false
    -e GF_USERS_AUTO_ASSIGN_ORG=true
    -e GF_AUTH_ANONYMOUS_ENABLED=true
    -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin
    -e "INFLUXDB_USER=$INFLUX_USER"
    -e "INFLUXDB_USER_PASSWORD=$INFLUX_PW"
    -v "$PWD/grafana/provisioning:/etc/grafana/provisioning:ro"
    -v "$PWD/grafana/dashboards:/var/lib/grafana/dashboards:ro"
)
[[ -n "$NETWORK" ]] && DOCKER_ARGS+=(--network "$NETWORK")
DOCKER_ARGS+=(grafana/grafana:12.4.3)

docker "${DOCKER_ARGS[@]}"

echo "Waiting for Grafana..."
for i in $(seq 1 60); do
    if curl -sf http://localhost:3000/api/health >/dev/null 2>&1; then
        echo "Grafana healthy after ${i}s"
        break
    fi
    if [[ "$i" -eq 60 ]]; then
        echo "Grafana timeout"
        docker logs grafana
        exit 1
    fi
    sleep 1
done
