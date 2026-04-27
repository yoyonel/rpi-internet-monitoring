# Simulation Environment (ARM64 on x86)

Run the full RPi4 monitoring stack locally on an x86_64 host using QEMU
user-mode emulation. Every container runs as `linux/arm64` — the same
architecture as the production Raspberry Pi — so images, configs and
dashboards are tested in near-production conditions.

## Prerequisites

| Tool             | Version tested | Notes               |
| ---------------- | -------------- | ------------------- |
| Docker           | 25.9+          | Compose V2 built-in |
| QEMU user-static | latest         | ARM64 emulation     |

Register the QEMU binfmt handlers (once per host reboot):

```bash
just sim-binfmt
# or: docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

## Quick start

```bash
just sim-up        # start the whole stack
just sim-status    # check container health
just sim-logs      # last 50 lines of logs
```

Grafana: <http://localhost:3000> (admin / simpass)
Chronograf: <http://localhost:8888>
InfluxDB API: <http://localhost:8086> (admin / simpass)

## Architecture

```
sim/.env.sim                  ← credentials (safe local defaults)
sim/docker-compose.sim.yml    ← ARM64 override layer
sim/influxdb-init.iql         ← creates databases + grants on first boot
sim/telegraf-sim.conf         ← Telegraf config adapted for x86 host
scripts/speedtest-loop.sh      ← periodic speedtest loop (replaces systemd timer)
docker-compose.yml            ← base compose (shared with production)
```

The simulation uses Docker Compose's override mechanism. Because the
Justfile uses `set dotenv-load` (which loads `.env` prod credentials
into the shell), the sim recipes first source `sim/.env.sim` to
override them — shell env vars have higher precedence than
`--env-file` in Docker Compose:

```bash
# What `just sim-up` expands to:
set -a && . sim/.env.sim && set +a && \
  docker compose \
    -f docker-compose.yml \
    -f sim/docker-compose.sim.yml \
    --env-file sim/.env.sim \
    -p rpi-sim \
    up -d
