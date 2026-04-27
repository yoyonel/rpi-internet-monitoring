# Technical Migration Report: Docker/Podman Hybrid Architecture

**Date**: 2026-04-18
**Context**: Migration of the Internet Monitoring stack from a native RPi/Docker environment to a Rootless Podman environment (Bazzite/Fedora) while maintaining 100% ISO-compatibility with Debian/Docker environments.

---

## 🏗 Executive Summary

The transition from Docker-only to a Hybrid model was driven by the need to support high-security, rootless container engines (Podman) on modern Linux distributions like Bazzite, without breaking compatibility for existing deployments on Raspberry Pi or Debian 13.

The core philosophy adopted is **"Detection & Adaptation"**: the stack identifies its environment at runtime and applies the necessary security and networking configurations automatically.

---

## 🔌 1. Container Engine Abstraction

### Choice: Dynamic CLI Resolution

We replaced all hardcoded `docker` and `docker compose` calls in the `Justfile` and support scripts with a dynamic variable:

```just
export CONTAINER_CLI := env('CONTAINER_CLI', `command -v podman >/dev/null 2>&1 && echo podman || echo docker`)
```

The `env()` function first checks for an explicit `CONTAINER_CLI` in `.env` (or the environment), falling back to runtime auto-detection. This allows Distrobox/Bazzite users to pin `CONTAINER_CLI=docker` in their `.env` when Docker is available through the host but `podman` would be detected first.

### Justification

- **Portability**: Developers on Debian/Docker machines continue to use `docker` transparently.
- **Support for Rootless Podman**: On Bazzite systems, `podman` is used without requiring an alias, ensuring that the engine's internal behaviors (like user mapping) are correctly handled.
- **Distrobox compatibility**: Inside a Distrobox container, both `podman` and `docker` may be available but only the host Docker socket is functional. The explicit `CONTAINER_CLI` override avoids mis-detection.

---

## 🛡 2. Security & SELinux Compliance

### Choice: `label=disable` in Compose

Added `security_opt: - label=disable` to all services in the `docker-compose.yml`.

### Justification

- **SELinux Support**: On Fedora-based systems (Bazzite), a rootless container cannot mount host files (like `telegraf.conf` or `grafana/provisioning/`) unless specifically authorized. This flag disables the security label enforcement for these specific containers.
- **Compatibility**: This flag is ignored by Docker on Debian/Ubuntu/Raspberry Pi (non-SELinux systems), ensuring zero impact on legacy deployments.

### Choice: InfluxDB Capability Injection

Added `cap_add: [CHOWN, DAC_OVERRIDE, SETUID, SETGID, FOWNER]` to InfluxDB.

### Justification

- **Rootless volume init**: InfluxDB needs these capabilities to change ownership of its data directories when running as a non-privileged user in a rootless podman namespace.

---

## 🕒 3. Service Automation (Native Cron)

### Choice: `speedtest-cron` sidecar container

We introduced a dedicated service in `docker-compose.yml` that runs the `scripts/speedtest-loop.sh` logic.

### Justification

- **Host Independence**: Eliminates the dependency on host-side `systemd` timers, which are often missing or restricted in modern "immutable" distros like Bazzite.
- **Simplified Deployment**: One `just up` command now starts the entire lifecycle (monitoring + data collection + visualization).

---

## 🔍 4. Tooling & Linting Evolution

### Choice: "System" Hooks in Pre-commit

Moved from containerized pre-commit hooks to **System-based hooks** (`language: system`).

### Justification

- **Performance**: Instant execution (no container startup).
- **ISO Stability**: Avoids the "Docker-in-Docker" or "Docker-in-Podman" socket permission hell during linting. By using local binaries (installed via Brew or Apt), we ensure the linting environment is identical and successfull regardless of the container engine status.
- **Manual Control**: Guarantees that the developer's local environment is exactly matched with the code quality requirements.

---

## 🔄 5. 100% ISO CI/Local Unification

### Choice: `pre-commit` as the Single Source of Truth

We refactored the GitHub Actions workflow (`.github/workflows/lint.yml`) to remove all manual linter steps and replaced them with the official `pre-commit/action`.

### Justification

