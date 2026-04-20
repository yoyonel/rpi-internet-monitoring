# ──────────────────────────────────────────────────────────
# Monitoring Débit Internet — RPi4 Maintenance Justfile
# ──────────────────────────────────────────────────────────
# Usage: just <recipe>
# List:  just --list

set shell := ["bash", "-eo", "pipefail", "-c"]
set dotenv-load

export CONTAINER_CLI := env('CONTAINER_CLI', `command -v podman >/dev/null 2>&1 && echo podman || echo docker`)
compose := CONTAINER_CLI + " compose"
project_dir := justfile_directory()

# List all available recipes (default)
default:
    @just --list

# ── Stack Lifecycle ──────────────────────────────────────

# Start the monitoring stack
up:
    {{ compose }} up -d

# Stop the monitoring stack (preserves data)
stop:
    {{ compose }} stop

# Restart all services
restart:
    {{ compose }} restart

# Restart a single service (e.g. just restart-svc grafana)
restart-svc svc:
    {{ compose }} restart {{ svc }}

# Full deploy: build speedtest, pull latest images, recreate
deploy:
    {{ compose }} build speedtest
    {{ compose }} up -d --pull always --remove-orphans

# Smart deploy: pull, auto-detect changes, backup, rebuild/restart, run migrations
deploy-smart:
    bash scripts/deploy.sh

# Build the speedtest image only
build:
    {{ compose }} build speedtest

# Stop and remove containers (preserves volumes/data)
down:
    {{ compose }} down

# Stop, remove containers AND volumes (⚠️ destroys all data)
[confirm("⚠️  This will DELETE ALL DATA (InfluxDB, Grafana, Chronograf). Continue?")]
nuke:
    {{ compose }} down -v

# ── Monitoring & Diagnostics ────────────────────────────

# Show container status and health
status:
    @echo "── Containers ──"
    @{{ compose }} ps -a
    @echo ""
    @echo "── Health ──"
    @{{ CONTAINER_CLI }} inspect influxdb grafana chronograf telegraf speedtest-cron 2>/dev/null | jq -r '.[] | "  \(.Name | ltrimstr("/")): \(.State.Health.Status)"' || true

# Show versions of all services
versions:
    bash scripts/versions.sh

# Show data statistics (databases, counts, disk usage)
stats:
    bash scripts/stats.sh

# Show recent logs (last 50 lines per service)
logs lines="50":
    {{ compose }} logs --tail={{ lines }}

# Show logs for a specific service
logs-svc svc lines="50":
    {{ compose }} logs --tail={{ lines }} {{ svc }}

# Follow logs in real-time
logs-follow:
    {{ compose }} logs -f --tail=20

# ── Data Operations ─────────────────────────────────────

# Run a manual speedtest (immediate, outside cron)
speedtest:
    {{ compose }} run --rm speedtest

# Show last N speedtest results (default: 5)
last-results n="5":
    @{{ CONTAINER_CLI }} exec influxdb influx \
        -username "${INFLUXDB_ADMIN_USER:-admin}" -password "${INFLUXDB_ADMIN_PASSWORD}" \
        -execute "SELECT download_bandwidth/1000000 AS dl_mbps, upload_bandwidth/1000000 AS ul_mbps, ping_latency FROM speedtest ORDER BY time DESC LIMIT {{ n }}" \
        -database speedtest -precision rfc3339

# ── Backup & Restore ───────────────────────────────────

# Create a full backup (dashboards + InfluxDB) with rotation (keep BACKUP_KEEP, default 5)
backup:
    bash scripts/backup.sh

