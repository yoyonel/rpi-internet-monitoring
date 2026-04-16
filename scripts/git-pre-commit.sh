#!/usr/bin/env bash
# Git pre-commit hook: lint & format check on staged files.
# Only checks files that are actually staged (--cached).
set -euo pipefail

STAGED=$(git diff --cached --name-only --diff-filter=ACMR)
if [[ -z "$STAGED" ]]; then
    exit 0
fi

FAIL=0

# ── Shell ─────────────────────────────────────────────────
SH_FILES=$(echo "$STAGED" | grep -E '\.(sh)$' || true)
if [[ -n "$SH_FILES" ]]; then
    echo "▶ shellcheck"
    # shellcheck disable=SC2086
    shellcheck $SH_FILES || FAIL=1
    echo "▶ shfmt (check)"
    # shellcheck disable=SC2086
    shfmt -d -i 4 -ci $SH_FILES || FAIL=1
fi

# ── Dockerfile ────────────────────────────────────────────
DOCKER_FILES=$(echo "$STAGED" | grep -E '(Dockerfile)' || true)
if [[ -n "$DOCKER_FILES" ]]; then
    echo "▶ hadolint"
    # shellcheck disable=SC2086
    hadolint $DOCKER_FILES || FAIL=1
fi

# ── YAML ──────────────────────────────────────────────────
YAML_FILES=$(echo "$STAGED" | grep -E '\.(yml|yaml)$' || true)
if [[ -n "$YAML_FILES" ]]; then
    echo "▶ yamllint"
    # shellcheck disable=SC2086
    yamllint $YAML_FILES || FAIL=1
fi

# ── Prettier (HTML, CSS, JS, JSON, MD, YAML, docker-compose) ──
PR_FILES=$(echo "$STAGED" | grep -E '\.(html|css|js|json|md|yml|yaml)$' || true)
if [[ -n "$PR_FILES" ]]; then
    echo "▶ prettier (check)"
    # shellcheck disable=SC2086
    npx prettier --check $PR_FILES || FAIL=1
fi

# ── Python ────────────────────────────────────────────────
PY_FILES=$(echo "$STAGED" | grep -E '\.py$' || true)
if [[ -n "$PY_FILES" ]]; then
    echo "▶ ruff check"
    # shellcheck disable=SC2086
    ruff check $PY_FILES || FAIL=1
    echo "▶ ruff format (check)"
    # shellcheck disable=SC2086
    ruff format --check $PY_FILES || FAIL=1
fi

if [[ "$FAIL" -ne 0 ]]; then
    echo ""
    echo "❌ Pre-commit checks failed. Run 'just fmt' to auto-fix formatting."
    exit 1
fi

echo "✅ Pre-commit checks passed"
