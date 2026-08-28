#!/usr/bin/env bash
# Build the Lighthouse PR comment body comparing mobile vs desktop scores.
# Usage: lighthouse-comment-body.sh <reports_dir>
# Outputs: body (multiline) to $GITHUB_OUTPUT
set -euo pipefail

REPORTS_DIR="${1:?Usage: lighthouse-comment-body.sh <reports_dir>}"

badge() {
    if ((${1} >= 90)); then
        echo "🟢"
    elif ((${1} >= 50)); then
        echo "🟠"
    else
        echo "🔴"
    fi
}

read_score() {
    python3 "$(dirname "$0")/../lighthouse-read-score.py" "$1" "$2"
}

{
    echo 'body<<EOFCOMMENT'
    echo '## 🔦 Lighthouse Audit'
    echo ''
    echo '| Category | Mobile | Desktop |'
    echo '|----------|-------:|--------:|'
    for cat in performance accessibility best-practices seo; do
        M_JSON="$REPORTS_DIR/lighthouse-mobile/lighthouse-mobile.report.json"
        D_JSON="$REPORTS_DIR/lighthouse-desktop/lighthouse-desktop.report.json"
        M=$(read_score "$M_JSON" "$cat")
        D=$(read_score "$D_JSON" "$cat")
        LABEL="$cat"
        [[ "$cat" == "best-practices" ]] && LABEL="best practices"
        echo "| $(badge "$M")$(badge "$D") ${LABEL} | **${M}** | **${D}** |"
    done
    echo ''
    echo "_Audited on GitHub Pages preview_"
    echo 'EOFCOMMENT'
} >>"$GITHUB_OUTPUT"