```

The `-p rpi-sim` project name isolates containers and volumes from any
production deployment on the same host.

### What the sim overlay changes

| Service      | Override                                                                | Why                                                                                |
| ------------ | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| All services | `platform: linux/arm64`                                                 | Force ARM64 emulation via QEMU                                                     |
| All services | `mem_limit` / `memswap_limit`                                           | Simulate RPi4 4 GB memory budget                                                   |
| influxdb     | `cap_add: CHOWN, DAC_OVERRIDE, SETUID, SETGID, FOWNER`                  | Entrypoint needs these to init data dir (base compose has `cap_drop: ALL`)         |
| influxdb     | Healthcheck: `curl /ping`, `timeout 15s, retries 20, start_period 300s` | QEMU emulation is ~10× slower; lightweight HTTP ping instead of heavy `influx` CLI |
| influxdb     | `ports: 127.0.0.1:8086:8086`                                            | Expose for external tooling                                                        |
| influxdb     | `INFLUXDB_MONITOR_STORE_ENABLED: false`                                 | Skip `_internal` database to save resources                                        |
| telegraf     | `hostname: rpi-sim`, custom `telegraf-sim.conf`                         | x86-compatible inputs (thermal_zone0 instead of BCM2711, wildcard net interfaces)  |
| influxdb     | `influxdb-init.iql` mounted in `/docker-entrypoint-initdb.d/`           | Creates `telegraf` + `speedtest` databases and grants on first boot (empty volume) |
| speedtest    | `platform: linux/arm64` + ARM64 build + admin credentials               | Build the speedtest image for ARM64; use admin creds for `CREATE DATABASE`         |

### Memory budget (RPi4 — 4 GB)

| Service             | mem_limit   | memswap_limit |
| ------------------- | ----------- | ------------- |
| Grafana             | 512 MB      | 768 MB        |
| InfluxDB            | 1 GB        | 1.5 GB        |
| Telegraf            | 256 MB      | 384 MB        |
| Chronograf          | 256 MB      | 384 MB        |
| docker-socket-proxy | 64 MB       | 64 MB         |
| speedtest-cron      | 256 MB      | 384 MB        |
| **Total**           | **~2.3 GB** | **~3.5 GB**   |

## Grafana provisioning

Datasources and dashboards are provisioned as code — no manual UI setup
required.

### Datasources (`grafana/provisioning/datasources/influxdb.yml`)

| Name               | UID                  | Database    | Default |
| ------------------ | -------------------- | ----------- | ------- |
| InfluxDB           | `2QPKy_O4k`          | `telegraf`  | Yes     |
| InfluxDB-Speedtest | `influxdb-speedtest` | `speedtest` | No      |

Credentials are injected via environment variables (`INFLUXDB_USER` /
`INFLUXDB_USER_PASSWORD`), set in `sim/.env.sim` for simulation or in
production `.env`.

### Dashboards (`grafana/provisioning/dashboards/dashboards.yml`)

A file provider watches `/var/lib/grafana/dashboards` (mounted from
`grafana/dashboards/`) and auto-reloads every 30 seconds.

| Dashboard           | File                     | Datasource                     |
| ------------------- | ------------------------ | ------------------------------ |
| Docker Containers   | `docker-containers.json` | InfluxDB (telegraf)            |
| RPi Alerts Overview | `rpi-alerts.json`        | InfluxDB (telegraf)            |
| Internet Speedtest  | `speedtest.json`         | InfluxDB-Speedtest (speedtest) |
| System Metrics      | `system-metrics.json`    | InfluxDB (telegraf)            |

Dashboard JSON files are in **raw format** (not wrapped in
`{"dashboard": {...}}` like Grafana API exports). The original export
files are preserved in `speedtest/dashboard.json` and
`telegraf/dashboard.json`.

## Telegraf sim config

`sim/telegraf-sim.conf` collects the same metrics as production but with
x86-compatible inputs:

- **CPU temperature**: reads `/sys/class/thermal/thermal_zone0/temp`
  (x86) instead of BCM2711 thermal sensor — produces the same
  `cpu_temperature` measurement
- **Network interfaces**: wildcard (auto-detect) instead of hardcoded
  `eth0` / `wlan0`
- **Docker**: same socket-proxy pattern as production
- **Tag**: `env = "sim"` to distinguish sim data from production

## Justfile recipes

| Recipe             | Description                                               |
| ------------------ | --------------------------------------------------------- |
| `sim-up`           | Start the full simulation stack                           |
| `sim-stop`         | Stop containers (preserve state)                          |
| `sim-down`         | Stop and remove containers (preserve volumes)             |
| `sim-nuke`         | Stop, remove containers AND volumes (confirmation prompt) |
| `sim-status`       | Container status + health checks                          |
| `sim-logs [lines]` | Show last N lines (default 50)                            |
| `sim-logs-follow`  | Follow logs in real-time                                  |
| `sim-build`        | Build the speedtest image for ARM64                       |
| `sim-speedtest`    | Run a manual speedtest                                    |
| `sim-influx-shell` | Open InfluxDB CLI in the sim container                    |
| `sim-stats`        | Show databases, retention policies, data counts           |
| `sim-test`         | Run the smoke test suite (25 checks, 7 sections)          |
| `sim-binfmt`       | Register QEMU binfmt handlers                             |

## Simulation fidelity vs production RPi

### What is identical

| Aspect                   | Detail                                                                                                                                                  |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Container images**     | Same images, same tags, same ARM64 binaries (InfluxDB 1.8.10, Grafana 12.4.3, Telegraf 1.38.2, Chronograf 1.9.4)                                        |
| **Compose base file**    | `docker-compose.yml` is shared — service definitions, networks, security options are the same                                                           |
| **InfluxDB schema**      | Same databases (`telegraf`, `speedtest`), same measurements, same field keys                                                                            |
| **Telegraf inputs**      | Same set of input plugins (cpu, mem, disk, diskio, swap, system, net, kernel, processes, netstat, interrupts, linux_sysctl_fs, docker, cpu_temperature) |
| **Telegraf output**      | Same InfluxDB output config (database, retention policy, auth)                                                                                          |
| **Grafana dashboards**   | Same JSON files, same datasource UIDs, same queries                                                                                                     |
| **Grafana provisioning** | Same datasource and dashboard provider config                                                                                                           |
| **Speedtest pipeline**   | Same Dockerfile, same `docker-entrypoint.sh`, same InfluxDB write format                                                                                |
| **Security posture**     | Same `cap_drop: ALL`, `no-new-privileges`, `read_only` (telegraf), socket-proxy pattern                                                                 |
| **Docker networking**    | Same bridge network, same service names, same inter-container DNS                                                                                       |

### What differs

| Aspect                         | Simulation (x86 + QEMU)                                  | Production (RPi4 native)                             | Impact                                                     |
| ------------------------------ | -------------------------------------------------------- | ---------------------------------------------------- | ---------------------------------------------------------- |
| **CPU architecture execution** | ARM64 user-mode emulated via QEMU (~10× slower)          | Native ARM Cortex-A72                                | Startup times and query latency are not representative     |
| **CPU temperature sensor**     | `/sys/class/thermal/thermal_zone0` (x86 CPU)             | BCM2711 thermal sensor (same sysfs path on RPi OS)   | Measurement name identical, values differ (x86 vs ARM SoC) |
| **Network interfaces**         | Wildcard (auto-detect: `docker0`, `eth0`, `veth*`, etc.) | Hardcoded `eth0` + `wlan0`                           | Sim collects more interfaces; field names identical        |
| **Hostname**                   | `rpi-sim`                                                | Real RPi hostname (`rpi-<user>`)                     | Queries using `WHERE host = 'xxx'` need adaptation         |
| **Memory limits**              | Docker `mem_limit` constraints                           | Physical 4 GB RAM                                    | Behavior under OOM may differ (Docker OOM-kill vs kernel)  |
| **Disk I/O**                   | Host SSD/NVMe (fast, even emulated)                      | microSD or USB SSD (slower, wear leveling)           | I/O latency and throughput not representative              |
| **Speedtest results**          | Host network (fibre/cable, low latency)                  | RPi network (Ethernet or WiFi, different throughput) | Bandwidth and latency values differ from real ISP metrics  |
| **Swap**                       | Host swap (may be large or absent)                       | RPi swap (typically 100 MB dphys-swapfile)           | Swap usage patterns differ                                 |
| **Docker metrics**             | Emulated containers (QEMU overhead in all stats)         | Native containers                                    | CPU/memory per container inflated by emulation overhead    |
| **Global tag**                 | `env = "sim"` (in telegraf-sim.conf)                     | No env tag (production telegraf.conf)                | Easy to distinguish in InfluxDB queries                    |
| **InfluxDB capabilities**      | `cap_add` for CHOWN/DAC_OVERRIDE/etc.                    | `cap_drop: ALL` only                                 | Sim is slightly more permissive (required for QEMU init)   |
| **Credentials**                | Hardcoded `simpass` in `.env.sim`                        | Real secrets in production `.env` (not in repo)      | No security concern — sim is local-only                    |
| **systemd timers**             | `speedtest-cron` container loop (every 10 min)           | `speedtest.timer` + `publish-gh-pages.timer`         | Speedtest cadence replicated; gh-pages publish untested    |
| **InfluxDB `_internal` DB**    | Disabled (`INFLUXDB_MONITOR_STORE_ENABLED: false`)       | Enabled by default                                   | No monitoring overhead data in sim                         |

### What you can rely on

**High confidence** — the simulation is a reliable proxy for:

- **Grafana dashboard development**: datasources, queries, panel layout, alerting rules — all identical. What renders in sim renders the same in production.
- **InfluxDB schema validation**: databases, measurements, field keys, retention policies — same data model.
- **Compose / container orchestration**: service dependencies, healthchecks, volume mounts, network topology — all exercised.
- **Telegraf plugin configuration**: same input/output plugins, same collection interval, same data format.
- **Speedtest data pipeline**: same Dockerfile, same entrypoint, same InfluxDB write path. Only the measured values differ.
- **Security configuration**: same security options and capability drops. The `cap_add` overrides in sim are an exception, documented above.
- **Provisioning-as-code workflow**: if dashboards and datasources provision correctly in sim, they will in production.

**Low confidence** — do not trust the simulation for:

- **Performance benchmarking**: QEMU adds ~10× overhead. CPU, memory, I/O metrics reflect the x86 host + emulation, not RPi4 hardware.
- **Capacity planning**: memory pressure, OOM behavior, swap usage are all distorted by the emulation layer and Docker memory limits.
- **Real network monitoring**: speedtest results measure the dev machine's connection, not the RPi's ISP link.
- **Disk wear / reliability**: host SSD ≠ RPi microSD. I/O patterns and failure modes are fundamentally different.
- **Temperature monitoring**: x86 thermal_zone0 values have no relation to BCM2711 temperatures.
- **Scheduling / cron**: the `speedtest-cron` container replaces `speedtest.timer` but uses a sleep loop, not a real scheduler. The `publish-gh-pages.timer` is not replicated.

### Summary

The simulation is a **functional test environment**, not a **performance
replica**. It validates that all components wire together correctly,
dashboards render with real data, and the provisioning pipeline works
end-to-end. It does _not_ replicate RPi4 hardware characteristics
(CPU speed, thermal behavior, SD card I/O, WiFi stability).

Rule of thumb: if it works in sim, the _configuration_ is correct. If
it doesn't work on the RPi, look at _hardware-specific_ factors (SD card
corruption, thermal throttling, network driver issues, kernel
differences).

## Troubleshooting

### InfluxDB fails to start (permission denied)

The base compose uses `cap_drop: ALL`. The InfluxDB 1.8 entrypoint
runs `mkdir` / `chown` on its data directory. The sim overlay adds
back the minimum capabilities needed (`CHOWN`, `DAC_OVERRIDE`, `SETUID`,
`SETGID`, `FOWNER`).

### InfluxDB healthcheck timeout under QEMU

ARM64 emulation on x86 is ~10× slower. The original healthcheck used
the `influx` CLI (a full Go binary), which took 60-90s per invocation
under QEMU — causing cascading timeouts after 405s+.

The fix replaces the CLI check with `curl -sf http://localhost:8086/ping`,
which responds in <100ms. The sim overlay sets `start_period: 300s` and
`retries: 20` for a generous 900s total budget. In practice, InfluxDB
becomes healthy in ~6s.

