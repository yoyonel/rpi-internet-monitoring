# Backup Restore Tooling

Automated tools for validating, restoring, and verifying RPi backup
archives in the local simulation stack. Provides a 3-level verification
pipeline: offline integrity check → restore into sim → data verification.

## Overview

```
backups-rpi/
  20260416-205640/                ← rsync'd from RPi
    influxdb-backup/              ← InfluxDB portable dump
      *.manifest, *.meta, *.tar.gz
    dashboard-*.json              ← Grafana dashboard exports
    datasources.json              ← Grafana datasource config

                    ┌──────────────────────────┐
                    │ just backup-check <dir>   │  Level 1: Offline
                    │ (no stack needed)         │  gzip -t, JSON, manifest
                    └──────────┬───────────────┘
                               │
                    ┌──────────▼───────────────┐
                    │ just sim-restore-backup   │  Level 2: Restore
                    │ <dir>                     │  influxd restore + dashboards
                    └──────────┬───────────────┘
                               │
                    ┌──────────▼───────────────┐
                    │ just sim-verify-backup    │  Level 3: Data verification
                    │                           │  counts, dates, Grafana
                    └──────────────────────────┘

    just sim-test-backup <dir>   ← runs all 3 levels end-to-end
```

## Justfile recipes

| Recipe                          | Stack needed | Description                                            |
| ------------------------------- | ------------ | ------------------------------------------------------ |
| `just backup`                   | yes          | Full backup + automatic rotation (keep last 5)         |
| `just backup-rotate [N]`        | no           | Standalone rotation: keep N most recent (default 5)    |
| `just backup-check <dir>`       | no           | Offline integrity: gzip -t on all shards, JSON valid   |
| `just sim-restore-backup <dir>` | yes          | Drop DBs, restore InfluxDB, import dashboards          |
| `just sim-verify-backup`        | yes          | 10 checks: counts, date range, Grafana connectivity    |
| `just sim-test-backup <dir>`    | auto         | Full pipeline: nuke → start → check → restore → verify |

## Scripts

| Script                          | Purpose                                            |
| ------------------------------- | -------------------------------------------------- |
| `scripts/backup.sh`             | Full backup + automatic rotation                   |
| `scripts/backup-check.sh`       | Offline validation (manifest, meta, gzip -t, JSON) |
| `scripts/sim-restore-backup.sh` | Restore backup into running sim stack              |
| `scripts/sim-verify-backup.sh`  | Verify restored data integrity and Grafana state   |

## Level 1 — Offline integrity check (`backup-check`)

Validates a backup directory without needing any running stack. Checks:

1. **Directory structure**: `influxdb-backup/` exists
2. **Manifest & meta**: present and non-empty
3. **Shard archives**: every `.tar.gz` passes `gzip -t` (detects truncated/corrupt files from interrupted rsync)
4. **Dashboard JSON**: valid JSON with `.dashboard` key
5. **Datasources JSON**: valid JSON, datasource count
6. **Size sanity**: warns if backup is suspiciously small (<1 MB)

```bash
just backup-check backups-rpi/20260416-205640
# 🟢 VERDICT: Backup structure is INTACT — safe to restore.
```

## Level 2 — Restore (`sim-restore-backup`)

Restores an RPi backup into the running sim stack:

1. Validates backup directory structure
2. Checks sim stack is running and InfluxDB is healthy
3. Drops existing `speedtest` and `telegraf` databases
4. Copies `influxdb-backup/` into the InfluxDB container
5. Runs `influxd restore -portable`
6. Re-grants permissions to the `telegraf` user
7. Imports Grafana dashboards with **datasource fix**: panels with
   `datasource: null` and `measurement == "speedtest"` are patched
   to use the explicit `influxdb-speedtest` datasource UID (prevents
   the "No data" issue caused by Grafana's default pointing to telegraf)

```bash
just sim-up                                        # if not running
just sim-restore-backup backups-rpi/20260416-205640
```

## Level 3 — Data verification (`sim-verify-backup`)

Post-restore validation with 10 checks:

1. Databases `speedtest` and `telegraf` exist
2. `download_bandwidth` count (expected >100k for full production backup)
3. First measurement date (expected 2022)
4. Last measurement date (expected 2026)
5. Telegraf measurements present
6. Grafana datasource connectivity (2 datasources)
7. Grafana dashboard count and listing

```bash
just sim-verify-backup
# 🟢 VERDICT: Backup is EXPLOITABLE — data restored successfully.
```

## Full pipeline (`sim-test-backup`)

Runs all 3 levels end-to-end with a fresh sim stack:

```bash
just sim-test-backup backups-rpi/20260416-205640
```

Pipeline steps: 0. Offline integrity check (fails fast if backup is corrupt)

1. Nuke existing sim stack (`docker compose down -v`)
2. Start fresh sim stack
3. Wait for InfluxDB healthy
4. Restore backup
5. Verify data integrity

## Known issues

### Datasource null in RPi dashboards

RPi Grafana dashboards may have `datasource: null` on speedtest panels,
meaning they use the Grafana default datasource. In production, the default
is `InfluxDB-Speedtest` (database: `speedtest`). In the sim stack, the
default is `InfluxDB` (database: `telegraf`), causing "No data" in dashboards.

The restore script automatically patches these panels during import.

## Backup rotation

Rotation is built into `scripts/backup.sh` and runs automatically after
each backup. The `BACKUP_KEEP` environment variable controls how many
backups to retain (default: **5**). Older backups are deleted by
chronological directory name (`YYYYMMDD-HHMMSS`).

```bash
# Automatic: rotation runs at the end of every backup
just backup

# Manual: rotate without creating a new backup
just backup-rotate      # keep 5 (default)
just backup-rotate 3    # keep 3
BACKUP_KEEP=10 just backup   # override during backup
```

### QEMU query performance

COUNT/ORDER BY queries on 120k+ points through ARM64 QEMU emulation can
take 30-60 seconds. The verify script uses the InfluxDB HTTP API directly
(not the emulated `influx` CLI) for better performance.
