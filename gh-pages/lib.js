// ── Pure computation functions for internet speed monitoring ──
// No DOM access. Testable with Node.js via `node --test`.

// ── Quality thresholds & weights ─────────────────────────────
// Performance thresholds: { good, bad } — below bad → score=1, above good → score=0
// For ping: inverted (lower is better)
export const QUALITY_THRESHOLDS = {
  dl: { good: 800, bad: 500 },
  ul: { good: 500, bad: 200 },
  pi: { good: 20, bad: 50 }, // inverted: low=good
};
export const PERF_WEIGHT = 0.3;
export const STAB_WEIGHT = 0.7;

// ── LTTB downsampling (Largest Triangle Three Buckets) ───────
// Typed array → [{x,y}]
export const lttb = (xArr, yArr, i0, i1, n) => {
  const len = i1 - i0;
  if (len <= n) {
    const out = new Array(len);
    for (let i = 0; i < len; i++) out[i] = { x: xArr[i0 + i], y: yArr[i0 + i] };
    return out;
  }
  const out = [{ x: xArr[i0], y: yArr[i0] }];
  const bs = (len - 2) / (n - 2);
  let a = 0;
  for (let i = 0; i < n - 2; i++) {
    const s = Math.floor((i + 1) * bs) + 1;
    const e = Math.min(Math.floor((i + 2) * bs) + 1, len);
    const ns = Math.min(Math.floor((i + 2) * bs) + 1, len - 1);
    const ne = Math.min(Math.floor((i + 3) * bs) + 1, len);
    let ax = 0,
      ay = 0,
      c = 0;
    for (let j = ns; j < ne; j++) {
      ax += xArr[i0 + j];
      ay += yArr[i0 + j];
      c++;
    }
    if (c) {
      ax /= c;
      ay /= c;
    }
    let ma = -1,
      bi = s;
    const px = xArr[i0 + a],
      py = yArr[i0 + a];
    for (let j = s; j < e; j++) {
      const ar = Math.abs((px - ax) * (yArr[i0 + j] - py) - (px - xArr[i0 + j]) * (ay - py));
      if (ar > ma) {
        ma = ar;
        bi = j;
      }
    }
    out.push({ x: xArr[i0 + bi], y: yArr[i0 + bi] });
    a = bi;
  }
  out.push({ x: xArr[i0 + len - 1], y: yArr[i0 + len - 1] });
  return out;
};

// ── Bucketize for band chart ─────────────────────────────────
// Returns array of { x, min, q1, med, q3, max, n }
export const bucketize = (xArr, yArr, i0, i1, bucketMs) => {
  const buckets = [];
  if (i0 >= i1) return buckets;
  const buf = [];
  let bStart = Math.floor(xArr[i0] / bucketMs) * bucketMs;

  const flush = () => {
    if (!buf.length) return;
    buf.sort((a, b) => a - b);
    const n = buf.length,
      mid = n >> 1;
    buckets.push({
      x: bStart + bucketMs / 2,
      min: buf[0],
      q1: buf[Math.floor(n * 0.25)],
      med: n & 1 ? buf[mid] : (buf[mid - 1] + buf[mid]) / 2,
      q3: buf[Math.ceil(n * 0.75) - 1] || buf[n - 1],
      max: buf[n - 1],
      n,
    });
    buf.length = 0;
  };

  for (let i = i0; i < i1; i++) {
    const bKey = Math.floor(xArr[i] / bucketMs) * bucketMs;
    if (bKey !== bStart) {
      flush();
      bStart = bKey;
    }
    buf.push(yArr[i]);
  }
  flush();
  return buckets;
};

// ── Stats helpers ────────────────────────────────────────────
export const sortedSlice = (arr, i0, i1) => {
  const tmp = new Float64Array(i1 - i0);
  for (let i = 0; i < tmp.length; i++) tmp[i] = arr[i0 + i];
  tmp.sort();
  return tmp;
};

export const medianOf = (s) => {
  const n = s.length,
    m = n >> 1;
  return n & 1 ? s[m] : (s[m - 1] + s[m]) / 2;
};

export const pctOf = (s, p) => {
  const idx = (p / 100) * (s.length - 1);
  const lo = Math.floor(idx),
    hi = Math.ceil(idx);
  return lo === hi ? s[lo] : s[lo] + (s[hi] - s[lo]) * (idx - lo);
};

