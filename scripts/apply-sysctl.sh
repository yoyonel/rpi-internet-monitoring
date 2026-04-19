#!/usr/bin/env bash
# apply-sysctl.sh — Apply kernel tuning parameters for the RPI stack (R3)
#
# Usage:
#   sudo bash scripts/apply-sysctl.sh          # install + apply
#   sudo bash scripts/apply-sysctl.sh --check  # check current value only
#
# See: docs/software-recommendations.md — R3 — Tuner swappiness + mem_limit
set -euo pipefail

SYSCTL_SRC="$(dirname "$(realpath "$0")")/../systemd/99-swappiness.conf"
SYSCTL_DEST="/etc/sysctl.d/99-swappiness.conf"

check_current() {
    current="$(cat /proc/sys/vm/swappiness)"
    echo "Current vm.swappiness = ${current}"
    if [[ "${current}" -le 10 ]]; then
        echo "  ✓ Already tuned (≤ 10)"
    else
        echo "  ! Default or high value — run without --check to apply"
    fi
}

if [[ "${1:-}" == "--check" ]]; then
    check_current
    exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo)." >&2
    exit 1
fi

echo "Installing ${SYSCTL_DEST} ..."
cp "${SYSCTL_SRC}" "${SYSCTL_DEST}"
chmod 644 "${SYSCTL_DEST}"

echo "Applying sysctl parameters ..."
sysctl --system --pattern "vm.swappiness"

check_current
echo "Done. The setting will persist across reboots."
