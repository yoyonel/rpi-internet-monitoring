#!/usr/bin/env bash
# Determine the Lighthouse target URL based on workflow context.
# Usage: lighthouse-target-url.sh <workflow_run_name> <pull_requests_json>
# Outputs: url=<URL> to $GITHUB_OUTPUT
set -euo pipefail

WORKFLOW_NAME="${1:-}"
PR_JSON="${2:-[]}"
PROD_URL="https://yoyonel.github.io/rpi-internet-monitoring/"

if [[ "$WORKFLOW_NAME" == "Preview PR — GitHub Pages" ]]; then
    PR=$(echo "$PR_JSON" |
        python3 -c "import json,sys; prs=json.load(sys.stdin); print(prs[0]['number'] if prs else '')")
    if [[ -n "$PR" ]]; then
        URL="https://yoyonel.github.io/rpi-internet-monitoring/pr-preview/pr-${PR}/"
        echo "GitHub Pages preview for PR #${PR}: $URL"
    else
        echo "No open PR found — falling back to production URL"
        URL="$PROD_URL"
    fi
else
    URL="$PROD_URL"
fi

echo "url=$URL" >>"$GITHUB_OUTPUT"
