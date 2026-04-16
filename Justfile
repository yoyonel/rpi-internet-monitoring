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
    #!/usr/bin/env bash
    set -eo pipefail
    printf "  %-12s %s\n" "Grafana:" "$(curl -sf http://localhost:3000/api/health | jq -r .version)"
    printf "  %-12s %s\n" "InfluxDB:" "$(docker exec influxdb influx -version 2>&1 | head -1)"
    printf "  %-12s %s\n" "Chronograf:" "$(docker exec chronograf chronograf --version 2>&1 | head -1)"
    printf "  %-12s %s\n" "Telegraf:" "$(docker exec telegraf telegraf --version 2>&1 | head -1)"
    printf "  %-12s %s\n" "Speedtest:" "bookworm ($(docker inspect speedtest:bookworm 2>/dev/null | jq -r '.[0].Created' 2>/dev/null | cut -dT -f1 || echo 'not built'))"

# Show data statistics (databases, counts, disk usage)
stats:
    #!/usr/bin/env bash
    set -eo pipefail
    echo "── Databases ──"
    docker exec influxdb influx -execute "SHOW DATABASES"
    echo ""
    echo "── Retention Policies ──"
    for db in speedtest telegraf _internal; do
        echo "  $db:"
        docker exec influxdb influx -execute "SHOW RETENTION POLICIES ON $db" 2>/dev/null | tail -2
        echo ""
    done
    echo "── Data Counts ──"
    printf "  Speedtest points: %s\n" "$(docker exec influxdb influx -execute "SELECT COUNT(download_bandwidth) FROM speedtest" -database speedtest 2>/dev/null | tail -1 | awk '{print $2}')"
    printf "  Telegraf (last 1h): %s cpu points\n" "$(docker exec influxdb influx -execute "SELECT COUNT(usage_idle) FROM cpu WHERE time > now() - 1h" -database telegraf 2>/dev/null | tail -1 | awk '{print $2}')"
    echo ""
    echo "── Disk Usage ──"
    docker exec influxdb du -sh /var/lib/influxdb/data/speedtest /var/lib/influxdb/data/telegraf /var/lib/influxdb/data/_internal 2>/dev/null || true
    echo ""
    docker system df

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
    #!/usr/bin/env bash
    set -eo pipefail
    PASS=0; FAIL=0
    for svc in "Grafana:http://localhost:3000/api/health" "Chronograf:http://localhost:8888/chronograf/v1/me"; do
        name=${svc%%:*}; url=${svc#*:}
        if curl -sf "$url" >/dev/null 2>&1; then printf "  ✅ %s\n" "$name"; PASS=$((PASS+1))
        else printf "  ❌ %s\n" "$name"; FAIL=$((FAIL+1)); fi
    done
    if docker exec influxdb influx -execute "SHOW DATABASES" >/dev/null 2>&1; then printf "  ✅ InfluxDB\n"; PASS=$((PASS+1))
    else printf "  ❌ InfluxDB\n"; FAIL=$((FAIL+1)); fi
    if docker exec telegraf pgrep telegraf >/dev/null 2>&1; then printf "  ✅ Telegraf\n"; PASS=$((PASS+1))
    else printf "  ❌ Telegraf\n"; FAIL=$((FAIL+1)); fi
    echo ""
    echo "$PASS/$((PASS+FAIL)) services healthy"

# ── Utilities ───────────────────────────────────────────

# Show alert rules and their current state
alerts:
    #!/usr/bin/env bash
    set -eo pipefail
    _user=$(grep '^GF_SECURITY_ADMIN_USER=' "{{ project_dir }}/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    _pass=$(grep '^GF_SECURITY_ADMIN_PASSWORD=' "{{ project_dir }}/.env" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    CREDS="${_user:-admin}:${_pass}"
    echo "── Alert Rules ──"
    curl -sf -u "$CREDS" "http://localhost:3000/api/prometheus/grafana/api/v1/rules" \
        | jq -r '.data.groups[].rules[] | "  \(if .state == "inactive" then "✅" elif .state == "firing" then "🔴" else "⚠️ " end) \(.name) [\(.state)] (\(.health))"'

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
    #!/usr/bin/env bash
    set -eo pipefail
    dir="$HOME/.config/systemd/user"
    mkdir -p "$dir"
    for unit in speedtest.service speedtest.timer publish-gh-pages.service publish-gh-pages.timer; do
        cp "{{ project_dir }}/systemd/$unit" "$dir/$unit"
        echo "  → $dir/$unit"
    done
    # Patch WorkingDirectory to actual project path
    sed -i "s|WorkingDirectory=.*|WorkingDirectory={{ project_dir }}|" "$dir/speedtest.service" "$dir/publish-gh-pages.service"
    systemctl --user daemon-reload
    systemctl --user enable --now speedtest.timer publish-gh-pages.timer
    echo ""
    echo "✅ Timers installed and started:"
    systemctl --user list-timers speedtest.timer publish-gh-pages.timer --no-pager

# Uninstall systemd user timers
uninstall-timers:
    #!/usr/bin/env bash
    set -eo pipefail
    systemctl --user disable --now speedtest.timer publish-gh-pages.timer 2>/dev/null || true
    dir="$HOME/.config/systemd/user"
    for unit in speedtest.service speedtest.timer publish-gh-pages.service publish-gh-pages.timer; do
        rm -f "$dir/$unit"
    done
    systemctl --user daemon-reload
    echo "✅ Timers uninstalled"

# Show systemd timer status and recent logs
timer-status:
    #!/usr/bin/env bash
    set -eo pipefail
    echo "── Timers ──"
    systemctl --user list-timers speedtest.timer publish-gh-pages.timer --no-pager 2>/dev/null || echo "  (no timers installed)"
    echo ""
    echo "── Recent speedtest runs ──"
    journalctl --user -u speedtest.service --no-pager -n 5 2>/dev/null || echo "  (no logs)"
    echo ""
    echo "── Recent publish runs ──"
    journalctl --user -u publish-gh-pages.service --no-pager -n 5 2>/dev/null || echo "  (no logs)"

# Open an InfluxDB CLI shell
influx-shell:
    docker exec -it influxdb influx

# Open a bash shell in a container
shell svc:
    docker exec -it {{ svc }} bash 2>/dev/null || docker exec -it {{ svc }} sh

# Show the active crontab entry
cron:
    @crontab -l 2>/dev/null | grep -v "^#" | grep . || echo "(no cron entries)"