# Rotate old backups, keeping the N most recent (default 5, override with BACKUP_KEEP=N)
backup-rotate keep="5":
    #!/usr/bin/env bash
    set -euo pipefail
    root="backups"
    mapfile -t all < <(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
    echo "Found ${#all[@]} backup(s), keeping {{ keep }}"
    if [[ ${#all[@]} -gt {{ keep }} ]]; then
        for old in "${all[@]:{{ keep }}}"; do
            echo "  🗑  Removing $old"
            rm -rf "${root:?}/$old"
        done
        echo "Pruned $(( ${#all[@]} - {{ keep }} )) old backup(s)"
    else
        echo "Nothing to prune"
    fi

# Offline integrity check on a backup dir (no stack needed)
backup-check dir:
    bash scripts/backup-check.sh {{ dir }}

# ── Build ───────────────────────────────────────────────

# Rebuild speedtest image from scratch (no cache)
build-clean:
    {{ compose }} build --no-cache speedtest

# ── Cleanup ─────────────────────────────────────────────

# Remove stopped containers and dangling images
clean:
    @echo "── Removing stopped project containers ──"
    @{{ compose }} rm -f 2>/dev/null || true
    @echo ""
    @echo "── Pruning dangling images ──"
    @{{ CONTAINER_CLI }} image prune -f
    @echo ""
    @echo "── Pruning build cache ──"
    @{{ CONTAINER_CLI }} builder prune -f
    @echo ""
    @{{ CONTAINER_CLI }} system df

# Full cleanup: clean + remove unused images (DESTRUCTIVE)
clean-all: clean
    @echo ""
    @echo "── Removing unused images ──"
    @{{ CONTAINER_CLI }} image prune -a -f
    @echo ""
    @{{ CONTAINER_CLI }} system df

# ── Testing ─────────────────────────────────────────────

# Run the regression test suite (17 checks)
test:
    bash test-stack.sh

# Quick health check (services only)
check:
    bash scripts/check.sh

# ── Utilities ───────────────────────────────────────────

# Install git hooks (pre-commit: lint, pre-push: E2E tests)
install-hooks:
    bash scripts/install-hooks.sh

# Show alert rules and their current state
alerts:
    bash scripts/alerts.sh '{{ project_dir }}'

# Publish monitoring page to GitHub Pages (last 30 days by default)
publish days="30":
    bash scripts/publish-gh-pages.sh {{ days }}

# Preview monitoring page locally (http://localhost:8080) without pushing
preview days="30":
    bash scripts/publish-gh-pages.sh --preview {{ days }}

# Preview monitoring page using live GitHub Pages data (no RPi needed)
preview-dev port="8080":
    bash scripts/preview-dev.sh {{ port }}

# Publish updated template to GitHub Pages using live data (no RPi needed)
publish-template:
    bash scripts/publish-template.sh

# Preview updated template locally before publishing (no RPi needed)
preview-template:
    bash scripts/publish-template.sh --preview

# ── Systemd Timers (replaces crontab) ──────────────────

# Install systemd user timers for speedtest + GH Pages publish
install-timers:
    bash scripts/install-timers.sh '{{ project_dir }}'

# Uninstall systemd user timers
uninstall-timers:
    bash scripts/uninstall-timers.sh

# Show systemd timer status and recent logs
timer-status:
    bash scripts/timer-status.sh

# Open an InfluxDB CLI shell
influx-shell:
    {{ CONTAINER_CLI }} exec -it influxdb influx

# Open a bash shell in a container
shell svc:
    {{ CONTAINER_CLI }} exec -it {{ svc }} bash 2>/dev/null || {{ CONTAINER_CLI }} exec -it {{ svc }} sh

# Show the active crontab entry
cron:
    @crontab -l 2>/dev/null | grep -v "^#" | grep . || echo "(no cron entries)"

# ── Code Quality ────────────────────────────────────────

# Lint all source files
lint:
    shellcheck scripts/*.sh sim/*.sh docker-entrypoint.sh test-stack.sh migrations/*.sh
    hadolint Dockerfile
    yamllint docker-compose.yml .github/workflows/*.yml grafana/provisioning/alerting/alerts.yml .yamllint.yml .hadolint.yaml
    npx prettier --check 'gh-pages/*.{html,css,js}' '**/*.json' '**/*.md' 'docker-compose.yml' '.github/workflows/*.yml'
    ruff check scripts/*.py
    ruff format --check scripts/*.py
    @echo "All linters passed ✅"

# Auto-format all source files
fmt:
    shfmt -w -i 4 -ci scripts/*.sh sim/*.sh docker-entrypoint.sh test-stack.sh migrations/*.sh
    npx prettier --write 'gh-pages/*.{html,css,js}' '**/*.json' '**/*.md' 'docker-compose.yml' '.github/workflows/*.yml'
    ruff format scripts/*.py
    @echo "All files formatted ✅"

# E2E tests against a local or remote preview (default: http://127.0.0.1:8080)
e2e url="http://127.0.0.1:8080":
    E2E_BASE_URL={{ url }} npx playwright test

# Run Lighthouse audit on production (mobile+desktop by default, --open to view)
lighthouse *args="--both":
    bash scripts/lighthouse.sh {{ args }}

# Parse Lighthouse reports and show prioritized action plan
lighthouse-report preset="both":
    python3 scripts/lighthouse-report.py {{ preset }}

# ── RPi4 Simulation (ARM64 on x86) ─────────────────────

# Source sim/.env.sim BEFORE compose so sim credentials override
# the production .env loaded by `set dotenv-load`.
# Shell env has higher precedence than --env-file in docker compose.
sim_compose := "set -a && . sim/.env.sim && set +a && " + compose + " -f docker-compose.yml -f sim/docker-compose.sim.yml --env-file sim/.env.sim -p rpi-sim"

# Start the RPi4 simulation stack (ARM64 emulated via QEMU)
sim-up:
    {{ sim_compose }} up -d

# Stop the simulation stack
sim-stop:
    {{ sim_compose }} stop

# Stop and remove simulation containers (preserves volumes)
sim-down:
    {{ sim_compose }} down

# Stop, remove containers AND simulation volumes (⚠️ destroys sim data)
[confirm("⚠️  This will DELETE ALL simulation data. Continue?")]
sim-nuke:
    {{ sim_compose }} down -v

# Show simulation container status
sim-status:
    @{{ sim_compose }} ps -a
    @echo ""
    @{{ CONTAINER_CLI }} inspect rpi-sim-influxdb rpi-sim-grafana rpi-sim-telegraf rpi-sim-chronograf rpi-sim-speedtest-cron 2>/dev/null | jq -r '.[] | "  \(.Name | ltrimstr("/")): \(.State.Health.Status // "n/a")"' || true

# Show simulation logs
sim-logs lines="50":
    {{ sim_compose }} logs --tail={{ lines }}

# Follow simulation logs in real-time
sim-logs-follow:
    {{ sim_compose }} logs -f --tail=20

# Build the speedtest image for ARM64
sim-build:
    {{ sim_compose }} build speedtest

# Run a manual speedtest in the simulation
sim-speedtest:
    {{ sim_compose }} run --rm speedtest

# Open an InfluxDB shell in the simulation
sim-influx-shell:
    {{ CONTAINER_CLI }} exec -it rpi-sim-influxdb influx -username admin -password simpass

# Show simulation stats (databases, counts, disk)
sim-stats:
    @echo "── Databases ──"
    @{{ CONTAINER_CLI }} exec rpi-sim-influxdb influx -username admin -password simpass -execute "SHOW DATABASES"
    @echo ""
    @echo "── Retention Policies ──"
    @for db in speedtest telegraf; do \
        echo "  $db:"; \
        {{ CONTAINER_CLI }} exec rpi-sim-influxdb influx -username admin -password simpass -execute "SHOW RETENTION POLICIES ON $db" 2>/dev/null | tail -2; \
        echo ""; \
    done
    @echo "── Data Counts ──"
    @printf "  Speedtest points: %s\n" "$({{ CONTAINER_CLI }} exec rpi-sim-influxdb influx -username admin -password simpass -execute 'SELECT COUNT(download_bandwidth) FROM speedtest' -database speedtest 2>/dev/null | tail -1 | awk '{print $2}')"
    @printf "  Telegraf cpu (last 1h): %s\n" "$({{ CONTAINER_CLI }} exec rpi-sim-influxdb influx -username admin -password simpass -execute 'SELECT COUNT(usage_idle) FROM cpu WHERE time > now() - 1h' -database telegraf 2>/dev/null | tail -1 | awk '{print $2}')"

# Restore an RPi backup into the sim stack (e.g. just sim-restore-backup backups-rpi/20260416-205640)
sim-restore-backup dir:
    bash scripts/sim-restore-backup.sh {{ dir }}

# Verify that restored backup data is intact and exploitable
sim-verify-backup:
    bash scripts/sim-verify-backup.sh

# Full backup test: nuke sim, restart, restore, verify (e.g. just sim-test-backup backups-rpi/20260416-205640)
sim-test-backup dir:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "── Step 0/5: Offline integrity check ──"
    bash scripts/backup-check.sh {{ dir }}
    echo ""
    echo "── Step 1/5: Nuke sim stack ──"
    {{ sim_compose }} down -v 2>/dev/null || true
    echo ""
    echo "── Step 2/5: Start fresh sim stack ──"
    {{ sim_compose }} up -d
    echo ""
    echo "── Step 3/5: Wait for InfluxDB healthy ──"
    for i in $(seq 1 60); do
        if curl -sf "http://localhost:8086/ping" >/dev/null 2>&1; then
            echo "  ✅ InfluxDB healthy after ~$((i * 5))s"
            break
        fi
        if [[ "$i" -eq 60 ]]; then
            echo "  ❌ InfluxDB not healthy after 300s"
            exit 1
        fi
        sleep 5
    done
    echo ""
    echo "── Step 4/5: Restore ──"
    bash scripts/sim-restore-backup.sh {{ dir }}
    echo ""
    echo "── Step 5/5: Verify ──"
    bash scripts/sim-verify-backup.sh

# Register QEMU user-static (needed once per host reboot)
sim-binfmt:
    {{ CONTAINER_CLI }} run --rm --privileged multiarch/qemu-user-static --reset -p yes

# Run the sim smoke test suite (25 checks)
sim-test:
    ./scripts/test-sim-stack.sh
