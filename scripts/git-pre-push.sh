#!/usr/bin/env bash
# Git pre-push hook: run E2E tests before pushing.
# Requires a preview server on localhost:8080.
set -euo pipefail

echo "▶ Checking if preview server is running on :8080 ..."
if ! curl -sf -o /dev/null http://localhost:8080 2>/dev/null; then
    echo "⚠  No preview server on :8080 — starting one in background ..."
    just preview-dev 8080 &
    PREVIEW_PID=$!
    # Wait for server to be ready (max 30s)
    for i in $(seq 1 30); do
        if curl -sf -o /dev/null http://localhost:8080 2>/dev/null; then
            break
        fi
        if [[ "$i" -eq 30 ]]; then
            echo "❌ Preview server failed to start"
            kill "$PREVIEW_PID" 2>/dev/null || true
            exit 1
        fi
        sleep 1
    done
    trap 'kill $PREVIEW_PID 2>/dev/null || true' EXIT
fi

echo "▶ Running E2E tests ..."
just e2e || {
    echo ""
    echo "❌ E2E tests failed. Push aborted."
    exit 1
}

echo "✅ Pre-push checks passed"
