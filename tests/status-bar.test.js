import { describe, it } from 'node:test';
import { strict as assert } from 'node:assert';
import { barColor, uptimePct, badgeInfo } from '../gh-pages/status-bar.js';

// ── barColor ─────────────────────────────────────────────────
describe('barColor', () => {
  it('returns green hue for score 0 (perfect)', () => {
    assert.equal(barColor(0), 'hsl(120, 40%, 28%)');
  });
  it('returns red hue for score 1 (critical)', () => {
    assert.equal(barColor(1), 'hsl(0, 40%, 28%)');
  });
  it('returns intermediate hue for score 0.5', () => {
    assert.equal(barColor(0.5), 'hsl(60, 40%, 28%)');
  });
});

// ── uptimePct ────────────────────────────────────────────────
describe('uptimePct', () => {
  const mkDay = (score) => ({ metrics: { dl: { score } } });

  it('returns -- for empty array', () => {
    assert.equal(uptimePct([], 'dl'), '--');
  });
  it('returns -- when all days have no metrics', () => {
    assert.equal(uptimePct([{ metrics: null }, { metrics: null }], 'dl'), '--');
  });
  it('returns 100.00 when all days are good (score < 0.6)', () => {
    const days = [mkDay(0.1), mkDay(0.2), mkDay(0.5)];
    assert.equal(uptimePct(days, 'dl'), '100.00');
  });
  it('returns 0.00 when all days are bad (score >= 0.6)', () => {
    const days = [mkDay(0.6), mkDay(0.8), mkDay(1.0)];
    assert.equal(uptimePct(days, 'dl'), '0.00');
  });
  it('computes correct percentage for mixed days', () => {
    // 7 bad + 23 good = 23/30 ≈ 76.67%
    const days = Array.from({ length: 7 }, () => mkDay(0.8)).concat(
      Array.from({ length: 23 }, () => mkDay(0.2)),
    );
    assert.equal(uptimePct(days, 'dl'), '76.67');
  });
  it('skips days without metrics', () => {
    const days = [mkDay(0.1), { metrics: null }, mkDay(0.1)];
    assert.equal(uptimePct(days, 'dl'), '100.00');
  });
});

// ── badgeInfo ────────────────────────────────────────────────
describe('badgeInfo', () => {
  it('returns none/empty for "--" (no data)', () => {
    const b = badgeInfo('--');
    assert.equal(b.cls, 'none');
    assert.equal(b.icon, '');
    assert.equal(b.level, '');
  });

  // Excellent: >= 90%
  it('returns ok/Excellent for 100%', () => {
    const b = badgeInfo('100.00');
    assert.equal(b.cls, 'ok');
    assert.equal(b.icon, '✓');
    assert.equal(b.level, 'Excellent');
  });
  it('returns ok/Excellent for 90% (boundary)', () => {
    const b = badgeInfo('90.00');
    assert.equal(b.cls, 'ok');
    assert.equal(b.level, 'Excellent');
  });
  it('returns ok/Excellent for 96.67% (Ping-like)', () => {
    const b = badgeInfo('96.67');
    assert.equal(b.cls, 'ok');
    assert.equal(b.level, 'Excellent');
  });

  // Correct: >= 70% and < 90%
  it('returns warn/Correct for 89.99% (just below Excellent)', () => {
    const b = badgeInfo('89.99');
    assert.equal(b.cls, 'warn');
    assert.equal(b.icon, '!');
    assert.equal(b.level, 'Correct');
  });
  it('returns warn/Correct for 73.33% (Download-like)', () => {
    const b = badgeInfo('73.33');
    assert.equal(b.cls, 'warn');
    assert.equal(b.level, 'Correct');
  });
  it('returns warn/Correct for 70% (boundary)', () => {
    const b = badgeInfo('70.00');
    assert.equal(b.cls, 'warn');
    assert.equal(b.level, 'Correct');
  });

  // Dégradé: < 70%
  it('returns bad/Dégradé for 69.99% (just below Correct)', () => {
    const b = badgeInfo('69.99');
    assert.equal(b.cls, 'bad');
    assert.equal(b.icon, '!');
    assert.equal(b.level, 'Dégradé');
  });
  it('returns bad/Dégradé for 43.33% (Upload-like)', () => {
    const b = badgeInfo('43.33');
    assert.equal(b.cls, 'bad');
    assert.equal(b.level, 'Dégradé');
  });
  it('returns bad/Dégradé for 0%', () => {
    const b = badgeInfo('0.00');
    assert.equal(b.cls, 'bad');
    assert.equal(b.level, 'Dégradé');
  });
});
