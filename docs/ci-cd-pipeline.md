# CI/CD Pipeline — GitHub Pages Deployment

## Architecture

Two independent systems publish the monitoring page to GitHub Pages:

### 1. RPi (systemd timer) — Data pipeline

Runs on the Raspberry Pi every 10 minutes. This is the **primary data source**.

```mermaid
graph LR
    A[systemd timer<br/>every 10 min] --> B[publish-gh-pages.sh]
    B --> C[InfluxDB<br/>speedtest data]
    B --> D[Grafana API<br/>alert rules]
    C --> E[render-template.py]
    D --> E
    E --> F[index.html + data.json<br/>+ alerts.json]
    F --> G[git push --force-with-lease<br/>→ gh-pages branch]
```

### 2. CI workflow (GitHub Actions) — Template rebuild

Triggered on push to `master` when frontend files change. Re-renders the page
template with **existing data** (from the gh-pages branch, not from production).

```mermaid
graph LR
    A[push to master<br/>gh-pages/** changed] --> B[deploy-gh-pages.yml]
    B --> C[git show origin/gh-pages:<br/>data.json + alerts.json]
    B --> D[render-template.py<br/>+ terser minification]
    C --> D
    D --> E[git push --force<br/>→ gh-pages branch]
```

### 3. PR preview (Surge)

Triggered on pull requests. Builds from **test fixtures** (no production dependency).

```mermaid
graph LR
    A[Pull Request] --> B[preview-pr.yml]
    B --> C[tests/fixtures/<br/>data.json + alerts.json]
    C --> D[render-template.py]
    D --> E[extract-live-data.py<br/>round-trip validation]
    E --> F[Deploy to Surge]
    F --> G[E2E tests + Lighthouse]
```

## Data flow — Before vs After

### Before (broken)

```mermaid
graph TD
    subgraph "PR Preview (broken)"
        A1[curl prod site HTML] --> A2[extract-live-data.py<br/>regex: RAW_DATA = ...]
        A2 -->|"FAIL: no inline data<br/>since PR #11"| A3[💥 Build fails]
    end

    subgraph "Deploy workflow (broken)"
        B1[curl prod site HTML] --> B2[extract-live-data.py<br/>regex: RAW_DATA = ...]
        B2 --> B3[upload-pages-artifact]
        B3 -->|"Pages API ≠ repo config<br/>(legacy branch mode)"| B4[💥 Deployed to void]
    end
```

### After (fixed)

```mermaid
graph TD
    subgraph "PR Preview"
        A1[tests/fixtures/] --> A2[render-template.py]
        A2 --> A3[extract-live-data.py<br/>round-trip check]
        A3 --> A4[✅ Surge + E2E + Lighthouse]
    end

    subgraph "Deploy workflow"
        B1[git show origin/gh-pages:<br/>data.json, alerts.json] --> B2[render-template.py]
        B2 --> B3[git push → gh-pages branch]
        B3 --> B4[✅ Consistent with repo config]
    end
```

## Key principles

1. **PR CI never depends on production** — uses versioned fixtures from `tests/fixtures/`
2. **Round-trip validation** — PR preview runs `render-template.py` then `extract-live-data.py` to verify pipeline consistency
3. **Single deployment method** — both RPi and CI use `git push` to the `gh-pages` branch (matches repo config: "Deploy from branch")
4. **Graceful fallbacks** — local scripts try live JSON → gh-pages branch → fixtures

## Concurrency

The RPi pushes every 10 minutes. The CI pushes on template changes. Both use `--force` to the same branch. The last writer wins, which is acceptable because:

- RPi writes **fresh data + current template**
- CI writes **existing data + updated template**
- The RPi will overwrite CI's push within 10 minutes with fresh data + the updated template (since it does `git pull` first)