// ── Histogram ────────────────────────────────────────────────
// Splits [min, max] into 10 equal-width bins, counts samples per bin.
export const computeHistogram = (sorted, min, max) => {
  const NBINS = 10;
  const range = max - min || 1;
  const binW = range / NBINS;
  const bins = Array.from({ length: NBINS }, (_, i) => ({
    lo: min + i * binW,
    hi: min + (i + 1) * binW,
    count: 0,
  }));
  for (const v of sorted) {
    let idx = Math.floor((v - min) / binW);
    if (idx >= NBINS) idx = NBINS - 1;
    if (idx < 0) idx = 0;
    bins[idx].count++;
  }
  return bins;
};

// ── Quality score (composite: performance + stability) ───────
export const qualityScore = (metric, median, sorted, avg, nPts) => {
  const th = QUALITY_THRESHOLDS[metric];
  // Performance score (0=nominal, 1=critical)
  let perf;
  if (metric === 'pi') {
    perf = median <= th.good ? 0 : median >= th.bad ? 1 : (median - th.good) / (th.bad - th.good);
  } else {
    perf = median >= th.good ? 0 : median <= th.bad ? 1 : (th.good - median) / (th.good - th.bad);
  }
  // Stability via IQR / median (robust to outliers)
  const q1 = pctOf(sorted, 25);
  const q3 = pctOf(sorted, 75);
  const iqr = q3 - q1;
  const iqrRatio = median > 0 ? iqr / median : 0;
  const IQR_GOOD = 0.05,
    IQR_BAD = 0.3;
  const stab =
    iqrRatio <= IQR_GOOD
      ? 0
      : iqrRatio >= IQR_BAD
        ? 1
        : (iqrRatio - IQR_GOOD) / (IQR_BAD - IQR_GOOD);
  // Composite
  const score = Math.min(1, Math.max(0, PERF_WEIGHT * perf + STAB_WEIGHT * stab));
  const hue = 120 * (1 - score);
  const lightness = 50 + 10 * Math.sin((hue / 120) * Math.PI);
  const color = `hsl(${hue.toFixed(0)}, 85%, ${lightness.toFixed(0)}%)`;
  return { score, perf, stab, q1, q3, iqr, iqrRatio, color, hue };
};

// ── Color utility ────────────────────────────────────────────
export const rgba = (hex, a) => {
  const [r, g, b] = hex
    .slice(1)
    .match(/.{2}/g)
    .map((x) => parseInt(x, 16));
  return `rgba(${r},${g},${b},${a})`;
};

// ── Binary search on sorted timestamp array ──────────────────
export const bsearch = (ts, len, target, first) => {
  let lo = 0,
    hi = len - 1,
    r = first ? len : -1;
  while (lo <= hi) {
    const m = (lo + hi) >> 1;
    if (first) {
      if (ts[m] >= target) {
        r = m;
        hi = m - 1;
      } else lo = m + 1;
    } else {
      if (ts[m] <= target) {
        r = m;
        lo = m + 1;
      } else hi = m - 1;
    }
  }
  return r;
};

// ── Filter range indices ─────────────────────────────────────
export const filterRange = (ts, len, s, e) => {
  const i0 = bsearch(ts, len, s, true),
    i1 = bsearch(ts, len, e, false);
  return i0 <= i1 && i0 < len ? [i0, i1 + 1] : null;
};

// ── Constants ────────────────────────────────────────────────
export const HOUR = 3_600_000;
export const BAND_THRESHOLD = 48; // hours: above this → band mode
export const PRESETS = [6, 12, 24, 48, 168, 720];
export const COL = { dl: '#7eb6f6', ul: '#c982e0', pi: '#f2a93b' };

// ── Formatters (pure, no DOM) ────────────────────────────────
export const pad2 = (n) => (n < 10 ? '0' + n : '' + n);

export const fmtDate = (t) => {
  const d = new Date(t);
  return `${pad2(d.getDate())}/${pad2(d.getMonth() + 1)} ${pad2(d.getHours())}:${pad2(
    d.getMinutes(),
  )}`;
};

export const fmtDateTz = (t, tzAbbr) => `${fmtDate(t)} ${tzAbbr}`;

export const fmtSpd = (v) =>
  v >= 1000
    ? `${(v / 1000).toFixed(1)}<span class="u">Gb/s</span>`
    : `${v.toFixed(0)}<span class="u">Mb/s</span>`;

