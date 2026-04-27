#!/usr/bin/env bash
# Smart deploy: pull, detect changes, backup, rebuild/restart as needed,
# and run pending migrations.
#
# Usage:
#   just deploy-smart          (via Justfile)
#   bash scripts/deploy.sh     (standalone)
#
# What it does:
#   1. Pre-flight checks (git clean, on correct branch)
#   2. git pull --ff-only
#   3. compose up -d (idempotent — only recreates what changed)
#   4. Run pending migrations from migrations/
#   5. Post-deploy health check
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/scripts/lib-common.sh"

detect_container_cli
COMPOSE="$DOCKER compose"
MIGRATIONS_DIR="$SCRIPT_DIR/migrations"
MIGRATIONS_LOG="$SCRIPT_DIR/.migrations-applied"

# ── Helpers ──────────────────────────────────────────────

_log() { printf "\033[1;34m▶ %s\033[0m\n" "$*"; }
_ok() { printf "\033[1;32m  ✅ %s\033[0m\n" "$*"; }
_warn() { printf "\033[1;33m  ⚠️  %s\033[0m\n" "$*"; }
_err() { printf "\033[1;31m  ❌ %s\033[0m\n" "$*"; }
_skip() { printf "\033[0;90m  ⊘ %s\033[0m\n" "$*"; }

_run_migrations() {
    if [[ ! -d "$MIGRATIONS_DIR" ]]; then
        _skip "No migrations/ directory"
        return
    fi

    # Create tracking file if missing
    touch "$MIGRATIONS_LOG"

    local count=0
    for migration in "$MIGRATIONS_DIR"/[0-9]*.sh; do
        [[ -f "$migration" ]] || continue
        local name
        name=$(basename "$migration")
        if grep -qxF "$name" "$MIGRATIONS_LOG" 2>/dev/null; then
            _skip "Migration $name (already applied)"
            continue
        fi
        _log "Running migration: $name"
        if bash "$migration"; then
            echo "$name" >>"$MIGRATIONS_LOG"
            _ok "Migration $name applied"
            count=$((count + 1))
        else
            _err "Migration $name FAILED (exit $?) — aborting"
            exit 1
        fi
    done

    if [[ $count -eq 0 ]]; then
        _skip "No pending migrations"
    else
        _ok "$count migration(s) applied"
    fi
}

# ── 1. Pre-flight ────────────────────────────────────────

_log "Pre-flight checks"

cd "$SCRIPT_DIR"

# Ensure we are in a git repo
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _err "Not a git repository"
    exit 1
fi

# Reject if there are uncommitted changes (except .env which is gitignored)
if ! git diff --quiet HEAD -- 2>/dev/null; then
    _err "Uncommitted changes detected — commit or stash first"
    git diff --stat HEAD
    exit 1
fi

BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")
_ok "On branch: $BRANCH"

# ── 2. Pull ──────────────────────────────────────────────

_log "Pulling latest changes"

BEFORE=$(git rev-parse HEAD)

if ! git pull --ff-only 2>&1; then
    _err "git pull --ff-only failed (diverged history?)"
    exit 1
fi

AFTER=$(git rev-parse HEAD)

if [[ "$BEFORE" == "$AFTER" ]]; then
    _ok "Already up to date (no new commits)"
else
    _ok "Updated: ${BEFORE:0:7} → ${AFTER:0:7}"
    # If this script itself was updated, re-exec the new version.
    # On re-exec, pull will be a no-op (already up to date) so no loop.
    if git diff --name-only "$BEFORE".."$AFTER" | grep -qx "scripts/deploy.sh"; then
        _warn "deploy.sh was updated — re-executing new version"
        exec bash "${BASH_SOURCE[0]}" "$@"
    fi
fi

# ── 3. Ensure containers match current config ───────────
# compose up -d is idempotent: recreates only what changed,
# creates missing services, removes orphans. Always safe to run.

_log "Ensuring containers match current config"
$COMPOSE up -d --remove-orphans

# ── 4. Migrations ────────────────────────────────────────

_run_migrations

# ── 5. Post-deploy check ────────────────────────────────

_log "Post-deploy verification"

# Wait for all healthchecks to settle (compose up may restart containers
# whose deps like influxdb take ~30s to become healthy).
MAX_WAIT=90
INTERVAL=10
elapsed=0
while ((elapsed < MAX_WAIT)); do
    healthy=$($COMPOSE ps --format json | grep -c '"healthy"' || true)
    total=$($COMPOSE ps --format json | grep -cE '"Health"\s*:\s*"(healthy|unhealthy|starting)"' || true)
    if ((total > 0 && healthy == total)); then
        break
    fi
    echo "  Waiting for health checks... (${healthy}/${total} healthy, ${elapsed}s/${MAX_WAIT}s)"
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

bash "$SCRIPT_DIR/scripts/check.sh" || true

echo ""
_log "Container status"
$COMPOSE ps -a

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Deploy complete — $(date -Iseconds)"
if [[ "$BEFORE" != "$AFTER" ]]; then
    echo "║  ${BEFORE:0:7} → ${AFTER:0:7} ($(git rev-list --count "$BEFORE".."$AFTER") commits)"
fi
echo "╚══════════════════════════════════════════╝"
