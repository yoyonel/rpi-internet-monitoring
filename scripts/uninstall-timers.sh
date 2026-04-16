#!/usr/bin/env bash
# Uninstall systemd user timers.
set -eo pipefail

systemctl --user disable --now speedtest.timer publish-gh-pages.timer 2>/dev/null || true

dir="$HOME/.config/systemd/user"
for unit in speedtest.service speedtest.timer publish-gh-pages.service publish-gh-pages.timer; do
    rm -f "$dir/$unit"
done

systemctl --user daemon-reload
echo "✅ Timers uninstalled"
