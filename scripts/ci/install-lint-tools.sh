#!/usr/bin/env bash
# Install linting tools for CI (shellcheck, hadolint, shfmt, yamllint, ruff).
set -euo pipefail

sudo apt-get update -qq
sudo apt-get install -y -qq shellcheck

sudo wget -qO /usr/local/bin/hadolint \
    https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64
sudo chmod +x /usr/local/bin/hadolint

sudo wget -qO /usr/local/bin/shfmt \
    https://github.com/mvdan/sh/releases/download/v3.10.0/shfmt_v3.10.0_linux_amd64
sudo chmod +x /usr/local/bin/shfmt

pip install --quiet yamllint ruff
