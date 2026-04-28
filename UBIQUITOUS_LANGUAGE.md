# Ubiquitous Language

## Metrics

| Term                | Definition                                                                                       | Aliases to avoid                                    |
| ------------------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------------- |
| **Download** (`dl`) | Downstream bandwidth measured by Speedtest, expressed in Mb/s                                    | download_bandwidth (InfluxDB raw field, in bytes/s) |
| **Upload** (`ul`)   | Upstream bandwidth measured by Speedtest, expressed in Mb/s                                      | upload_bandwidth (InfluxDB raw field, in bytes/s)   |
| **Ping** (`pi`)     | Round-trip latency measured by Speedtest, expressed in ms                                        | ping_latency (InfluxDB raw field), latency, RTT     |
| **Measurement**     | A single Speedtest run producing one Download, one Upload, and one Ping value at a point in time | result, data point, sample, test                    |
| **System Metric**   | A host-level observation collected by Telegraf (CPU, RAM, disk, temperature)                     | telemetry, stat                                     |

## Data pipeline

| Term          | Definition                                                                                                                              | Aliases to avoid                  |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| **Speedtest** | The Ookla CLI tool that performs internet speed measurements every 10 minutes via a systemd timer                                       | speed test, bandwidth test, iperf |
| **InfluxDB**  | The time-series database (v1.8) that stores all Measurements and System Metrics                                                         | DB, database, Influx              |
| **Telegraf**  | The metrics agent that collects System Metrics every 20 seconds and writes them to InfluxDB                                             | collector, agent                  |
| **Publish**   | The pipeline step (`publish-gh-pages.sh`) that queries InfluxDB, renders the HTML template, and pushes to GitHub Pages every 10 minutes | deploy, export, sync              |
| **Timer**     | A systemd user timer that schedules Speedtest runs and Publish cycles, replacing crontab                                                | cron, crontab, scheduler          |

## Frontend (GitHub Pages)

| Term              | Definition                                                                                                                                         | Aliases to avoid                       |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| **Dashboard**     | The single static HTML page deployed on GitHub Pages that visualizes Measurements                                                                  | page, site, frontend, app              |
| **Stat Card**     | A DOM element displaying a metric's current median, quality dot, histogram, and decile chart for the active Time Range                             | card, tile, box                        |
| **Quality Score** | A composite indicator (0–1) combining Performance and Stability for a given metric over the active Time Range                                      | score, quality, indicator              |
| **Quality Dot**   | The colored circle (green → red via HSL gradient) on a Stat Card that visualizes the Quality Score                                                 | pastille, dot, badge, indicator        |
| **Band Chart**    | The Chart.js visualization showing min/Q1/median/Q3/max bands per time bucket, used when the Time Range exceeds 48 hours                           | box plot, bucket chart, quartile chart |
| **Line Chart**    | The Chart.js visualization showing LTTB-downsampled individual Measurements, used when the Time Range is ≤ 48 hours                                | scatter, point chart                   |
| **Histogram**     | A 10-bin SVG distribution chart inside a Stat Card showing the frequency distribution of values in the active Time Range                           | distribution, bar chart                |
| **Decile Chart**  | An SVG bar chart inside a Stat Card showing the 10 decile (P10–P100) values for the active Time Range                                              | percentile chart                       |
| **Time Range**    | The currently selected time window (start, end) controlling which Measurements are displayed                                                       | range, window, period, interval        |
| **Preset**        | A predefined Time Range duration (6h, 12h, 24h, 2d, 7d, 30d) or "Today" (midnight → now) selectable via toolbar buttons                            | button, quick range                    |
| **Today**         | A special Preset that sets the Time Range from midnight local time to the latest data point. Default view on page load                             | Auj., aujourd'hui                      |
| **Time Picker**   | The Grafana-style dropdown panel with a calendar, absolute inputs, relative presets, and recent ranges                                             | date picker, calendar, range picker    |
| **Status Bar**    | A GitHub-style 30-day uptime bar per metric (DL, UL, Ping). Each bar represents one day's Quality Score with a muted HSL color                     | uptime bar, daily status               |
| **Active Day**    | The Status Bar segment(s) overlapping the current Time Range, highlighted with an outline indicator                                                | selected day, current day              |
| **Sync Status**   | The colored dot in the nav bar indicating data freshness (OK < 10 min, degraded 10–20 min, error > 20 min)                                         | freshness indicator, staleness dot     |
| **Alert**         | A Grafana-provisioned threshold rule (CPU, temperature, RAM, swap, disk, load) whose state (firing/pending/inactive) is displayed on the Dashboard | warning, notification, alarm           |

## Algorithms

| Term                          | Definition                                                                                                                                         | Aliases to avoid                   |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| **LTTB**                      | Largest Triangle Three Buckets — a downsampling algorithm that preserves visual shape when reducing data points for Line Chart rendering           | downsampling, decimation, thinning |
| **Bucketize**                 | The aggregation step that groups Measurements into fixed-duration time buckets, computing min/Q1/median/Q3/max per bucket for Band Chart rendering | aggregate, bin, group              |
| **Performance Score**         | The sub-score (0=nominal, 1=critical) measuring how far the median deviates from quality thresholds                                                | perf, absolute score               |
| **Stability Score**           | The sub-score (0=stable, 1=unstable) measuring normalized IQR dispersion (IQR/median)                                                              | stab, variability, dispersion      |
| **IQR**                       | Interquartile Range (Q3 − Q1) — a robust dispersion estimator immune to outliers, preferred over standard deviation                                | spread, σ, CV                      |
| **Binary Search** (`bsearch`) | A O(log n) lookup on sorted timestamp arrays to find the first/last index within a Time Range                                                      | search, lookup, find               |