- **Zero Divergence**: Since both the developer's machine and the GitHub runner use the exact same `.pre-commit-config.yaml`, there is zero risk of "Linter Wars" (where one tool passes locally but fails on CI).
- **Maintenance**: Adding or modifying a check only requires an update in one place (the config file) instead of synchronized changes across multiple scripts and workflows.
- **Portability**: This architecture makes the project engine-agnostic; as long as `pre-commit` is installed, the quality gate is identical on any host.

---

## 🌐 6. Network Stability

### Choice: IPv4 (127.0.0.1) over `localhost`

Forced the use of `127.0.0.1` for local E2E tests and internal preview communication.

### Justification

- **Ghost 404 Resolution**: Some modern Linux environments resolve `localhost` to `::1` (IPv6) by default, while simple Python or Node.js servers might only bind to `127.0.0.1` (IPv4). This causes intermittent 404 errors during automated tests. Forcing IPv4 ensures stability.

---

## 🔑 7. Credential Resolution Strategy

### Choice: Environment Variables with .env File Fallback

All shell scripts (`stats.sh`, `check.sh`, `alerts.sh`, `backup.sh`, `publish-gh-pages.sh`) now prefer environment variables over hardcoded `.env` file parsing:

```bash
_influx_admin="${INFLUXDB_ADMIN_USER:-$(grep '^INFLUXDB_ADMIN_USER=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2-)}"
```

### Justification

- **Justfile `set dotenv-load`**: When scripts run via `just`, environment variables from `.env` are already injected by Just itself. The grep fallback is only needed for standalone execution (`bash scripts/stats.sh`).
- **Simulation compatibility**: The sim stack sources `sim/.env.sim` (with `simpass` credentials) before running compose. Without env var priority, scripts would always read `.env` (with `changeme` prod credentials), causing `401 Unauthorized` errors against the sim InfluxDB/Grafana.
- **Separation of concerns**: Credentials flow through the standard env-var mechanism instead of each script reimplementing its own `.env` parser.

---

## 🩺 8. InfluxDB Healthcheck Under QEMU

### Choice: HTTP `/ping` Instead of `influx` CLI

The sim overlay's InfluxDB healthcheck was changed from the full `influx` CLI command to a lightweight HTTP probe:

```yaml
healthcheck:
  test: ['CMD-SHELL', 'curl -sf http://localhost:8086/ping || exit 1']
  start_period: 300s
  retries: 20
```

### Justification

- **Performance**: The `influx` CLI under QEMU ARM64 emulation took 60-90s per invocation (Go binary startup + TLS + query). The `curl /ping` endpoint responds in <100ms, reducing healthcheck from ~405s to ~6s.
- **Reliability**: The CLI-based check often timed out during InfluxDB's first-boot initialization (creating databases, running init scripts), causing cascading container restarts.
- **Correctness**: `/ping` returns HTTP 204 only when the HTTP server is ready to accept connections — sufficient for a dependency healthcheck.

---

## 🔀 9. Sim Compose `dotenv-load` Conflict Resolution

### Problem

Just's `set dotenv-load` loads `.env` (prod credentials: `changeme`) into the shell environment. Docker Compose's `--env-file sim/.env.sim` only applies to variable substitution in the YAML file, but **shell environment variables have higher precedence**. Result: containers received prod credentials while InfluxDB was initialized with sim credentials → `401 Unauthorized`.

### Choice: Source sim credentials before compose

```just
sim_compose := "set -a && . sim/.env.sim && set +a && " + compose + " -f docker-compose.yml -f sim/docker-compose.sim.yml --env-file sim/.env.sim -p rpi-sim"
```

### Justification

- **Correct precedence**: `set -a && . sim/.env.sim` overwrites the dotenv-loaded prod values with sim values in the shell, ensuring containers receive `simpass`.
- **No Justfile architectural change**: Avoids removing `set dotenv-load` (which all prod recipes depend on) or introducing conditional env loading.

---

## ✅ Conclusion

The current `feat/podman-rootless-and-cleanup` branch achieves total parity. A developer on Debian 13 will experience a standard Docker setup, while a developer on Bazzite/Distrobox will experience a seamless Podman or Docker setup, with both benefiting from consolidated Grafana workspaces and robust automation. The credential resolution strategy ensures scripts work identically whether invoked via `just` (with dotenv-load), standalone, or against the simulation environment.
