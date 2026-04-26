import { describe, it } from 'node:test';
import { strict as assert } from 'node:assert';
import {
  lttb,
  bucketize,
  sortedSlice,
  medianOf,
  pctOf,
  computeHistogram,
  qualityScore,
  rgba,
  bsearch,
  filterRange,
  QUALITY_THRESHOLDS,
  PERF_WEIGHT,
  STAB_WEIGHT,
  HOUR,
  BAND_THRESHOLD,
  PRESETS,
  COL,
  pad2,
  fmtDate,
  fmtDateTz,
  fmtSpd,
  fmtSpd0,
  fmtPct,
  histogramSVG,
  qualityTooltipHtml,
  statCard,
  DS_LINE,
  makeBandDs,
  makeLineDs,
} from '../gh-pages/lib.js';

// ── Helpers ──────────────────────────────────────────────────
const f64 = (...vals) => new Float64Array(vals);

// ── medianOf ─────────────────────────────────────────────────
describe('medianOf', () => {
  it('returns middle value for odd-length array', () => {
    assert.equal(medianOf(f64(1, 2, 3)), 2);
  });
  it('returns average of two middle values for even-length array', () => {
    assert.equal(medianOf(f64(1, 2, 3, 4)), 2.5);
  });
  it('works with single element', () => {
    assert.equal(medianOf(f64(42)), 42);
  });
});

// ── pctOf ────────────────────────────────────────────────────
describe('pctOf', () => {
  it('returns min for p=0', () => {
    assert.equal(pctOf(f64(10, 20, 30, 40), 0), 10);
  });
  it('returns max for p=100', () => {
    assert.equal(pctOf(f64(10, 20, 30, 40), 100), 40);
  });
  it('interpolates for p=50 on even-length', () => {
    assert.equal(pctOf(f64(10, 20, 30, 40), 50), 25);
  });
  it('returns exact value for p=25 on 5 elements', () => {
    assert.equal(pctOf(f64(1, 2, 3, 4, 5), 25), 2);
  });
});

// ── sortedSlice ──────────────────────────────────────────────
describe('sortedSlice', () => {
  it('extracts and sorts a slice of a Float64Array', () => {
    const arr = f64(50, 10, 30, 20, 40);
    const sorted = sortedSlice(arr, 1, 4);
    assert.deepEqual([...sorted], [10, 20, 30]);
  });
  it('does not mutate the original array', () => {
    const arr = f64(3, 1, 2);
    sortedSlice(arr, 0, 3);
    assert.deepEqual([...arr], [3, 1, 2]);
  });
});