export const fmtSpd0 = (v) => (v >= 1000 ? (v / 1000).toFixed(1) + ' G' : v.toFixed(0));

export const fmtPct = (v) => (v * 100).toFixed(0) + '%';

// ── Histogram SVG builder (pure string, no DOM) ──────────────
export const histogramSVG = (bins, avg, median, color, unit, nSamples) => {
  const W = 260,
    H = 76;
  const PAD_T = 10,
    PAD_B = 12,
    PAD_L = 2,
    PAD_R = 2;
  const plotH = H - PAD_T - PAD_B;
  const plotW = W - PAD_L - PAD_R;
  const BAR_GAP = 2;
  const barW = (plotW - BAR_GAP * (bins.length + 1)) / bins.length;
  const bot = PAD_T + plotH;

  const maxCount = Math.max(...bins.map((b) => b.count), 1);
  const toY = (count) => PAD_T + plotH * (1 - count / maxCount);

  const fmtVal = (v) => (unit === 'ms' ? v.toFixed(1) : v.toFixed(0));

  let s = `<svg class="dcl-svg" viewBox="0 0 ${W} ${H}">`;

  const range = bins[bins.length - 1].hi - bins[0].lo || 1;
  const valToX = (v) => PAD_L + BAR_GAP + ((v - bins[0].lo) / range) * (plotW - BAR_GAP * 2);

  bins.forEach((bin, i) => {
    const x = PAD_L + BAR_GAP + i * (barW + BAR_GAP);
    const barY = toY(bin.count);
    const barH = Math.max(bin.count > 0 ? 1 : 0, bot - barY);
    const pct = nSamples > 0 ? ((bin.count / nSamples) * 100).toFixed(0) : 0;
    const tipMain = `${bin.count} mesure${bin.count > 1 ? 's' : ''} (${pct}%)`;
    const tipSub = `${fmtVal(bin.lo)} \u2013 ${fmtVal(bin.hi)} ${unit}`;
    const HIT_PAD = 1;

    s += `<rect x="${(x - HIT_PAD).toFixed(1)}" y="${PAD_T}" width="${(barW + HIT_PAD * 2).toFixed(1)}" height="${plotH}" fill="transparent" class="dcl-hit" data-tip="${tipMain}" data-sub="${tipSub}"/>`;
    s += `<rect x="${x.toFixed(1)}" y="${barY.toFixed(1)}" width="${barW.toFixed(1)}" height="${barH.toFixed(1)}" rx="1.5" fill="${color}" class="dcl-bar${bin.count === maxCount ? ' dcl-p50' : ''}" pointer-events="none"/>`;
  });

  const avgX = valToX(avg);
  s += `<line x1="${avgX.toFixed(1)}" y1="${PAD_T}" x2="${avgX.toFixed(1)}" y2="${bot}" stroke="var(--bg)" stroke-width="3" opacity=".5"/>`;
  s += `<line x1="${avgX.toFixed(1)}" y1="${PAD_T}" x2="${avgX.toFixed(1)}" y2="${bot}" stroke="${color}" stroke-width="1.5" stroke-dasharray="4,3" opacity=".9"/>`;
  s += `<text x="${avgX.toFixed(1)}" y="${PAD_T - 1.5}" fill="${color}" font-size="7" text-anchor="middle" opacity=".9">avg</text>`;

  const medX = valToX(median);
  s += `<line x1="${medX.toFixed(1)}" y1="${PAD_T}" x2="${medX.toFixed(1)}" y2="${bot}" stroke="var(--bg)" stroke-width="3" opacity=".5"/>`;
  s += `<line x1="${medX.toFixed(1)}" y1="${PAD_T}" x2="${medX.toFixed(1)}" y2="${bot}" stroke="var(--text)" stroke-width="1.5" stroke-dasharray="2,2" opacity=".9"/>`;
  s += `<text x="${medX.toFixed(1)}" y="${PAD_T - 1.5}" fill="var(--text)" font-size="7" text-anchor="middle" font-weight="600">m\u00e9d</text>`;

  const fmtShort = (v) =>
    unit === 'ms' ? v.toFixed(0) : v >= 1000 ? (v / 1000).toFixed(1) + 'k' : v.toFixed(0);
  s += `<text x="${PAD_L + BAR_GAP}" y="${H - 1}" fill="var(--text3)" font-size="6" text-anchor="start">${fmtShort(bins[0].lo)}</text>`;
  const midBin = Math.floor(bins.length / 2);
  const midX = PAD_L + BAR_GAP + midBin * (barW + BAR_GAP) + barW / 2;
  s += `<text x="${midX.toFixed(1)}" y="${H - 1}" fill="var(--text3)" font-size="6" text-anchor="middle">${fmtShort(bins[midBin].lo)}</text>`;
  s += `<text x="${W - PAD_R - BAR_GAP}" y="${H - 1}" fill="var(--text3)" font-size="6" text-anchor="end">${fmtShort(bins[bins.length - 1].hi)}</text>`;

  s += '</svg>';
  return s;
};

