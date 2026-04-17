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
sim/telegraf-sim.conf         ← Telegraf config adapted for x86 host
docker-compose.yml            ← base compose (shared with production)
```

The simulation uses Docker Compose's override mechanism:

```bash
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

| Service      | Override                                                  | Why                                                                               |
| ------------ | --------------------------------------------------------- | --------------------------------------------------------------------------------- |
| All services | `platform: linux/arm64`                                   | Force ARM64 emulation via QEMU                                                    |
| All services | `mem_limit` / `memswap_limit`                             | Simulate RPi4 4 GB memory budget                                                  |
| influxdb     | `cap_add: CHOWN, DAC_OVERRIDE, SETUID, SETGID, FOWNER`    | Entrypoint needs these to init data dir (base compose has `cap_drop: ALL`)        |
| influxdb     | Healthcheck: `timeout 30s, retries 10, start_period 120s` | QEMU emulation is ~10× slower than native                                         |
| influxdb     | `ports: 127.0.0.1:8086:8086`                              | Expose for external tooling                                                       |
| influxdb     | `INFLUXDB_MONITOR_STORE_ENABLED: false`                   | Skip `_internal` database to save resources                                       |
| telegraf     | `hostname: rpi-sim`, custom `telegraf-sim.conf`           | x86-compatible inputs (thermal_zone0 instead of BCM2711, wildcard net interfaces) |
| speedtest    | `platform: linux/arm64` + ARM64 build                     | Build the speedtest image for ARM64                                               |

### Memory budget (RPi4 — 4 GB)

| Service             | mem_limit   | memswap_limit |
| ------------------- | ----------- | ------------- |
| Grafana             | 512 MB      | 768 MB        |
| InfluxDB            | 1 GB        | 1.5 GB        |
| Telegraf            | 256 MB      | 384 MB        |
| Chronograf          | 256 MB      | 384 MB        |
| docker-socket-proxy | 64 MB       | 64 MB         |
| **Total**           | **~2.1 GB** | **~3.1 GB**   |

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
| `sim-binfmt`       | Register QEMU binfmt handlers                             |

## Troubleshooting

### InfluxDB fails to start (permission denied)

The base compose uses `cap_drop: ALL`. The InfluxDB 1.8 entrypoint
runs `mkdir` / `chown` on its data directory. The sim overlay adds
back the minimum capabilities needed (`CHOWN`, `DAC_OVERRIDE`, `SETUID`,
`SETGID`, `FOWNER`).

### InfluxDB healthcheck timeout under QEMU

ARM64 emulation on x86 is ~10× slower. The sim overlay increases
`start_period` to 120s and `retries` to 10. First startup can take
2-3 minutes.

### Empty dashboards after first boot

InfluxDB auto-creates the `telegraf` and `speedtest` databases on
first start, but the `telegraf` user may lack privileges. If dashboards
show no data, grant access:

```bash
just sim-influx-shell
> GRANT ALL ON telegraf TO telegraf
> GRANT ALL ON speedtest TO telegraf
```

### Running a speedtest

The `speedtest` service uses `profiles: [run-once]` — it does not start
with `docker compose up`. Trigger it manually:

```bash
just sim-speedtest
```