// ── computeHistogram ─────────────────────────────────────────
describe('computeHistogram', () => {
  it('produces 10 bins', () => {
    const sorted = f64(0, 1, 2, 3, 4, 5, 6, 7, 8, 9);
    const bins = computeHistogram(sorted, 0, 10);
    assert.equal(bins.length, 10);
  });
  it('total count equals input length', () => {
    const sorted = f64(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
    const bins = computeHistogram(sorted, 1, 10);
    const total = bins.reduce((s, b) => s + b.count, 0);
    assert.equal(total, 10);
  });
  it('max value goes in last bin', () => {
    const sorted = f64(0, 10);
    const bins = computeHistogram(sorted, 0, 10);
    assert.equal(bins[bins.length - 1].count >= 1, true);
  });
  it('handles zero range gracefully', () => {
    const sorted = f64(5, 5, 5);
    const bins = computeHistogram(sorted, 5, 5);
    assert.equal(bins.length, 10);
    const total = bins.reduce((s, b) => s + b.count, 0);
    assert.equal(total, 3);
  });
});

// ── lttb ─────────────────────────────────────────────────────
describe('lttb', () => {
  it('returns all points when n >= length', () => {
    const x = f64(1, 2, 3, 4, 5);
    const y = f64(10, 20, 30, 40, 50);
    const out = lttb(x, y, 0, 5, 10);
    assert.equal(out.length, 5);
    assert.deepEqual(out[0], { x: 1, y: 10 });
    assert.deepEqual(out[4], { x: 5, y: 50 });
  });
  it('downsamples to requested size', () => {
    const N = 1000;
    const x = new Float64Array(N);
    const y = new Float64Array(N);
    for (let i = 0; i < N; i++) {
      x[i] = i;
      y[i] = Math.sin(i / 50);
    }
    const out = lttb(x, y, 0, N, 100);
    assert.equal(out.length, 100);
  });
  it('preserves first and last points', () => {
    const N = 200;
    const x = new Float64Array(N);
    const y = new Float64Array(N);
    for (let i = 0; i < N; i++) {
      x[i] = i * 10;
      y[i] = i * 2;
    }
    const out = lttb(x, y, 0, N, 50);
    assert.deepEqual(out[0], { x: 0, y: 0 });
    assert.deepEqual(out[out.length - 1], { x: 1990, y: 398 });
  });
  it('respects i0/i1 subrange', () => {
    const x = f64(0, 1, 2, 3, 4, 5, 6, 7, 8, 9);
    const y = f64(0, 1, 2, 3, 4, 5, 6, 7, 8, 9);
    const out = lttb(x, y, 2, 7, 100);
    assert.equal(out.length, 5);
    assert.deepEqual(out[0], { x: 2, y: 2 });
    assert.deepEqual(out[4], { x: 6, y: 6 });
  });
});

// ── bucketize ────────────────────────────────────────────────
describe('bucketize', () => {
  it('returns empty for empty range', () => {
    const x = f64(1, 2, 3);
    const y = f64(10, 20, 30);
    assert.deepEqual(bucketize(x, y, 3, 3, 1000), []);
  });
  it('groups samples into time buckets', () => {
    // 6 samples, bucket size 1000ms, spanning 2 buckets
    const x = f64(100, 200, 300, 1100, 1200, 1300);
    const y = f64(10, 20, 30, 40, 50, 60);
    const buckets = bucketize(x, y, 0, 6, 1000);
    assert.equal(buckets.length, 2);
    assert.equal(buckets[0].n, 3);
    assert.equal(buckets[1].n, 3);
  });
  it('computes correct statistics per bucket', () => {
    const x = f64(0, 1, 2, 3, 4);
    const y = f64(10, 30, 20, 50, 40);
    const buckets = bucketize(x, y, 0, 5, 100);
    assert.equal(buckets.length, 1);
    const b = buckets[0];
    assert.equal(b.min, 10);
    assert.equal(b.max, 50);
    assert.equal(b.n, 5);
    assert.equal(b.med, 30); // sorted: 10,20,30,40,50 → median=30 (odd)
  });
});

// ── qualityScore ─────────────────────────────────────────────
describe('qualityScore', () => {
  it('returns score=0 (perfect) for high download and stable data', () => {
    // All values at 900 Mb/s — above good threshold (800), zero IQR
    const sorted = f64(900, 900, 900, 900, 900);
    const q = qualityScore('dl', 900, sorted, 900, 5);
    assert.equal(q.score, 0);
    assert.equal(q.perf, 0);
    assert.equal(q.stab, 0);
  });
  it('returns score=1 (critical) for low download and unstable data', () => {
    // Values: wildly spread below bad threshold (500)
    const sorted = f64(10, 100, 200, 400, 500);
    const q = qualityScore('dl', 200, sorted, 242, 5);
    assert.equal(q.score, 1);
  });
  it('handles ping (inverted: lower = better)', () => {
    // 10ms ping — well under good threshold (20ms)
    const sorted = f64(10, 10, 10, 10, 10);
    const q = qualityScore('pi', 10, sorted, 10, 5);
    assert.equal(q.perf, 0);
  });
  it('handles ping above bad threshold', () => {
    const sorted = f64(60, 60, 60, 60, 60);
    const q = qualityScore('pi', 60, sorted, 60, 5);
    assert.equal(q.perf, 1);
  });
  it('returns a valid HSL color string', () => {
    const sorted = f64(600, 650, 700, 750, 800);
    const q = qualityScore('dl', 700, sorted, 700, 5);
    assert.match(q.color, /^hsl\(\d+, 85%, \d+%\)$/);
  });
  it('handles zero median without division error', () => {
    const sorted = f64(0, 0, 0, 0, 0);
    const q = qualityScore('dl', 0, sorted, 0, 5);
    assert.equal(typeof q.score, 'number');
    assert.equal(isNaN(q.score), false);
  });
  it('exports correct threshold constants', () => {
    assert.deepEqual(QUALITY_THRESHOLDS.dl, { good: 800, bad: 500 });
    assert.equal(PERF_WEIGHT, 0.3);
    assert.equal(STAB_WEIGHT, 0.7);
  });
});

// ── rgba ─────────────────────────────────────────────────────
describe('rgba', () => {
  it('converts hex + alpha to rgba string', () => {
    assert.equal(rgba('#ff8800', 0.5), 'rgba(255,136,0,0.5)');
  });
  it('handles black', () => {
    assert.equal(rgba('#000000', 1), 'rgba(0,0,0,1)');
  });
  it('handles white', () => {
    assert.equal(rgba('#ffffff', 0), 'rgba(255,255,255,0)');
  });
});

// ── bsearch ──────────────────────────────────────────────────
describe('bsearch', () => {
  const ts = f64(100, 200, 300, 400, 500);
  it('finds first index >= target', () => {
    assert.equal(bsearch(ts, 5, 250, true), 2);
  });
  it('finds last index <= target', () => {
    assert.equal(bsearch(ts, 5, 250, false), 1);
  });
  it('returns exact match for first', () => {
    assert.equal(bsearch(ts, 5, 300, true), 2);
  });
  it('returns exact match for last', () => {
    assert.equal(bsearch(ts, 5, 300, false), 2);
  });
  it('returns len when target > all values (first=true)', () => {
    assert.equal(bsearch(ts, 5, 999, true), 5);
  });
  it('returns -1 when target < all values (first=false)', () => {
    assert.equal(bsearch(ts, 5, 50, false), -1);
  });
});

// ── filterRange ──────────────────────────────────────────────
describe('filterRange', () => {
  const ts = f64(100, 200, 300, 400, 500);
  it('returns [i0, i1+1] for valid range', () => {
    const r = filterRange(ts, 5, 150, 350);
    assert.deepEqual(r, [1, 3]);
  });
  it('returns null for empty range', () => {
    const r = filterRange(ts, 5, 600, 700);
    assert.equal(r, null);
  });
  it('includes boundary values', () => {
    const r = filterRange(ts, 5, 100, 500);
    assert.deepEqual(r, [0, 5]);
  });
});

// ── Constants ────────────────────────────────────────────────
describe('constants', () => {
  it('HOUR equals 3600000 ms', () => {
    assert.equal(HOUR, 3_600_000);
  });
  it('BAND_THRESHOLD is 48', () => {
    assert.equal(BAND_THRESHOLD, 48);
  });
  it('PRESETS contains expected values', () => {
    assert.deepEqual(PRESETS, [6, 12, 24, 48, 168, 720]);
  });
  it('COL has dl, ul, pi hex colors', () => {
    assert.ok(COL.dl.startsWith('#'));
    assert.ok(COL.ul.startsWith('#'));
    assert.ok(COL.pi.startsWith('#'));
  });
});

// ── Formatters ───────────────────────────────────────────────
describe('pad2', () => {
  it('pads single digit', () => {
    assert.equal(pad2(5), '05');
  });
  it('does not pad double digit', () => {
    assert.equal(pad2(12), '12');
  });
});

describe('fmtDate', () => {
  it('formats timestamp as dd/MM HH:mm', () => {
    // 2026-01-15T14:30:00Z
    const t = new Date(2026, 0, 15, 14, 30).getTime();
    assert.equal(fmtDate(t), '15/01 14:30');
  });
});

describe('fmtDateTz', () => {
  it('appends timezone abbreviation', () => {
    const t = new Date(2026, 0, 15, 14, 30).getTime();
    const result = fmtDateTz(t, 'CET');
    assert.ok(result.endsWith('CET'));
    assert.ok(result.startsWith('15/01 14:30'));
  });
});

describe('fmtSpd', () => {
  it('formats Mb/s with unit span', () => {
    assert.equal(fmtSpd(500), '500<span class="u">Mb/s</span>');
  });
  it('formats Gb/s for values >= 1000', () => {
    assert.equal(fmtSpd(1500), '1.5<span class="u">Gb/s</span>');
  });
});

describe('fmtSpd0', () => {
  it('formats plain Mb/s', () => {
    assert.equal(fmtSpd0(500), '500');
  });
  it('formats Gb/s with G suffix', () => {
    assert.equal(fmtSpd0(1500), '1.5 G');
  });
});

describe('fmtPct', () => {
  it('formats ratio as percentage', () => {
    assert.equal(fmtPct(0.85), '85%');
  });
  it('handles zero', () => {
    assert.equal(fmtPct(0), '0%');
  });
});

// ── histogramSVG ─────────────────────────────────────────────
describe('histogramSVG', () => {
  const bins = Array.from({ length: 10 }, (_, i) => ({
    lo: i * 10,
    hi: (i + 1) * 10,
    count: i + 1,
  }));

  it('returns an SVG string', () => {
    const svg = histogramSVG(bins, 50, 45, '#7eb6f6', 'Mb/s', 55);
    assert.ok(svg.startsWith('<svg'));
    assert.ok(svg.endsWith('</svg>'));
  });
  it('contains histogram bars', () => {
    const svg = histogramSVG(bins, 50, 45, '#7eb6f6', 'Mb/s', 55);
    assert.ok(svg.includes('dcl-bar'));
    assert.ok(svg.includes('dcl-hit'));
  });
  it('contains avg and med markers', () => {
    const svg = histogramSVG(bins, 50, 45, '#7eb6f6', 'Mb/s', 55);
    assert.ok(svg.includes('>avg</text>'));
    assert.ok(svg.includes('>m\u00e9d</text>'));
  });
});

// ── qualityTooltipHtml ───────────────────────────────────────
describe('qualityTooltipHtml', () => {
  const q = {
    score: 0.2,
    perf: 0.1,
    stab: 0.2,
    q1: 700,
    q3: 900,
    iqr: 200,
    iqrRatio: 0.25,
    color: 'hsl(96, 85%, 55%)',
    hue: 96,
  };

  it('returns HTML with quality label', () => {
    const html = qualityTooltipHtml('dl', q, 800, 100, 'Mb/s');
    assert.ok(html.includes('Excellent'));
  });
  it('contains performance and stability sections', () => {
    const html = qualityTooltipHtml('dl', q, 800, 100, 'Mb/s');
    assert.ok(html.includes('Performance'));
    assert.ok(html.includes('Stabilit\u00e9'));
  });
  it('shows Critique for high scores', () => {
    const qBad = { ...q, score: 0.9 };
    const html = qualityTooltipHtml('dl', qBad, 100, 10, 'Mb/s');
    assert.ok(html.includes('Critique'));
  });
});

// ── statCard ─────────────────────────────────────────────────
describe('statCard', () => {
  it('builds stat card HTML with quality dot', () => {
    const html = statCard(
      'dl',
      'Download',
      '800',
      '<svg/>',
      'min 700',
      '810',
      100,
      '15/01 → 16/01',
      { color: 'hsl(120,85%,50%)' },
    );
    assert.ok(html.includes('class="stat dl"'));
    assert.ok(html.includes('q-dot'));
    assert.ok(html.includes('data-metric="dl"'));
  });
  it('builds stat card without quality dot when null', () => {
    const html = statCard(
      'pi',
      'Ping',
      '12ms',
      '<svg/>',
      'min 10',
      '11',
      50,
      '15/01 → 16/01',
      null,
    );
    assert.ok(html.includes('class="stat pi"'));
    assert.ok(!html.includes('q-dot'));
  });
});

// ── DS_LINE ──────────────────────────────────────────────────
describe('DS_LINE', () => {
  it('has expected Chart.js line properties', () => {
    assert.equal(DS_LINE.pointRadius, 0);
    assert.equal(DS_LINE.borderWidth, 1.5);
    assert.ok(DS_LINE.tension > 0);
  });
});

// ── makeBandDs ───────────────────────────────────────────────
describe('makeBandDs', () => {
  const buckets = [
    { x: 1000, min: 10, q1: 20, med: 30, q3: 40, max: 50 },
    { x: 2000, min: 15, q1: 25, med: 35, q3: 45, max: 55 },
  ];

  it('returns 5 datasets (Q3, Q1, median, min whisker, max whisker)', () => {
    const ds = makeBandDs(buckets, '#7eb6f6', 'download');
    assert.equal(ds.length, 5);
  });
  it('median dataset has the label', () => {
    const ds = makeBandDs(buckets, '#7eb6f6', 'download');
    assert.equal(ds[2].label, 'download');
  });
  it('band datasets are flagged _isBand', () => {
    const ds = makeBandDs(buckets, '#7eb6f6', 'download');
    assert.ok(ds[0]._isBand);
    assert.ok(ds[1]._isBand);
    assert.ok(!ds[2]._isBand); // median is not _isBand
  });
});

// ── makeLineDs ───────────────────────────────────────────────
describe('makeLineDs', () => {
  const x = f64(100, 200, 300, 400, 500);
  const y = f64(10, 20, 30, 40, 50);

  it('returns array with one dataset', () => {
    const ds = makeLineDs(x, y, 0, 5, '#7eb6f6', 'download', 'gradient-placeholder');
    assert.equal(ds.length, 1);
  });
  it('dataset has label and fill', () => {
    const ds = makeLineDs(x, y, 0, 5, '#7eb6f6', 'download', 'grad');
    assert.equal(ds[0].label, 'download');
    assert.equal(ds[0].fill, true);
    assert.equal(ds[0].backgroundColor, 'grad');
  });
});
