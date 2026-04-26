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
