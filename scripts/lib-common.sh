#!/usr/bin/env bash
# lib-common.sh — Shared shell library for rpi-internet-monitoring scripts.
#
# Source this file at the top of any script that needs container CLI detection,
# credential loading, Grafana helpers, or the test harness.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib-common.sh"          # scripts/ peers
#   source "$SCRIPT_DIR/scripts/lib-common.sh"  # repo-root scripts
#
# Functions provided:
#   detect_container_cli  — sets $DOCKER (docker or podman)
#   load_env <file>       — reads KEY=VALUE pairs, sets _read_env()
#   setup_grafana_auth    — sets GRAFANA_CREDS + _gcurl()
#   pass / fail / warn / test_summary — test harness with counters
# ─────────────────────────────────────────────────────────

# Guard against double-sourcing
[[ -n "${_LIB_COMMON_LOADED:-}" ]] && return 0
_LIB_COMMON_LOADED=1

# ── Container CLI detection ──────────────────────────────
# Uses if/elif to avoid bash operator-precedence pitfalls that caused
# the one-liner variant to concatenate both "docker" and "podman".
detect_container_cli() {
    if [[ -n "${CONTAINER_CLI:-}" ]]; then
        DOCKER="$CONTAINER_CLI"
    elif command -v docker >/dev/null 2>&1; then
        DOCKER=docker
    elif command -v podman >/dev/null 2>&1; then
        DOCKER=podman
    else
        DOCKER=docker
    fi
    export DOCKER
}

# ── Credential loading ───────────────────────────────────
# load_env <env-file>
#   Parses a KEY=VALUE file, strips quotes.  After calling, use
#   _read_env KEY to retrieve a value.  Does NOT export into the
#   environment — callers pick what they need.
#
# Example:
#   load_env "$PROJECT_DIR/.env"
#   _user=$(_read_env GF_SECURITY_ADMIN_USER)
load_env() {
    local file="${1:?load_env: path to env file required}"
    if [[ ! -f "$file" ]]; then
        echo "lib-common: warning: env file not found: $file" >&2
        return 1
    fi
    _LIB_ENV_FILE="$file"
}

# Read a single key from the loaded env file.
# The file takes precedence so that scripts can override
# environment variables inherited from the parent (e.g. Justfile's
# `set dotenv-load` exports production .env, but sim scripts need
# sim/.env.sim values).  Falls back to the current env var only
# when the key is absent from the file.
_read_env() {
    local key="${1:?_read_env: key required}"
    # Prefer the explicitly-loaded file
    if [[ -n "${_LIB_ENV_FILE:-}" ]] && [[ -f "$_LIB_ENV_FILE" ]]; then
        local file_val
        file_val=$(grep "^${key}=" "$_LIB_ENV_FILE" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
        if [[ -n "$file_val" ]]; then
            echo "$file_val"
            return
        fi
    fi
    # Fall back to existing env var
    echo "${!key:-}"
}

# ── Grafana authenticated curl ───────────────────────────
# setup_grafana_auth
#   Sets GRAFANA_CREDS and defines _gcurl().
#   Reads GF_SECURITY_ADMIN_USER/PASSWORD via _read_env
#   (requires load_env to have been called first).
setup_grafana_auth() {
    local user pass
    user=$(_read_env GF_SECURITY_ADMIN_USER)
    pass=$(_read_env GF_SECURITY_ADMIN_PASSWORD)
    GRAFANA_CREDS="${user:-admin}:${pass:?setup_grafana_auth: Grafana password is required}"
}

# Helper: pass creds via process substitution (not visible in /proc cmdline)
_gcurl() {
    curl -sf -K <(printf 'user = "%s"\n' "$GRAFANA_CREDS") "$@"
}

# ── Test harness ─────────────────────────────────────────
_TEST_PASS=0
_TEST_FAIL=0
_TEST_WARN=0

pass() {
    echo "  ✅ $1"
    ((_TEST_PASS++))
}

fail() {
    echo "  ❌ $1"
    ((_TEST_FAIL++))
}

warn() {
    echo "  ⚠️  $1"
    ((_TEST_WARN++))
}

test_summary() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    printf "║  Results: ✅ %-3d passed  ❌ %-3d failed  ⚠️  %-3d warnings ║\n" "$_TEST_PASS" "$_TEST_FAIL" "$_TEST_WARN"
    echo "╚══════════════════════════════════════════════════════════╝"
    [[ "$_TEST_FAIL" -eq 0 ]]
}
