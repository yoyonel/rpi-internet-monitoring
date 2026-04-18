#!/usr/bin/env bash
# Migration: disable legacy cron/systemd-timer based speedtest scheduling.
# The new speedtest-cron container (added in this PR) replaces the external
# cron entry or systemd timer that previously triggered `docker compose run --rm speedtest`.
set -euo pipefail

echo "Checking for legacy speedtest scheduling..."

# Remove crontab entries referencing speedtest
if crontab -l 2>/dev/null | grep -q speedtest; then
    echo "  Removing speedtest crontab entry..."
    crontab -l 2>/dev/null | grep -v speedtest | crontab - || true
    echo "  ✅ Crontab entry removed"
else
    echo "  ⊘ No crontab entry found (OK)"
fi

# Disable systemd timer if present
if systemctl --user is-enabled speedtest.timer 2>/dev/null | grep -q enabled; then
    echo "  Disabling speedtest.timer..."
    systemctl --user stop speedtest.timer 2>/dev/null || true
    systemctl --user disable speedtest.timer 2>/dev/null || true
    echo "  ✅ speedtest.timer disabled"
else
    echo "  ⊘ No speedtest.timer enabled (OK)"
fi