// ── Quality tooltip HTML builder (pure string) ───────────────
export const qualityTooltipHtml = (metric, q, median, nPts, unit) => {
  const th = QUALITY_THRESHOLDS[metric];
  const thDir = metric === 'pi' ? '\u2264' : '\u2265';
  const thBad = metric === 'pi' ? '\u2265' : '\u2264';
  const label =
    q.score < 0.3
      ? 'Excellent'
      : q.score < 0.6
        ? 'Correct'
        : q.score < 0.8
          ? 'D\u00e9grad\u00e9'
          : 'Critique';
  return `<div class="q-tip-title">${label} <span style="color:${q.color}">(${fmtPct(1 - q.score)})</span></div>
<div class="q-tip-grid">
  <span class="q-tip-label">Performance</span><span class="q-tip-val">${fmtPct(1 - q.perf)}</span>
  <span class="q-tip-detail">m\u00e9diane ${median.toFixed(1)} ${unit} (vert ${thDir} ${th.good}, rouge ${thBad} ${th.bad})</span>
  <span class="q-tip-label">Stabilit\u00e9</span><span class="q-tip-val">${fmtPct(1 - q.stab)}</span>
  <span class="q-tip-detail">IQR/m\u00e9d = ${(q.iqrRatio * 100).toFixed(1)}% (Q1=${q.q1.toFixed(1)}, Q3=${q.q3.toFixed(1)}, IQR=${q.iqr.toFixed(1)} ${unit})</span>
  <span class="q-tip-detail">vert \u2264 5%, rouge \u2265 30%</span>
  <span class="q-tip-label">Pond\u00e9ration</span><span class="q-tip-val">${(PERF_WEIGHT * 100).toFixed(0)}/${(STAB_WEIGHT * 100).toFixed(0)}</span>
  <span class="q-tip-detail">perf \u00d7 ${PERF_WEIGHT} + stab \u00d7 ${STAB_WEIGHT}</span>
</div>`;
};

// ── Stat card HTML builder (pure string) ─────────────────────
export const statCard = (
  cls,
  label,
  mainVal,
  chartSVG,
  summary,
  lastVal,
  nPts,
  timeRange,
  qualityInfo,
) =>
  `<div class="stat ${cls}">
      <div class="v">${mainVal}${qualityInfo ? `<span class="q-dot" data-metric="${cls}" style="background:${qualityInfo.color};box-shadow:0 0 8px 2px ${qualityInfo.color}"></span>` : ''}</div>
      <div class="l">${label} <span class="l-sub">m\u00e9diane</span></div>
      <div class="dcl-wrap">${chartSVG}</div>
      <div class="stat-sum">${summary}</div>
      <div class="stat-last">LAST <strong>${lastVal}</strong></div>
      <div class="pts">${timeRange} \u00b7 ${nPts} pts</div>
    </div>`;

// ── Dataset factories (Chart.js config builders) ─────────────
export const DS_LINE = {
  tension: 0.15,
  pointRadius: 0,
  pointHitRadius: 6,
  pointHoverRadius: 3,
  borderWidth: 1.5,
};

