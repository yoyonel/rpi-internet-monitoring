#!/usr/bin/env bash
# Show versions of all monitoring stack services.
set -eo pipefail
DOCKER=${CONTAINER_CLI:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}


printf "  %-12s %s\n" "Grafana:" "$(curl -sf http://localhost:3000/api/health | jq -r .version)"
printf "  %-12s %s\n" "InfluxDB:" "$("$DOCKER" exec influxdb influx -version 2>&1 | head -1)"
printf "  %-12s %s\n" "Chronograf:" "$("$DOCKER" exec chronograf chronograf --version 2>&1 | head -1)"
printf "  %-12s %s\n" "Telegraf:" "$("$DOCKER" exec telegraf telegraf --version 2>&1 | head -1)"
printf "  %-12s %s\n" "Speedtest:" "bookworm ($("$DOCKER" inspect speedtest:bookworm 2>/dev/null | jq -r '.[0].Created' 2>/dev/null | cut -dT -f1 || echo 'not built'))"
