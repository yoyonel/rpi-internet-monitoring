#!/usr/bin/env bash
# Show systemd timer status and recent logs.
set -eo pipefail

echo "── Timers ──"
systemctl --user list-timers speedtest.timer publish-gh-pages.timer --no-pager 2>/dev/null \
    || echo "  (no timers installed)"

echo ""
echo "── Recent speedtest runs ──"
journalctl --user -u speedtest.service --no-pager -n 5 2>/dev/null \
    || echo "  (no logs)"

echo ""
echo "── Recent publish runs ──"
journalctl --user -u publish-gh-pages.service --no-pager -n 5 2>/dev/null \
    || echo "  (no logs)"
