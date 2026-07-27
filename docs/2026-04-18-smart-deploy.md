# Smart Deploy System

## Overview

`just deploy-smart` replaces manual SSH deployment workflows with a single command that automatically detects what changed and takes the minimal required actions.

## Usage

```bash
ssh rpi
cd ~/rpi-internet-monitoring
just deploy-smart
```

That's it. The script handles everything: pull, backup, build, restart, migrations, health check.

## How It Works

### 1. Git-Diff Based Decision Engine

After `git pull`, the script analyzes `git diff --name-only BEFORE..AFTER` to decide actions:

| Changed file pattern        | Action triggered                        |
| --------------------------- | --------------------------------------- |
| `Dockerfile`                | Rebuild speedtest image + recreate all  |
| `docker-entrypoint.sh`      | Rebuild speedtest image + recreate all  |
| `docker-compose.yml`        | Recreate all containers                 |
| `grafana/provisioning/*`    | Restart grafana only                    |
| `telegraf/*`                | Restart telegraf only                   |
| `scripts/*`, `docs/*`, etc. | No runtime action (active on next call) |

If multiple patterns match, the heaviest action wins (recreate > restart > nothing).

### 2. Automatic Backup

Before any destructive action (rebuild or recreate), the script runs `scripts/backup.sh` automatically. Script-only changes skip the backup.

### 3. Migration System

One-shot operations (disable a cron, create a Grafana folder, run a data migration) are tracked in `migrations/`:

```
migrations/
  001-disable-legacy-speedtest-scheduling.sh
  002-some-future-migration.sh
```

Rules:

- Files must match `[0-9]*.sh` (numbered prefix)
- Each migration runs exactly once per machine
- Applied migrations are tracked in `.migrations-applied` (gitignored, machine-local)
- Migrations run in alphabetical order
- A failed migration aborts the deploy (fix and re-run)

#### Writing a Migration

```bash
#!/usr/bin/env bash
# Migration: brief description of what this does.
set -euo pipefail

# Idempotent logic here — safe to run if already partially applied
echo "Doing the thing..."
```

Migrations should be **idempotent** when possible (check before acting).

### 4. Post-Deploy Health Check

After all actions, the script runs `scripts/check.sh` to verify service health, then shows container status.

## Output Example

```
▶ Pre-flight checks
  ✅ On branch: master
▶ Pulling latest changes
  ✅ Updated: 092840d → 6859413 (4 commits)
▶ Analyzing changes
  ✅ docker-compose.yml → recreate containers
  ✅ grafana/provisioning/alerting/alerts.yml → restart grafana
  ⊘ scripts/stats.sh (no runtime action needed)
  ⊘ docs/sim-environment.md (no runtime action needed)

  Plan: build=false recreate=true restart_grafana=false restart_telegraf=false
▶ Creating backup before destructive changes
  [backup output...]
▶ Recreating containers
  [compose output...]
▶ Running migration: 001-disable-legacy-speedtest-scheduling.sh
  ⊘ No crontab entry found (OK)
  ⊘ No speedtest.timer enabled (OK)
  ✅ Migration 001-disable-legacy-speedtest-scheduling.sh applied
▶ Post-deploy verification
  ✅ Grafana
  ✅ InfluxDB
  ✅ Telegraf
  ✅ Chronograf
  4/4 services healthy

╔══════════════════════════════════════════════════════════╗
║  Deploy complete — 2026-04-18T15:30:00+02:00
║  092840d → 6859413 (4 commits)
╚══════════════════════════════════════════════════════════╝
```

## What It Does NOT Do

- **Auto-pull on a schedule** — you still SSH and run `just deploy-smart` manually (Phase 2 would add a systemd timer for this)
- **Rollback on failure** — if a deploy breaks, you must manually `git reset --hard ORIG_HEAD && just down && just up` (Phase 2 would automate this)
- **Handle `.env` changes** — secrets are not in git; if you change `.env`, restart manually with `just restart`

## Advantages

| Before (manual)                            | After (`deploy-smart`)             |
| ------------------------------------------ | ---------------------------------- |
| Read changelog to decide what to do        | Automatic diff analysis            |
| Remember to backup before changes          | Automatic pre-deploy backup        |
| Decide: full recreate vs restart a service | Automatic minimal action           |
| Remember one-shot tasks (disable cron)     | Migrations tracked in git          |
| Run health checks after deploy             | Automatic post-deploy verification |
| ~5 min of thinking + typing                | 1 command, 0 thinking              |

## Risks and Mitigations

| Risk                                  | Likelihood | Impact | Mitigation                                                 |
| ------------------------------------- | ---------- | ------ | ---------------------------------------------------------- |
| Migration script has a bug            | Low        | Medium | Migrations are idempotent; fix and re-run `deploy-smart`   |
| Backup fails (disk full)              | Low        | High   | Deploy aborts on backup failure (`set -euo pipefail`)      |
| Service unhealthy after recreate      | Low        | Medium | Post-deploy check alerts you; `just logs` to diagnose      |
| `git pull --ff-only` fails (diverged) | Low        | None   | Deploy aborts cleanly; resolve manually                    |
| New compose service not detected      | None       | None   | `compose up -d` always picks up new services               |
| `.env` out of sync with new vars      | Rare       | High   | Check `.env.example` diff in PR; not automatable (secrets) |

## File Layout

```
scripts/deploy.sh                          # The deploy engine
migrations/                                # One-shot migration scripts
  001-disable-legacy-speedtest-scheduling.sh
.migrations-applied                        # Machine-local tracking (gitignored)
```