export const makeBandDs = (buckets, color, label) => [
  {
    ...DS_LINE,
    data: buckets.map((b) => ({ x: b.x, y: b.q3 })),
    borderColor: 'transparent',
    borderWidth: 0,
    pointRadius: 0,
    backgroundColor: rgba(color, 0.15),
    fill: '+1',
    _isBand: true,
    tension: 0.3,
  },
  {
    ...DS_LINE,
    data: buckets.map((b) => ({ x: b.x, y: b.q1 })),
    borderColor: rgba(color, 0.3),
    borderWidth: 0.5,
    pointRadius: 0,
    fill: false,
    _isBand: true,
    tension: 0.3,
  },
  {
    ...DS_LINE,
    data: buckets.map((b) => ({ x: b.x, y: b.med })),
    borderColor: color,
    borderWidth: 2,
    pointRadius: 0,
    fill: false,
    label,
    tension: 0.3,
  },
  {
    ...DS_LINE,
    data: buckets.map((b) => ({ x: b.x, y: b.min })),
    borderColor: rgba(color, 0.12),
    borderWidth: 1,
    pointRadius: 0,
    borderDash: [2, 3],
    fill: false,
    _isBand: true,
    tension: 0.3,
  },
  {
    ...DS_LINE,
    data: buckets.map((b) => ({ x: b.x, y: b.max })),
    borderColor: rgba(color, 0.12),
    borderWidth: 1,
    pointRadius: 0,
    borderDash: [2, 3],
    fill: false,
    _isBand: true,
    tension: 0.3,
  },
];

export const makeLineDs = (xArr, yArr, i0, i1, color, label, gradient) => [
  {
    ...DS_LINE,
    label,
    data: lttb(xArr, yArr, i0, i1, 600),
    borderColor: color,
    backgroundColor: gradient,
    fill: true,
  },
];

// ── Daily status bars (GitHub-style uptime view) ─────────────
// Returns array of { date, dayStart, dayEnd, metrics: { dl, ul, pi }, overall }
// Each metric: { score, color, label, median, n } or null if no data
// overall: composite score across all 3 metrics
const DAY = 86_400_000;

const statusLabel = (score) =>
  score < 0.3 ? 'Excellent' : score < 0.6 ? 'Correct' : score < 0.8 ? 'Dégradé' : 'Critique';

const statusColor = (score) => {
  const hue = 120 * (1 - score);
  const lightness = 50 + 10 * Math.sin((hue / 120) * Math.PI);
  return `hsl(${hue.toFixed(0)}, 85%, ${lightness.toFixed(0)}%)`;
};

export const computeDailyStatus = (ts, dl, ul, pi, LEN, nDays = 30) => {
  if (!LEN || !ts) return [];

  // Find the end of the last day (midnight after last data point)
  const lastTs = ts[LEN - 1];
  const lastDate = new Date(lastTs);
  const endDay = new Date(
    lastDate.getFullYear(),
    lastDate.getMonth(),
    lastDate.getDate() + 1,
  ).getTime();

  const days = [];

  for (let d = 0; d < nDays; d++) {
    const dayEnd = endDay - d * DAY;
    const dayStart = dayEnd - DAY;
    const date = new Date(dayStart);
    const dateStr = `${pad2(date.getDate())}/${pad2(date.getMonth() + 1)}/${date.getFullYear()}`;

    const rng = filterRange(ts, LEN, dayStart, dayEnd - 1);

    if (!rng) {
      days.unshift({ date: dateStr, dayStart, dayEnd, metrics: null, overall: null });
      continue;
    }

    const [i0, i1] = rng;
    const n = i1 - i0;

    const computeMetric = (metric, arr) => {
      const sorted = sortedSlice(arr, i0, i1);
      const med = medianOf(sorted);
      let sum = 0;
      for (let i = i0; i < i1; i++) sum += arr[i];
      const avg = sum / n;
      const q = qualityScore(metric, med, sorted, avg, n);
      return {
        score: q.score,
        color: q.color,
        label: statusLabel(q.score),
        median: med,
        n,
        perf: q.perf,
        stab: q.stab,
        iqrRatio: q.iqrRatio,
        q1: q.q1,
        q3: q.q3,
      };
    };

    const mDl = computeMetric('dl', dl);
    const mUl = computeMetric('ul', ul);
    const mPi = computeMetric('pi', pi);

    // Overall = weighted average of the 3 scores
    const overallScore = (mDl.score + mUl.score + mPi.score) / 3;

    days.unshift({
      date: dateStr,
      dayStart,
      dayEnd,
      metrics: { dl: mDl, ul: mUl, pi: mPi },
      overall: {
        score: overallScore,
        color: statusColor(overallScore),
        label: statusLabel(overallScore),
      },
    });
  }

  return days;
};
