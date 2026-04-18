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
#   3. Diff-based analysis: decide what actions are needed
#   4. Backup (if destructive actions are needed)
#   5. Build (if Dockerfile/entrypoint changed)
#   6. Recreate or targeted restart (based on changed files)
#   7. Run pending migrations from migrations/
#   8. Post-deploy health check
set -euo pipefail

DOCKER=${CONTAINER_CLI:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}
COMPOSE="$DOCKER compose"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
    _ok "Already up to date"
    # Still run migrations in case some were added manually
    _log "Checking pending migrations"
    _run_migrations
    _log "Post-deploy verification"
    bash "$SCRIPT_DIR/scripts/check.sh" || true
    _ok "Deploy complete (no changes)"
    exit 0
fi

_ok "Updated: ${BEFORE:0:7} → ${AFTER:0:7}"

# ── 3. Diff analysis ────────────────────────────────────

_log "Analyzing changes"

CHANGED_FILES=$(git diff --name-only "$BEFORE" "$AFTER")

needs_build=false
needs_recreate=false
restart_grafana=false
restart_telegraf=false
needs_backup=false

while IFS= read -r file; do
    case "$file" in
        Dockerfile | docker-entrypoint.sh)
            needs_build=true
            needs_recreate=true
            _ok "  $file → rebuild + recreate"
            ;;
        docker-compose.yml)
            needs_recreate=true
            _ok "  $file → recreate containers"
            ;;
        grafana/provisioning/*)
            restart_grafana=true
            _ok "  $file → restart grafana"
            ;;
        telegraf/*)
            restart_telegraf=true
            _ok "  $file → restart telegraf"
            ;;
        scripts/* | Justfile | docs/* | .github/* | *.md | sim/* | tests/* | test-* | lighthouse-* | gh-pages/* | .pre-commit* | ruff.toml | package*)
            _skip "$file (no runtime action needed)"
            ;;
        *)
            _skip "$file (unknown — no action)"
            ;;
    esac
done <<<"$CHANGED_FILES"

# Recreate implies restarting everything, so skip targeted restarts
if $needs_recreate; then
    restart_grafana=false
    restart_telegraf=false
fi

# Backup if any container-level changes
if $needs_build || $needs_recreate; then
    needs_backup=true
fi

echo ""
printf "  Plan: build=%s recreate=%s restart_grafana=%s restart_telegraf=%s\n" \
    "$needs_build" "$needs_recreate" "$restart_grafana" "$restart_telegraf"

# ── 4. Backup ────────────────────────────────────────────

if $needs_backup; then
    _log "Creating backup before destructive changes"
    bash "$SCRIPT_DIR/scripts/backup.sh"
    echo ""
else
    _skip "Backup skipped (no container-level changes)"
fi

# ── 5. Build ─────────────────────────────────────────────

if $needs_build; then
    _log "Rebuilding speedtest image"
    $COMPOSE build speedtest
else
    _skip "Build skipped (Dockerfile unchanged)"
fi

# ── 6. Recreate / Restart ───────────────────────────────

if $needs_recreate; then
    _log "Recreating containers"
    $COMPOSE up -d --remove-orphans
elif $restart_grafana || $restart_telegraf; then
    if $restart_grafana; then
        _log "Restarting grafana"
        $COMPOSE restart grafana
    fi
    if $restart_telegraf; then
        _log "Restarting telegraf"
        $COMPOSE restart telegraf
    fi
else
    _skip "No container changes needed"
fi

# ── 7. Migrations ────────────────────────────────────────

_run_migrations

# ── 8. Post-deploy check ────────────────────────────────

_log "Post-deploy verification"

# Wait a few seconds for services to stabilize after restart/recreate
if $needs_recreate || $restart_grafana || $restart_telegraf; then
    echo "  Waiting 10s for services to stabilize..."
    sleep 10
fi

bash "$SCRIPT_DIR/scripts/check.sh" || true

echo ""
_log "Container status"
$COMPOSE ps -a

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Deploy complete — $(date -Iseconds)"
echo "║  ${BEFORE:0:7} → ${AFTER:0:7} ($(git rev-list --count "$BEFORE".."$AFTER") commits)"
echo "╚══════════════════════════════════════════╝"
