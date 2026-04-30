#!/usr/bin/env bash
# Quick health check of the monitoring services.
# Auto-detects which services are running (InfluxDB, VictoriaMetrics, or both).
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../" && pwd)"
# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/scripts/lib-common.sh"

detect_container_cli
load_env "$SCRIPT_DIR/.env"

PASS=0
FAIL=0
SKIP=0

_check_http() {
    local name="$1" url="$2"
    if curl -sf "$url" >/dev/null 2>&1; then
        printf "  ✅ %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  ❌ %s\n" "$name"
        FAIL=$((FAIL + 1))
    fi
}

_is_container_running() {
    local name="$1"
    [[ "$("$DOCKER" inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]
}

# ── Always-on services ───────────────────────────────────
_check_http "Grafana" "http://localhost:3000/api/health"

if _is_container_running chronograf 2>/dev/null; then
    _check_http "Chronograf" "http://localhost:8888/chronograf/v1/me"
else
    printf "  ⊘ Chronograf (not running)\n"
    SKIP=$((SKIP + 1))
fi

# ── TSDB backends (auto-detect) ──────────────────────────
if _is_container_running influxdb 2>/dev/null; then
    _influx_admin=$(_read_env INFLUXDB_ADMIN_USER)
    _influx_admin_pass=$(_read_env INFLUXDB_ADMIN_PASSWORD)
    if "$DOCKER" exec influxdb influx -username "${_influx_admin:-admin}" -password "${_influx_admin_pass}" -execute "SHOW DATABASES" >/dev/null 2>&1; then
        printf "  ✅ InfluxDB\n"
        PASS=$((PASS + 1))
    else
        printf "  ❌ InfluxDB\n"
        FAIL=$((FAIL + 1))
    fi
else
    printf "  ⊘ InfluxDB (not running)\n"
    SKIP=$((SKIP + 1))
fi

if _is_container_running victoriametrics 2>/dev/null; then
    _check_http "VictoriaMetrics" "http://localhost:8428/health"
else
    printf "  ⊘ VictoriaMetrics (not running)\n"
    SKIP=$((SKIP + 1))
fi

# ── Collector ────────────────────────────────────────────
if "$DOCKER" exec telegraf pgrep telegraf >/dev/null 2>&1; then
    printf "  ✅ Telegraf\n"
    PASS=$((PASS + 1))
else
    printf "  ❌ Telegraf\n"
    FAIL=$((FAIL + 1))
fi

echo ""
TOTAL=$((PASS + FAIL))
if [[ "$SKIP" -gt 0 ]]; then
    echo "$PASS/$TOTAL services healthy ($SKIP skipped)"
else
    echo "$PASS/$TOTAL services healthy"
fi
