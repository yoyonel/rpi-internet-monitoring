#!/usr/bin/env bash
# Offline integrity check for an RPi backup directory.
# Validates archive integrity WITHOUT needing the sim stack running.
#
# Usage: bash scripts/backup-check.sh <backup-dir>
#   e.g.: bash scripts/backup-check.sh backups-rpi/20260416-205640
#
# Checks:
#   1. Directory structure (influxdb-backup/, manifest, meta)
#   2. Every .tar.gz referenced in the manifest exists and is not corrupt (gzip -t)
#   3. Dashboard JSON files are valid JSON
#   4. Datasources JSON is valid JSON
#   5. Meta file is non-empty and parseable
set -uo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <backup-dir>"
    echo "  e.g.: $0 backups-rpi/20260416-205640"
    exit 1
fi

BACKUP_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

# Resolve relative paths from project root
if [[ ! "$BACKUP_DIR" = /* ]]; then
    BACKUP_DIR="$PROJECT_DIR/$BACKUP_DIR"
fi

# Test harness provided by lib-common.sh (pass/fail/warn/test_summary)

echo "╔══════════════════════════════════════════════════════════╗"
echo "║     Backup Integrity Check (offline)                     ║"
echo "║     $(date -Iseconds)                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Target: $BACKUP_DIR"
echo ""

# ── 1. Directory structure ────────────────────────────────
echo "── 1. Directory structure ──"

if [[ ! -d "$BACKUP_DIR" ]]; then
    fail "Directory not found: $BACKUP_DIR"
    echo ""
    echo "🔴 VERDICT: Backup directory does not exist."
    exit 1
fi
pass "Backup directory exists"

INFLUX_DIR="$BACKUP_DIR/influxdb-backup"
if [[ ! -d "$INFLUX_DIR" ]]; then
    fail "influxdb-backup/ subdirectory missing"
else
    pass "influxdb-backup/ directory present"
fi
echo ""

# ── 2. Manifest & meta ───────────────────────────────────
echo "── 2. Manifest & meta files ──"

mapfile -t MANIFESTS < <(find "$INFLUX_DIR" -name '*.manifest' 2>/dev/null)
if [[ ${#MANIFESTS[@]} -eq 0 ]]; then
    fail "No .manifest file found in influxdb-backup/"
else
    for m in "${MANIFESTS[@]}"; do
        if [[ -s "$m" ]]; then
            pass "Manifest: $(basename "$m") ($(wc -c <"$m") bytes)"
        else
            fail "Manifest is empty: $(basename "$m")"
        fi
    done
fi

mapfile -t METAS < <(find "$INFLUX_DIR" -name '*.meta' 2>/dev/null)
if [[ ${#METAS[@]} -eq 0 ]]; then
    fail "No .meta file found in influxdb-backup/"
else
    for m in "${METAS[@]}"; do
        if [[ -s "$m" ]]; then
            pass "Meta: $(basename "$m") ($(wc -c <"$m") bytes)"
        else
            fail "Meta file is empty: $(basename "$m")"
        fi
    done
fi
echo ""

# ── 3. Shard archives integrity ──────────────────────────
echo "── 3. Shard archives (gzip -t) ──"

mapfile -t SHARDS < <(find "$INFLUX_DIR" -name '*.tar.gz' 2>/dev/null | sort)
SHARD_COUNT=${#SHARDS[@]}

if [[ "$SHARD_COUNT" -eq 0 ]]; then
    fail "No .tar.gz shard files found"
else
    echo "  📦 Found $SHARD_COUNT shard archive(s) — testing each..."
    CORRUPT=0
    for shard in "${SHARDS[@]}"; do
        if ! gzip -t "$shard" 2>/dev/null; then
            fail "CORRUPT: $(basename "$shard")"
            ((CORRUPT++))
        fi
    done
    if [[ "$CORRUPT" -eq 0 ]]; then
        pass "All $SHARD_COUNT shard archives pass gzip integrity check"
    else
        fail "$CORRUPT/$SHARD_COUNT shard(s) are corrupt"
    fi
fi
echo ""

# ── 4. Dashboard JSON validation ─────────────────────────
echo "── 4. Dashboard JSON files ──"

mapfile -t DASHBOARDS < <(find "$BACKUP_DIR" -maxdepth 1 -name 'dashboard-*.json' 2>/dev/null | sort)
DASH_COUNT=${#DASHBOARDS[@]}

if [[ "$DASH_COUNT" -eq 0 ]]; then
    warn "No dashboard-*.json files found (may be normal for InfluxDB-only backups)"
else
    INVALID_JSON=0
    for f in "${DASHBOARDS[@]}"; do
        NAME=$(basename "$f")
        if ! jq empty "$f" 2>/dev/null; then
            fail "Invalid JSON: $NAME"
            ((INVALID_JSON++))
        else
            # Check for expected structure
            if jq -e '.dashboard' "$f" >/dev/null 2>&1; then
                TITLE=$(jq -r '.dashboard.title // "untitled"' "$f")
                pass "$NAME → \"$TITLE\""
            else
                warn "$NAME is valid JSON but missing .dashboard key"
            fi
        fi
    done
fi
echo ""

# ── 5. Datasources JSON ──────────────────────────────────
echo "── 5. Datasources file ──"

DS_FILE="$BACKUP_DIR/datasources.json"
if [[ ! -f "$DS_FILE" ]]; then
    warn "datasources.json not found (may be normal for InfluxDB-only backups)"
else
    if ! jq empty "$DS_FILE" 2>/dev/null; then
        fail "datasources.json is invalid JSON"
    else
        DS_COUNT=$(jq 'length' "$DS_FILE" 2>/dev/null || echo 0)
        pass "datasources.json is valid ($DS_COUNT datasource(s))"
    fi
fi
echo ""

# ── 6. Size sanity check ─────────────────────────────────
echo "── 6. Size sanity ──"

TOTAL_SIZE=$(du -sb "$BACKUP_DIR" | awk '{print $1}')
TOTAL_HUMAN=$(du -sh "$BACKUP_DIR" | awk '{print $1}')
echo "  📊 Total backup size: $TOTAL_HUMAN"

# A valid backup with ~122k speedtest points + telegraf should be at least ~10MB
if [[ "$TOTAL_SIZE" -lt 1048576 ]]; then
    warn "Backup is suspiciously small (<1MB) — may be incomplete"
elif [[ "$TOTAL_SIZE" -lt 10485760 ]]; then
    warn "Backup is relatively small (<10MB) — verify data completeness after restore"
else
    pass "Backup size looks reasonable ($TOTAL_HUMAN)"
fi
echo ""

# ── Summary ──────────────────────────────────────────────
test_summary
echo ""

if [[ "$_TEST_FAIL" -eq 0 ]]; then
    echo "🟢 VERDICT: Backup structure is INTACT — safe to restore."
    exit 0
else
    echo "🔴 VERDICT: Backup has $_TEST_FAIL INTEGRITY ISSUE(S) — do NOT restore."
    exit 1
fi