## Infrastructure

| Term        | Definition                                                                                                                      | Aliases to avoid                 |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| **Stack**   | The Docker Compose ensemble of services (Grafana, InfluxDB, Chronograf, Telegraf, Speedtest) running on the RPi                 | cluster, environment, deployment |
| **Sim**     | A local simulation of the RPi4 Stack using QEMU ARM64 emulation on x86, for testing without hardware                            | emulation, mock, local stack     |
| **Backup**  | A timestamped snapshot of InfluxDB data and Grafana dashboards, with automatic rotation (keep last N)                           | dump, export, archive            |
| **Preview** | A local HTTP server serving the Dashboard with either live GitHub Pages data (`preview-dev`) or local InfluxDB data (`preview`) | dev server, local server         |

## Code architecture

| Term                   | Definition                                                                                                                                                           | Aliases to avoid        |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------- |
| **lib.js**             | The pure-function ES module containing all algorithms (LTTB, Bucketize, Quality Score, Daily Status, stats, formatting) — zero DOM dependency, testable with Node.js | library, utils, helpers |
| **app.js**             | The thin orchestrator that loads data, initializes components, and wires callbacks (e.g., applyRange, highlightActiveDay) — the only entry point in the HTML         | main, index, controller |
| **State** (`state.js`) | The single mutable data store shared by all UI components, holding typed arrays and the current Time Range (including isToday flag)                                  | store, context, global  |
| **status-bar.js**      | Self-contained module rendering Status Bars, tooltips, click-to-navigate, and active day highlighting                                                                | uptime module           |
| **charts.js**          | Chart.js wrapper: creates/updates bandwidth and latency charts, manages render cycle with onRender hook                                                              | chart module, renderer  |

## Relationships

- A **Speedtest** run produces exactly one **Measurement** (one Download + one Upload + one Ping value)
- **Measurements** are stored in **InfluxDB** and read by both **Grafana** (real-time dashboards) and **Publish** (static page)
- **Publish** renders the **Dashboard** by injecting **Measurements** into the HTML template as `data.json`
- The **Dashboard** displays **Measurements** as either a **Line Chart** (≤ 48h) or a **Band Chart** (> 48h), controlled by the **Time Range**
- Each **Stat Card** contains a **Quality Dot**, a **Histogram**, and a **Decile Chart** for one metric
- The **Quality Score** is computed from **Performance Score** (30%) and **Stability Score** (70%)
- The **Stability Score** uses **IQR** rather than standard deviation to resist outliers
- **Alerts** are provisioned in **Grafana** and exported to the **Dashboard** as `alerts.json`
- The **Sim** replicates the full **Stack** locally for testing **Backup** restore and data integrity

## Example dialogue

> **Dev:** "When the **Time Range** is set to 7 days, do we show individual points?"

> **Domain expert:** "No — above 48 hours, the **Dashboard** switches from **Line Chart** to **Band Chart**. Each time bucket shows min, Q1, median, Q3, max so you see the distribution, not individual **Measurements**."

> **Dev:** "And the **Quality Dot** on a **Stat Card** — is it based on the latest **Measurement**?"

> **Domain expert:** "No, it reflects the entire active **Time Range**. The **Quality Score** combines **Performance Score** (is the median good enough?) with **Stability Score** (is the **IQR** tight?). So a green dot means: both good values AND consistent values over the window."

> **Dev:** "What if there's a single outlier — like one **Measurement** at 38 Mb/s among thousands at 940?"

> **Domain expert:** "That's exactly why **Stability Score** uses **IQR** instead of standard deviation. The **IQR** ignores the bottom and top 25%, so a single outlier doesn't move the needle. The CV approach would flag the whole period as unstable."

> **Dev:** "And the **Sync Status** dot in the nav — is that related to **Alerts**?"

> **Domain expert:** "No, those are independent. **Sync Status** tracks data freshness — how long since the last **Publish** pushed to GitHub Pages. **Alerts** come from **Grafana** threshold rules on **System Metrics** like CPU temperature or disk usage."

## Flagged ambiguities

- **"score"** is used loosely for three distinct values: the composite **Quality Score**, the **Performance Score** sub-component, and the **Stability Score** sub-component. Always qualify which score is meant.
- **"data point"** / **"point"** / **"sample"** / **"result"** all refer to a single **Measurement**. Use **Measurement** in domain discussions; "data point" is acceptable in chart/rendering context only.
- **"dashboard"** means both the static GitHub Pages **Dashboard** and the Grafana dashboards. Disambiguate: "**Dashboard**" (capitalized) = the public page; "Grafana dashboard" = the internal Grafana panels.
- **"deploy"** vs **"publish"**: "deploy" is used for docker `compose up` operations on the **Stack**; **Publish** specifically means the InfluxDB → GitHub Pages pipeline. Don't interchange them.
- **"preview"** has two modes: `preview` (queries local InfluxDB, requires RPi) and `preview-dev` (fetches live data from GitHub Pages, no RPi needed). Always specify which.
- **"bucket"** appears in two contexts: LTTB buckets (internal algorithm partitions) and **Bucketize** time buckets (visible Band Chart aggregation). Context usually disambiguates, but be explicit when discussing both.
- **"alert"** could mean a Grafana provisioned rule or the rendered HTML element on the Dashboard. In the domain, **Alert** is the Grafana rule; the HTML rendering is just the Alert's visualization.