### Empty dashboards after first boot

The init script (`sim/influxdb-init.iql`) automatically creates both
databases and grants `ALL PRIVILEGES` to the `telegraf` user on first
boot. If dashboards still show no data after startup:

1. Verify InfluxDB is healthy: `just sim-status`
2. Check that databases exist: `just sim-stats`
3. If the schema is corrupted (e.g. field type conflict), nuke and
   recreate from scratch:

```bash
just sim-nuke
just sim-up
```

### Running a speedtest

The `speedtest-cron` service starts automatically with `just sim-up`
and runs a speedtest every 10 minutes (configurable via
`SPEEDTEST_INTERVAL` in `sim/docker-compose.sim.yml`), matching the
production `speedtest.timer` cadence.

To trigger an additional one-off speedtest:

```bash
just sim-speedtest
```

Check the cron logs:

```bash
just sim-logs-follow
# or: docker logs -f speedtest-cron
```

## CI / CD — Nightly sim smoke tests

A GitHub Actions workflow (`.github/workflows/sim-e2e-nightly.yml`)
runs the full sim stack on an Ubuntu runner every night and validates
the deployment end-to-end.

### Schedule

- **Nightly**: 03:30 UTC (offset from the existing GH Pages E2E at 03:00)
- **Manual**: `workflow_dispatch` — trigger from the Actions tab to
  validate a PR before merging

