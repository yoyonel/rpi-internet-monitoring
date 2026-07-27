# Handoff & Verification Guide: Cross-Platform Stability

**Version**: 1.0
**Target Platforms**: Raspberry Pi 4 (Prod), Debian 13 (Docker), Bazzite (Podman/SELinux)

---

## 🏗 Environment Context Matrix

Use this matrix to configure your `.env` file and verify environment detection.

| Feature             | Bazzite (Podman Rootless)                | Debian 13 / RPi (Docker)    |
| :------------------ | :--------------------------------------- | :-------------------------- |
| **`CONTAINER_CLI`** | `podman` (Auto-detected)                 | `docker` (Auto-detected)    |
| **`DOCKER_SOCK`**   | `/run/user/1000/podman/podman.sock`      | `/var/run/docker.sock`      |
| **SELinux Context** | `security_opt: label=disable` (Required) | Ignored by Docker           |
| **User Mapping**    | Rootless (UID 1000 -> 0)                 | Rooted (UID 0 -> 0)         |
| **Automation**      | Native Container Cron                    | Native Container Cron (New) |

---

## 🚨 Production Migration Checklist (RPi 4)

When deploying this branch to the Raspberry Pi for the first time, follow these steps to avoid regressions.

### 1. The "Double Cron" Risk

**Issue**: This branch introduces a `speedtest-cron` container. If your RPi already has a systemd timer, you will get duplicate data.

- **Action**: Disable the legacy timer on the RPi host:
  ```bash
  sudo systemctl stop speedtest.timer
  sudo systemctl disable speedtest.timer
  ```
- **Verification**: Check InfluxDB logs or Grafana to ensure data points arrive every 10 minutes, not every 5.

### 2. Volume Permissions

**Issue**: If you migrate data from a Podman Rootless host to a Docker host.

- **Action**: Check if InfluxDB starts correctly. If it fails with "Permission Denied", the folders in `influxdb-data` might be owned by an mapped UID (like 100999).
- **Fix**: Grant ownership back to root or the container UID: `sudo chown -R root:root ./volumes/influxdb-data`.

---

## ✅ Verification Commands

Run these commands on **any** device to ensure "ISO" compliance.

### 1. Environment Detection

```bash
just status
```

_Expected_: Should list all services, including `speedtest-cron`. Verify the engine name (Docker/Podman) in the output.

### 2. Stack Integration (Simulated)

```bash
just test-sim
```

_Expected_: Starts a full simulation stack. All containers should reach `healthy` status.

### 3. Linting Parity

```bash
pre-commit run --all-files
```

_Expected_: All checks **Passed**. If this passes on any machine, it **will** pass on GitHub CI.

---

## 🤖 AI Handoff Prompt (For Claude/Other LLMs)

> "You are taking over the `feat/podman-rootless-and-cleanup` branch. Your goal is to verify architectural parity between Podman (Bazzite) and Docker (Debian/RPi).
>
> 1. Read `docs/2026-04-18-podman-docker-hybrid-migration.md` for arch choices.
> 2. Read `docs/handoff-verification-guide.md` for environment configs.
> 3. Verify that `Justfile` correctly abstracts `CONTAINER_CLI`.
> 4. Ensure `security_opt: label=disable` is present in `docker-compose.yml` for all services (SELinux safety).
> 5. Confirm that `speedtest-cron` logic in `docker-compose.yml` doesn't conflict with legacy host-side scripts."

---

## 📉 Potential Regressions to Watch

- **Socket Path**: If `DOCKER_SOCK` is not set in `.env`, the stack will default to `/var/run/docker.sock`. This will fail on Podman Rootless.
- **Grafana Provisioning**: If `grafana-storage` volume is reused from an old version, the new folder structure ("RPi Monitoring") might look duplicated. **Fix**: Wipe the volume with `just down -v` if needed (destructive!).
