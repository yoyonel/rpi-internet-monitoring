#!/usr/bin/env bash

# InfluxDB variables
influxdb_proto=${INFLUXDB_PROTO:-http}
influxdb_host=${INFLUXDB_HOST:-influxdb}
influxdb_port=${INFLUXDB_PORT:-8086}
influxdb_db=${INFLUXDB_DB:-speedtest}
influxdb_user=${INFLUXDB_USER:-}
influxdb_password=${INFLUXDB_USER_PASSWORD:-}

# Validate env variables (alphanumeric + hyphen/underscore only)
for var_name in influxdb_host influxdb_db; do
    val="${!var_name}"
    if [[ ! "$val" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "ERROR: Invalid $var_name: '$val'" >&2
        exit 1
    fi
done
if [[ ! "$influxdb_port" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid influxdb_port: '$influxdb_port'" >&2
    exit 1
fi
if [[ "$influxdb_proto" != "http" && "$influxdb_proto" != "https" ]]; then
    echo "ERROR: Invalid influxdb_proto: '$influxdb_proto'" >&2
    exit 1
fi

influxdb_url="${influxdb_proto}://${influxdb_host}:${influxdb_port}"

# Build auth flags for curl (via config to avoid creds in /proc cmdline)
CURL_AUTH_CONF=""
if [[ -n "$influxdb_user" && -n "$influxdb_password" ]]; then
    CURL_AUTH_CONF=$(mktemp)
    chmod 600 "$CURL_AUTH_CONF"
    printf 'user = "%s:%s"\n' "$influxdb_user" "$influxdb_password" >"$CURL_AUTH_CONF"
    trap 'rm -f "$CURL_AUTH_CONF"' EXIT
fi
curl_auth() { if [[ -n "$CURL_AUTH_CONF" ]]; then echo "-K $CURL_AUTH_CONF"; fi; }

# run speedtest & store result
json_result=$(speedtest -f json --accept-license --accept-gdpr)

# Extract data from speedtest result
result_id=$(echo "${json_result}" | jq -r '.result.id')
ping_latency=$(echo "${json_result}" | jq -r '.ping.latency')
download_bandwidth=$(echo "${json_result}" | jq -r '.download.bandwidth')
upload_bandwidth=$(echo "${json_result}" | jq -r '.upload.bandwidth')

# Validate extracted values (must be alphanumeric/numeric to prevent InfluxDB injection)
if [[ ! "$result_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: Invalid result_id: '$result_id'" >&2
    exit 1
fi
for field_name in ping_latency download_bandwidth upload_bandwidth; do
    val="${!field_name}"
    if [[ ! "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "ERROR: Invalid $field_name: '$val'" >&2
        exit 1
    fi
done

# Ensure InfluxDB database exists
# shellcheck disable=SC2046
curl $(curl_auth) \
    -d "q=CREATE DATABASE ${influxdb_db}" \
    "${influxdb_url}/query"

# Write metric to InfluxDB
http_post_data_metrics="speedtest,result_id=${result_id} ping_latency=${ping_latency},download_bandwidth=${download_bandwidth},upload_bandwidth=${upload_bandwidth}"
echo "${http_post_data_metrics}"
# shellcheck disable=SC2046
curl $(curl_auth) \
    -d "${http_post_data_metrics}" \
    "${influxdb_url}/write?db=${influxdb_db}"
