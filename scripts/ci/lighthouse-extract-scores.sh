#!/usr/bin/env bash
# Extract Lighthouse scores and write a Job Summary.
# Usage: lighthouse-extract-scores.sh <report.json> <preset>
# Outputs: perf, a11y, bp, seo to $GITHUB_OUTPUT
set -euo pipefail

JSON="${1:?Usage: lighthouse-extract-scores.sh <report.json> <preset>}"
PRESET="${2:?}"

read_score() {
    python3 -c "import json; d=json.load(open('$JSON')); \
        print(int(d['categories']['$1']['score']*100))"
}

PERF=$(read_score performance)
A11Y=$(read_score accessibility)
BP=$(read_score best-practices)
SEO=$(read_score seo)

{
    echo "perf=$PERF"
    echo "a11y=$A11Y"
    echo "bp=$BP"
    echo "seo=$SEO"
} >>"$GITHUB_OUTPUT"

badge() {
    if ((${1} >= 90)); then
        echo "🟢"
    elif ((${1} >= 50)); then
        echo "🟠"
    else
        echo "🔴"
    fi
}

{
    echo "## Lighthouse — $PRESET"
    echo ""
    echo "> Audited: \`${TARGET_URL:-unknown}\`"
    echo ""
    echo "| Category | Score |"
    echo "|----------|------:|"
    echo "| $(badge "$PERF") Performance   | **${PERF}** |"
    echo "| $(badge "$A11Y") Accessibility  | **${A11Y}** |"
    echo "| $(badge "$BP") Best Practices | **${BP}** |"
    echo "| $(badge "$SEO") SEO            | **${SEO}** |"
} >>"$GITHUB_STEP_SUMMARY"
