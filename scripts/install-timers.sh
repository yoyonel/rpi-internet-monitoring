#!/usr/bin/env bash
# Install systemd user timers for speedtest + GH Pages publish.
# Usage: bash scripts/install-timers.sh <project_dir>
set -eo pipefail

PROJECT_DIR="${1:-.}"
dir="$HOME/.config/systemd/user"
mkdir -p "$dir"

for unit in speedtest.service speedtest.timer publish-gh-pages.service publish-gh-pages.timer; do
    cp "$PROJECT_DIR/systemd/$unit" "$dir/$unit"
    echo "  → $dir/$unit"
done

# Patch WorkingDirectory to actual project path
sed -i "s|WorkingDirectory=.*|WorkingDirectory=$PROJECT_DIR|" \
    "$dir/speedtest.service" "$dir/publish-gh-pages.service"

systemctl --user daemon-reload
systemctl --user enable --now speedtest.timer publish-gh-pages.timer

echo ""
echo "✅ Timers installed and started:"
systemctl --user list-timers speedtest.timer publish-gh-pages.timer --no-pager
