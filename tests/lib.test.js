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
