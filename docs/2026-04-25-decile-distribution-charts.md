# Decile Distribution Charts — Stats Cards

## Context

The stats cards (Download, Upload, Ping) previously displayed a purely textual
grid of MIN / AVG / MAX / LAST values. While informative, this format gave no
sense of _how the data is distributed_ — a key insight when monitoring internet
quality over time.

## Solution

Each stat card now includes an **inline SVG decile bar chart** that visualises
the distribution of values in the selected time range.

### What is shown

| Element             | Description                                                                                                            |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| **9 bars (D1–D9)**  | Percentile values P10 through P90. D5 (P50 = median) is highlighted with stronger opacity.                             |
| **min / max lines** | Dashed grey reference lines. When min/max fall outside the decile range, they are clamped to the edge with ▼/▲ arrows. |
| **avg line**        | Dashed coloured line showing the arithmetic mean.                                                                      |
| **Extra refs**      | Ping also displays P95 as an additional reference line.                                                                |
| **Summary text**    | Compact `min · avg · max` below the chart.                                                                             |
| **LAST value**      | Preserved as plain text — hard to represent graphically in a meaningful way.                                           |

### Interaction

- **Click** on a decile bar to inspect its value (tooltip + glow highlight).
- **Click again** (same bar or elsewhere) to dismiss.
- The Bandwidth/Latency Chart.js tooltips also use click instead of hover, with
  a dismiss-on-click-tooltip plugin.

### Y-axis scaling strategy

A naïve min→max scale compresses the chart when outliers exist (e.g. Download
min=38 Mb/s vs D4–D9 all at ~930–944 Mb/s). Instead, the Y-axis is scaled to
the **decile range (D1→D9)** with 18% padding. Min/max reference lines are
clamped to the visible area with arrow indicators when they overflow.

This ensures the distribution differences between deciles remain visually
distinguishable even with extreme outliers.

## Technical choices

- **Inline SVG** (not Canvas/Chart.js): zero external dependencies, ~1 KB per
  chart, no impact on Lighthouse performance scores.
- **CSS classes for bar styling** (`dcl-bar`, `dcl-p50`, `dcl-sel`): opacity and
  selection highlight are in CSS, not inline SVG attributes — easier to maintain
  and theme.
- **Transparent hit areas** (`dcl-hit`): wider than the visible bars for easier
  click targets, with `pointer-events: none` on the visible bar rects.
- **Delegated event listener**: a single `click` handler on `document` manages
  all 27 hit areas (9 bars × 3 metrics) efficiently.
- **Selection cleanup on re-render**: `dclClearSelection()` is called in
  `doRender()` so stale tooltip/highlight state is cleaned when the time range
  changes.

## Files modified

- `gh-pages/app.js` — `computeDeciles()`, `decileChartSVG()`, decile tooltip
  handler, `tooltipDismissPlugin`, updated `statCard()` builder, updated
  `baseOpts` to use `events: ['click']`.
- `gh-pages/style.css` — replaced `.sg` grid styles with `.dcl-*` chart styles,
  added `.dcl-tip` tooltip and `.dcl-sel` highlight.

## Lighthouse impact

| Metric              | Before | After |
| ------------------- | ------ | ----- |
| Desktop Performance | 100    | 100   |
| Mobile Performance  | ~71    | 71    |
| Accessibility       | 100    | 100   |
| Best Practices      | 100    | 100   |

The mobile performance score is unchanged — existing bottlenecks are Chart.js
bundle size and CDN cache lifetimes, not our SVG additions.