### Pipeline stages

```
binfmt → build → up → wait (InfluxDB healthy + Telegraf data) → smoke tests → teardown
```

| Stage                     | Duration (est.) | What it validates                                         |
| ------------------------- | --------------- | --------------------------------------------------------- |
| Register QEMU binfmt      | ~5s             | ARM64 emulation available on the runner                   |
| Build + start stack       | ~5 min          | Dockerfile builds, all images pull, compose orchestration |
| Wait for InfluxDB healthy | ~2-3 min        | Init script runs, databases + grants created              |
| Wait for Telegraf data    | ~90s            | Collection interval works under QEMU emulation            |
| Smoke tests               | ~15s            | 7 test sections (see below)                               |
| Teardown                  | ~10s            | Containers + volumes removed                              |
| **Total**                 | **~12-15 min**  |                                                           |

### What the smoke tests validate

The test script (`scripts/test-sim-stack.sh`) runs 7 sections:

1. **Service health** — Grafana, InfluxDB, Chronograf respond on their
   respective ports
2. **Grafana datasources** — 2 datasources exist (`InfluxDB`,
   `InfluxDB-Speedtest`), connectivity OK
3. **Grafana dashboards** — 4 dashboards provisioned (by UID)
4. **InfluxDB schema** — `telegraf` + `speedtest` databases exist,
   `telegraf` user has `ALL PRIVILEGES` on both
5. **Telegraf pipeline** — CPU data points written in the last 5 minutes
   (proves Telegraf → InfluxDB is working)
6. **Speedtest write path** — Injects a synthetic data point via the
   InfluxDB HTTP API, verifies it is queryable, then cleans up (avoids
   running a real speedtest — no network dependency, no QEMU slowness)
7. **Container state** — All 6 containers running (grafana, influxdb,
   chronograf, telegraf, docker-socket-proxy, speedtest-cron)

### Running locally

```bash
just sim-up
# Wait ~2 min for InfluxDB + Telegraf to settle
./scripts/test-sim-stack.sh
```

### Failure artifacts

On failure, the workflow uploads a `sim-e2e-logs` artifact containing
the full Docker Compose logs and container status (retained 7 days).
