influxdb_proto=${INFLUXDB_PROTO:-http}
influxdb_host=${INFLUXDB_HOST:-influxdb}
influxdb_port=${INFLUXDB_PORT:-8086}
influxdb_db=${INFLUXDB_DB:-speedtest}

influxdb_url="${influxdb_proto}://${influxdb_host}:${influxdb_port}"

# Ensure InfluxDB database 'speedtest' exists
curl \
    -d "q=CREATE DATABASE ${influxdb_db}" \
    "${influxdb_url}/query"

