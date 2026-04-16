# ──────────────────────────────────────────────────────────
# Monitoring Débit Internet — RPi4 Maintenance Justfile
# ──────────────────────────────────────────────────────────
# Usage: just <recipe>
# List:  just --list

set shell := ["bash", "-eo", "pipefail", "-c"]

compose := "docker compose"
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
    @docker inspect influxdb grafana chronograf telegraf 2>/dev/null | jq -r '.[] | "  \(.Name | ltrimstr("/")): \(.State.Health.Status)"'

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
    @docker exec influxdb influx \
        -execute "SELECT download_bandwidth/1000000 AS dl_mbps, upload_bandwidth/1000000 AS ul_mbps, ping_latency FROM speedtest ORDER BY time DESC LIMIT {{ n }}" \
        -database speedtest -precision rfc3339

# ── Backup & Restore ───────────────────────────────────

# Create a full backup (dashboards + InfluxDB)
backup:
    bash scripts/backup.sh

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
    @docker image prune -f
    @echo ""
    @echo "── Pruning build cache ──"
    @docker builder prune -f
    @echo ""
    @docker system df

# Full cleanup: clean + remove unused images (DESTRUCTIVE)
clean-all: clean
    @echo ""
    @echo "── Removing unused images ──"
    @docker image prune -a -f
    @echo ""
    @docker system df

# ── Testing ─────────────────────────────────────────────

# Run the regression test suite (17 checks)
test:
    bash test-stack.sh

# Quick health check (services only)
check:
    bash scripts/check.sh

# ── Utilities ───────────────────────────────────────────

# Show alert rules and their current state
alerts:
    bash scripts/alerts.sh {{ project_dir }}

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
    bash scripts/install-timers.sh {{ project_dir }}

# Uninstall systemd user timers
uninstall-timers:
    bash scripts/uninstall-timers.sh

# Show systemd timer status and recent logs
timer-status:
    bash scripts/timer-status.sh

# Open an InfluxDB CLI shell
influx-shell:
    docker exec -it influxdb influx

# Open a bash shell in a container
shell svc:
    docker exec -it {{ svc }} bash 2>/dev/null || docker exec -it {{ svc }} sh

# Show the active crontab entry
cron:
    @crontab -l 2>/dev/null | grep -v "^#" | grep . || echo "(no cron entries)"
