#!/usr/bin/env bash
# Run Lighthouse audits against the production GitHub Pages site.
#
# Usage: bash scripts/lighthouse.sh [--mobile|--desktop|--both] [--open]
#   --mobile   Audit mobile only (default)
#   --desktop  Audit desktop only
#   --both     Audit both mobile and desktop (default if no flag)
#   --open     Open HTML reports in browser after audit
#
# Reports are saved to lighthouse-reports/ with timestamped filenames.
set -euo pipefail

URL="https://yoyonel.github.io/rpi-internet-monitoring/"
OUT_DIR="lighthouse-reports"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OPEN=false
PRESETS=()

for arg in "$@"; do
    case "$arg" in
        --mobile) PRESETS+=(mobile) ;;
        --desktop) PRESETS+=(desktop) ;;
        --both) PRESETS=(mobile desktop) ;;
        --open) OPEN=true ;;
        *)
            echo "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

# Default: both
if [[ ${#PRESETS[@]} -eq 0 ]]; then
    PRESETS=(mobile desktop)
fi

# Check lighthouse is installed
if ! command -v lighthouse &>/dev/null; then
    echo "❌ lighthouse CLI not found. Install with:"
    echo "   npm install -g lighthouse"
    exit 1
fi

mkdir -p "$OUT_DIR"

badge() {
    if (($1 >= 90)); then
        echo "🟢"
    elif (($1 >= 50)); then
        echo "🟠"
    else
        echo "🔴"
    fi
}

for preset in "${PRESETS[@]}"; do
    echo ""
    echo "══════════════════════════════════════════════"
    echo "  Lighthouse — ${preset^^} — $URL"
    echo "══════════════════════════════════════════════"

    REPORT_NAME="${OUT_DIR}/${TIMESTAMP}-${preset}"

    ARGS=(
        "$URL"
        --output html --output json
        --output-path "$REPORT_NAME"
        --chrome-flags="--headless --no-sandbox"
    )
    if [[ "$preset" == "desktop" ]]; then
        ARGS+=(--preset desktop)
    fi

    lighthouse "${ARGS[@]}"

    # Extract scores
    JSON="${REPORT_NAME}.report.json"
    read_score() {
        python3 "$(dirname "$0")/lighthouse-read-score.py" "$JSON" "$1"
    }

    PERF=$(read_score performance)
    A11Y=$(read_score accessibility)
    BP=$(read_score best-practices)
    SEO=$(read_score seo)

    echo ""
    echo "  ┌─────────────────────────────────┐"
    echo "  │  ${preset^^} Results              "
    echo "  ├─────────────────────────────────┤"
    printf "  │  %s Performance    %3d          │\n" "$(badge "$PERF")" "$PERF"
    printf "  │  %s Accessibility   %3d          │\n" "$(badge "$A11Y")" "$A11Y"
    printf "  │  %s Best Practices  %3d          │\n" "$(badge "$BP")" "$BP"
    printf "  │  %s SEO             %3d          │\n" "$(badge "$SEO")" "$SEO"
    echo "  └─────────────────────────────────┘"
    echo ""
    echo "  HTML: ${REPORT_NAME}.report.html"
    echo "  JSON: ${REPORT_NAME}.report.json"

    if [[ "$OPEN" == true ]]; then
        xdg-open "${REPORT_NAME}.report.html" 2>/dev/null ||
            open "${REPORT_NAME}.report.html" 2>/dev/null ||
            echo "  (could not auto-open report)"
    fi
done

# Symlink latest reports for easy access
for preset in "${PRESETS[@]}"; do
    for ext in report.html report.json; do
        src="${TIMESTAMP}-${preset}.${ext}"
        link="${OUT_DIR}/latest-${preset}.${ext}"
        ln -sf "$src" "$link"
    done
done

echo ""
echo "Done. Latest reports symlinked:"
for preset in "${PRESETS[@]}"; do
    echo "  ${OUT_DIR}/latest-${preset}.report.html"
done
