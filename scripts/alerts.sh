#!/usr/bin/env bash
# Show Grafana alert rules and their current state.
# Usage: bash scripts/alerts.sh <project_dir>
set -eo pipefail

PROJECT_DIR="${1:-.}"

_user="${GF_SECURITY_ADMIN_USER:-$(grep '^GF_SECURITY_ADMIN_USER=' "$PROJECT_DIR/.env" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")}"
_pass="${GF_SECURITY_ADMIN_PASSWORD:-$(grep '^GF_SECURITY_ADMIN_PASSWORD=' "$PROJECT_DIR/.env" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")}"
CREDS="${_user:-admin}:${_pass}"

echo "── Alert Rules ──"
curl -sf -K <(printf 'user = "%s"\n' "$CREDS") "http://localhost:3000/api/prometheus/grafana/api/v1/rules" |
    jq -r '.data.groups[].rules[] | "  \(if .state == "inactive" then "✅" elif .state == "firing" then "🔴" else "⚠️ " end) \(.name) [\(.state)] (\(.health))"'
