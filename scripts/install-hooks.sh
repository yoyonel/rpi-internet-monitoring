#!/usr/bin/env bash
# Install git hooks for this repository.
# Usage: bash scripts/install-hooks.sh
set -euo pipefail

HOOKS_DIR="$(git rev-parse --show-toplevel)/.git/hooks"

# pre-commit framework handles the pre-commit hook
pre-commit install

# pre-push: E2E tests (custom script)
ln -sf "$(pwd)/scripts/git-pre-push.sh" "$HOOKS_DIR/pre-push"

echo ""
echo "Git hooks installed ✅"
echo "  pre-commit → pre-commit framework (lint & format)"
echo "  pre-push   → E2E tests"
