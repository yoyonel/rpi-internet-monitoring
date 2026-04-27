#!/usr/bin/env bash
# Show Grafana alert rules and their current state.
# Usage: bash scripts/alerts.sh <project_dir>
set -eo pipefail

PROJECT_DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

load_env "$PROJECT_DIR/.env"
setup_grafana_auth

echo "── Alert Rules ──"
_gcurl "http://localhost:3000/api/prometheus/grafana/api/v1/rules" |
    jq -r '.data.groups[].rules[] | "  \(if .state == "inactive" then "✅" elif .state == "firing" then "🔴" else "⚠️ " end) \(.name) [\(.state)] (\(.health))"'
