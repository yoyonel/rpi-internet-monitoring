# CLS Optimization — Post-mortem

> PR #10 `perf/lighthouse-round2` — April 2026

## Context

After merging PRs #8 (Lighthouse tooling) and #9 (quick wins), baseline scores were:

|               | Mobile | Desktop   |
| ------------- | ------ | --------- |
| Performance   | 80     | 80        |
| CLS           | 0.000  | **0.428** |
| Accessibility | 100    | 100       |

Desktop CLS of 0.428 is rated **"Poor"** (threshold: Good < 0.1, Needs Improvement < 0.25).

## Root cause analysis

### Identifying the culprit

Lighthouse JSON reports (`audits.layout-shifts.details.items`) pointed to:

```
selector: body > main.w > div.panel
nodeLabel: "Bandwidth\ndownload\nupload"
score: 0.428
```

The first `.panel` (Bandwidth chart) was being pushed down during page load.

### Measuring the shift

Using Playwright with `javaScriptEnabled: false` vs `true` at viewport 412×823 (Lighthouse mobile):

| Element               | Without JS              | With JS                  | Delta      |
| --------------------- | ----------------------- | ------------------------ | ---------- |
| `<canvas>` (Chart.js) | 150px (browser default) | 314px (aspect-ratio 2.8) | **+164px** |
| `.stats#statsRow`     | 0px (empty div)         | 243px (filled by JS)     | **+243px** |
| `.alerts#alertsSec`   | 0px (`display: none`)   | 324px (filled by JS)     | **+324px** |

Total: **~731px** of content injected dynamically above the chart panels, pushing them down.

### Why mobile CLS was initially 0

Lighthouse mobile throttles CPU 4× and network to slow 4G. The slower execution means layout shifts happen within the same animation frame, counted as a single shift with lower impact. Desktop executes JS faster, causing shifts across multiple frames.

## Fixes applied

### 1. Reserve canvas space with CSS `aspect-ratio`

Chart.js uses `maintainAspectRatio: true` with specific ratios in `baseOpts()`:

- Bandwidth chart: `aspectRatio: 2.8`
- Latency chart: `aspectRatio: 4`
- Mobile (`innerWidth < 600`): `aspectRatio: 1.5`

**Fix**: Mirror these ratios in CSS so canvases occupy the correct space before JS runs:

```css
.panel canvas {
  display: block;
  width: 100%;
}
#bwChart {
  aspect-ratio: 2.8;
}
#piChart {
  aspect-ratio: 4;
}

@media (max-width: 640px) {
  #bwChart,
  #piChart {
    aspect-ratio: 1.5;
  }
}
```

**Impact**: Desktop CLS 0.428 → 0.227, Performance 80 → 88.

### 2. Reserve stats row space with `min-height`

The `#statsRow` div starts empty and gets filled with 3 stat cards by JS. Heights measured with Playwright:

| Viewport                  | Stats height |
| ------------------------- | ------------ |
| 1350px (desktop)          | 230px        |
| 412px (Lighthouse mobile) | 243px        |
| ≤380px (single column)    | 446px        |

**Fix**: `min-height` at each breakpoint.

**Impact**: Desktop CLS 0.227 → 0.095, Performance 88 → 97.

### 3. Invert alerts visibility logic

The alerts section used `style="display: none"` in HTML, then JS showed it (`alertsSec.style.display = ''`). This caused a 255px shift when alerts content appeared.

**Fix**: Remove `display: none` from HTML, invert JS logic to **hide** the section if no alerts:

```js
// Before: show if alerts exist
if (!alertsArr.length) return;
alertsSec.style.display = '';

// After: hide if no alerts
if (!alertsArr.length) {
  alertsSec.style.display = 'none';
  return;
}
```

Combined with `min-height: 324px` on `.alerts` to prevent shift from content injection.

**Impact**: Desktop CLS 0.065 → 0.000, Mobile CLS 0.124 → 0.000.

## Results

|                    | Mobile (before) | Mobile (after) | Desktop (before) | Desktop (after) |
| ------------------ | --------------- | -------------- | ---------------- | --------------- |
| **Performance**    | 80              | **81**         | 80               | **99**          |
| **CLS**            | 0.000           | **0.000**      | 0.428            | **0.000**       |
| **Accessibility**  | 100             | 100            | 100              | 100             |
| **Best Practices** | 100             | 100            | 100              | 100             |
| **SEO**            | 100             | 100            | 100              | 100             |

## Files modified

- `gh-pages/style.css` — `aspect-ratio` on canvases, `min-height` on `.stats` and `.alerts`
- `gh-pages/index.template.html` — Remove `style="display: none"` from alerts section
- `gh-pages/app.js` — Invert alert visibility logic

## Methodology

Each fix was validated locally in isolation:

1. Edit CSS/HTML/JS
2. Restart preview server (`scripts/preview-dev.sh`)
3. Run `npx lighthouse --preset=desktop` + `--preset=perf`
4. Extract CLS from JSON report, compare with previous
5. Run 12 E2E tests to check for regressions
6. Iterate until CLS < 0.1

Key tool: Playwright with `javaScriptEnabled: false` to measure "before JS" dimensions and compare with "after JS" — this reveals exactly which elements shift and by how much.

## Tradeoffs

- **Hardcoded `min-height` values**: These depend on the current number of alerts (6) and stat card content. If the page evolves significantly, these values may need adjustment.
- **Alerts visible by default**: Users without JS briefly see an empty alerts section with just the title "Alertes RPi". This is acceptable since the page requires JS anyway (Chart.js).
- **`aspect-ratio` coupling**: CSS ratios must stay in sync with the `baseOpts()` values in `app.js`. A change to chart aspect ratios requires updating both files.
