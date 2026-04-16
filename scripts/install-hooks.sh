#!/usr/bin/env bash
# Install git hooks for this repository.
# Usage: bash scripts/install-hooks.sh
set -euo pipefail

HOOKS_DIR="$(git rev-parse --show-toplevel)/.git/hooks"

ln -sf "$(pwd)/scripts/git-pre-commit.sh" "$HOOKS_DIR/pre-commit"
ln -sf "$(pwd)/scripts/git-pre-push.sh" "$HOOKS_DIR/pre-push"

echo "Git hooks installed ✅"
echo "  pre-commit → lint & format check on staged files"
echo "  pre-push   → E2E tests"
