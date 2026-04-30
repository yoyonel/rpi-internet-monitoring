#!/usr/bin/env bash
# Seed test data into InfluxDB and VictoriaMetrics for Grafana E2E tests.
# Writes 10 data points (speedtest, cpu, mem, disk, docker) into both backends.
#
# Env vars: INFLUXDB_ADMIN_USER, INFLUXDB_ADMIN_PASSWORD
set -euo pipefail

ADMIN="${INFLUXDB_ADMIN_USER:?}"
ADMIN_PW="${INFLUXDB_ADMIN_PASSWORD:?}"

INFLUX_URL="http://localhost:8086"
VM_URL="http://localhost:8428"

# ── Verify connectivity ──
echo "Testing InfluxDB write endpoint..."
curl -sf -o /dev/null -w 'HTTP %{http_code}\n' "$INFLUX_URL/ping" || {
    echo "InfluxDB not reachable!"
    docker logs influxdb 2>&1 | tail -20
    exit 1
}
echo "Testing VM write endpoint..."
curl -sf -o /dev/null -w 'HTTP %{http_code}\n' "$VM_URL/health" || {
    echo "VM not reachable!"
    docker logs victoriametrics 2>&1 | tail -20
    exit 1
}

# ── Verify InfluxDB databases exist ──
DBS=$(curl -sf -u "$ADMIN:$ADMIN_PW" \
    "$INFLUX_URL/query" \
    --data-urlencode 'q=SHOW DATABASES')
echo "Databases: $DBS"
echo "$DBS" | grep -q speedtest ||
    {
        echo "speedtest DB missing!"
        exit 1
    }

# ── Test write ──
echo "Testing first write..."
TS_TEST=$(date +%s)000000000
curl -v --data-binary \
    "test_metric,host=ci value=1 $TS_TEST" \
    "$INFLUX_URL/write?db=telegraf&u=$ADMIN&p=$ADMIN_PW" \
    2>&1 || {
    echo "Test write failed!"
    exit 1
}

# ── Write 10 data points (last 10 minutes) ──
TS=$(date +%s)
for offset in $(seq 0 9); do
    T=$((TS - (9 - offset) * 60))000000000
    DL=$((800000000 + RANDOM % 200000000))
    UL=$((500000000 + RANDOM % 200000000))
    PING="$((8 + RANDOM % 15)).$((RANDOM % 10))"
    CPU_IDLE="$((80 + RANDOM % 15)).$((RANDOM % 10))"
    MEM="$((30 + RANDOM % 30)).$((RANDOM % 10))"

    SPD="speedtest,result_id=ci-${offset}"
    SPD+=" ping_latency=${PING}"
    SPD+=",download_bandwidth=${DL}i"
    SPD+=",upload_bandwidth=${UL}i ${T}"
    CPU="cpu,cpu=cpu-total,host=ci"
    CPU+=" usage_idle=${CPU_IDLE},usage_system=2.1 ${T}"
    MEM_L="mem,host=ci used_percent=${MEM} ${T}"
    DSK="disk,host=ci,path=/ used_percent=45.2 ${T}"
    DCK="docker_container_cpu,container_name=grafana"
    DCK+=" usage_percent=1.5 ${T}"

    # Write to InfluxDB
    curl -sf --data-binary "$SPD" \
        "$INFLUX_URL/write?db=speedtest&u=$ADMIN&p=$ADMIN_PW"
    printf '%s\n%s\n%s\n%s' "$CPU" "$MEM_L" "$DSK" "$DCK" |
        curl -sf --data-binary @- \
            "$INFLUX_URL/write?db=telegraf&u=$ADMIN&p=$ADMIN_PW"

    # Write to VictoriaMetrics
    curl -sf --data-binary "$SPD" \
        "$VM_URL/write?db=speedtest"
    printf '%s\n%s\n%s\n%s' "$CPU" "$MEM_L" "$DSK" "$DCK" |
        curl -sf --data-binary @- \
            "$VM_URL/write?db=telegraf"
done

# ── Flush VM index ──
curl -sf "$VM_URL/internal/force_flush"
sleep 2
echo "✓ Seeded 10 data points into both backends"
