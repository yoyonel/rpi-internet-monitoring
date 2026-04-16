#!/usr/bin/env bash
# Show data statistics: databases, retention policies, counts, disk usage.
set -eo pipefail

echo "── Databases ──"
docker exec influxdb influx -execute "SHOW DATABASES"
echo ""

echo "── Retention Policies ──"
for db in speedtest telegraf _internal; do
    echo "  $db:"
    docker exec influxdb influx -execute "SHOW RETENTION POLICIES ON $db" 2>/dev/null | tail -2
    echo ""
done

echo "── Data Counts ──"
printf "  Speedtest points: %s\n" "$(docker exec influxdb influx -execute "SELECT COUNT(download_bandwidth) FROM speedtest" -database speedtest 2>/dev/null | tail -1 | awk '{print $2}')"
printf "  Telegraf (last 1h): %s cpu points\n" "$(docker exec influxdb influx -execute "SELECT COUNT(usage_idle) FROM cpu WHERE time > now() - 1h" -database telegraf 2>/dev/null | tail -1 | awk '{print $2}')"
echo ""

echo "── Disk Usage ──"
docker exec influxdb du -sh /var/lib/influxdb/data/speedtest /var/lib/influxdb/data/telegraf /var/lib/influxdb/data/_internal 2>/dev/null || true
echo ""
docker system df
