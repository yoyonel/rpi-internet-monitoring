#!/usr/bin/env bash
# Generate shields.io endpoint JSON files for Lighthouse badges.
# Usage: lighthouse-generate-badges.sh <reports_dir> <badges_dir>
set -euo pipefail

REPORTS_DIR="${1:?Usage: lighthouse-generate-badges.sh <reports_dir> <badges_dir>}"
BADGES_DIR="${2:?}"

mkdir -p "$BADGES_DIR"

for preset in mobile desktop; do
    JSON="$REPORTS_DIR/lighthouse-${preset}/lighthouse-${preset}.report.json"
    [[ -f "$JSON" ]] || {
        echo "⚠ No report for $preset"
        continue
    }

    for cat in performance accessibility best-practices seo; do
        score=$(python3 -c "
import json
d = json.load(open('$JSON'))
print(int(d['categories']['$cat']['score'] * 100))
")
        if ((score >= 90)); then
            color="brightgreen"
        elif ((score >= 50)); then
            color="orange"
        else
            color="red"
        fi

        label="${cat}"
        [[ "$cat" == "best-practices" ]] && label="best practices"
        cat >"$BADGES_DIR/lighthouse-${cat}-${preset}.json" <<EOF
{
  "schemaVersion": 1,
  "label": "Lighthouse ${label} (${preset})",
  "message": "${score}",
  "color": "${color}"
}
EOF
    done
done
ls -la "$BADGES_DIR/"
