#!/usr/bin/env bash
# Show data statistics: databases, retention policies, counts, disk usage.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../" && pwd)"
# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/scripts/lib-common.sh"

detect_container_cli
load_env "$SCRIPT_DIR/.env"

_influx_admin=$(_read_env INFLUXDB_ADMIN_USER)
_influx_admin_pass=$(_read_env INFLUXDB_ADMIN_PASSWORD)
INFLUX_AUTH="-username ${_influx_admin:-admin} -password ${_influx_admin_pass}"

echo "── Databases ──"
# shellcheck disable=SC2086
"$DOCKER" exec influxdb influx $INFLUX_AUTH -execute "SHOW DATABASES"
echo ""

echo "── Retention Policies ──"
for db in speedtest telegraf _internal; do
    echo "  $db:"
    # shellcheck disable=SC2086
    "$DOCKER" exec influxdb influx $INFLUX_AUTH -execute "SHOW RETENTION POLICIES ON $db" 2>/dev/null | tail -2 || echo "    (not available)"
    echo ""
done

echo "── Data Counts ──"
# shellcheck disable=SC2086
printf "  Speedtest points: %s\n" "$("$DOCKER" exec influxdb influx $INFLUX_AUTH -execute "SELECT COUNT(download_bandwidth) FROM speedtest" -database speedtest 2>/dev/null | tail -1 | awk '{print $2}')"
# shellcheck disable=SC2086
printf "  Telegraf (last 1h): %s cpu points\n" "$("$DOCKER" exec influxdb influx $INFLUX_AUTH -execute "SELECT COUNT(usage_idle) FROM cpu WHERE time > now() - 1h" -database telegraf 2>/dev/null | tail -1 | awk '{print $2}')"
echo ""

echo "── Disk Usage ──"
"$DOCKER" exec influxdb du -sh /var/lib/influxdb/data/speedtest /var/lib/influxdb/data/telegraf /var/lib/influxdb/data/_internal 2>/dev/null || true
echo ""
"$DOCKER" system df
