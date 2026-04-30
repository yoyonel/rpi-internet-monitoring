#!/usr/bin/env bash
# Git pre-push hook: run E2E tests before pushing.
# Automatically finds a free port for the preview server.
set -euo pipefail

# ── Find a free port ──────────────────────────────────────
find_free_port() {
    python3 "$(dirname "$0")/find-free-port.py"
}

PORT=$(find_free_port)
echo "▶ Starting preview server on :${PORT} ..."
just preview-dev "$PORT" &
PREVIEW_PID=$!
trap 'kill $PREVIEW_PID 2>/dev/null || true; wait $PREVIEW_PID 2>/dev/null || true' EXIT

# Wait for server to be ready (max 30s)
for i in $(seq 1 30); do
    if curl -sf -o /dev/null "http://127.0.0.1:${PORT}" 2>/dev/null; then
        break
    fi
    if [[ "$i" -eq 30 ]]; then
        echo "❌ Preview server failed to start on :${PORT}"
        exit 1
    fi
    sleep 1
done

echo "▶ Running E2E tests against :${PORT} ..."
just e2e "http://127.0.0.1:${PORT}" || {
    echo ""
    echo "❌ E2E tests failed. Push aborted."
    exit 1
}

echo "✅ Pre-push checks passed"
