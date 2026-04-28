// ── Status bars (GitHub-style uptime view) ──────────────────
// Self-contained: computes daily status from shared state, renders to #statusBars.
// Tooltip on hover shows day details.

import { computeDailyStatus } from './lib.js';
import { data, range } from './state.js';

const METRIC_LABELS = {
  dl: { name: 'Download', unit: 'Mb/s', format: (v) => v.toFixed(0) + ' Mb/s' },
  ul: { name: 'Upload', unit: 'Mb/s', format: (v) => v.toFixed(0) + ' Mb/s' },
  pi: { name: 'Ping', unit: 'ms', format: (v) => v.toFixed(1) + ' ms' },
};

const ROWS = [
  { key: 'dl', label: 'Download' },
  { key: 'ul', label: 'Upload' },
  { key: 'pi', label: 'Ping' },
];

/** Escape HTML */
const esc = (s) =>
  String(s).replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );

/** Muted color for status bars (subdued by default, like GitHub) */
export const barColor = (score) => {
  const hue = 120 * (1 - score);
  return `hsl(${hue.toFixed(0)}, 40%, 28%)`;
};

/** Compute uptime percentage for a metric across all days with data */
export const uptimePct = (days, metricKey) => {
  let good = 0,
    total = 0;
  for (const d of days) {
    if (!d.metrics) continue;
    total++;
    if (d.metrics[metricKey].score < 0.6) good++;
  }
  return total > 0 ? ((good / total) * 100).toFixed(2) : '--';
};

/** Compute badge class, icon and level from uptime percentage string */
export const badgeInfo = (pct) => {
  if (pct === '--') return { cls: 'none', icon: '', level: '' };
  const p = Number(pct);
  return {
    cls: p >= 90 ? 'ok' : p >= 70 ? 'warn' : 'bad',
    icon: p >= 90 ? '✓' : '!',
    level: p >= 90 ? 'Excellent' : p >= 70 ? 'Correct' : 'Dégradé',
  };
};

/** Badge severity rank: lower = worse */
const BADGE_RANK = { bad: 0, warn: 1, ok: 2, none: 3 };

/** Colors for favicon */
const FAVICON_COLORS = { ok: '#3fb950', warn: '#d29922', bad: '#f85149', none: '#555' };

/** Draw a speed gauge onto a canvas context.
 *  @param {CanvasRenderingContext2D} ctx
 *  @param {number} S — canvas size (square)
 *  @param {string} worstCls — 'ok' | 'warn' | 'bad' | 'none'
 *  @param {object} [opts] — { showDot, showBg } */
const drawGauge = (ctx, S, worstCls, opts = {}) => {
  const { showDot = false, showBg = false } = opts;
  const color = FAVICON_COLORS[worstCls] || FAVICON_COLORS.none;
  const fill = worstCls === 'ok' ? 1.0 : worstCls === 'warn' ? 0.65 : worstCls === 'bad' ? 0.3 : 0;
  const scale = S / 32; // scale factor relative to 32px reference

  ctx.clearRect(0, 0, S, S);

  // ── Optional dark rounded background (favicon only) ──
  if (showBg) {
    ctx.beginPath();
    ctx.roundRect(0, 0, S, S, 6 * scale);
    ctx.fillStyle = '#161b22';
    ctx.fill();
  }

  // ── Speed gauge arc (bottom half) ──
  const cx = S / 2,
    cy = S * 0.6;
  const radius = 10 * scale;
  // Background arc (dark grey)
  ctx.beginPath();
  ctx.arc(cx, cy, radius, Math.PI, 0);
  ctx.lineWidth = 3 * scale;
  ctx.strokeStyle = '#30363d';
  ctx.lineCap = 'butt';
  ctx.stroke();
  // Colored arc
  if (fill > 0) {
    ctx.beginPath();
    ctx.arc(cx, cy, radius, Math.PI, Math.PI + Math.PI * fill);
    ctx.lineWidth = 3 * scale;
    ctx.strokeStyle = color;
    ctx.lineCap = 'round';
    ctx.stroke();
  }

  // ── Needle ──
  const angle = Math.PI + Math.PI * fill;
  const nLen = 6 * scale;
  ctx.beginPath();
  ctx.moveTo(cx, cy);
  ctx.lineTo(cx + Math.cos(angle) * nLen, cy + Math.sin(angle) * nLen);
  ctx.lineWidth = 2 * scale;
  ctx.strokeStyle = '#e6edf3';
  ctx.lineCap = 'round';
  ctx.stroke();
  // Center dot
  ctx.beginPath();
  ctx.arc(cx, cy, 2 * scale, 0, 2 * Math.PI);
  ctx.fillStyle = '#e6edf3';
  ctx.fill();

  // ── Optional status dot (top-right) ──
  if (showDot) {
    ctx.beginPath();
    ctx.arc(S - 6 * scale, 6 * scale, 4 * scale, 0, 2 * Math.PI);
    ctx.fillStyle = color;
    ctx.fill();
    ctx.lineWidth = 1.5 * scale;
    ctx.strokeStyle = '#161b22';
    ctx.stroke();
  }
};

/** Generate favicon and update <link rel="icon"> */
const updateFavicon = (worstCls) => {
  const S = 32;
  const c = document.createElement('canvas');
  c.width = S;
  c.height = S;
  drawGauge(c.getContext('2d'), S, worstCls, { showDot: true, showBg: true });
  let link = document.querySelector('link[rel="icon"]');
  if (!link) {
    link = document.createElement('link');
    link.rel = 'icon';
    document.head.appendChild(link);
  }
  link.href = c.toDataURL('image/png');
};

/** Draw the gauge into the nav brand area */
const updateNavGauge = (worstCls) => {
  const brand = document.querySelector('nav .brand');
  if (!brand) return;
  let canvas = brand.querySelector('.brand-gauge');
  if (!canvas) {
    canvas = document.createElement('canvas');
    canvas.className = 'brand-gauge';
    canvas.width = 64;
    canvas.height = 64;
    brand.prepend(canvas);
  }
  const dpr = window.devicePixelRatio || 1;
  const displaySize = 28;
  canvas.width = displaySize * dpr;
  canvas.height = displaySize * dpr;
  canvas.style.width = displaySize + 'px';
  canvas.style.height = displaySize + 'px';
  const ctx = canvas.getContext('2d');
  ctx.scale(dpr, dpr);
  drawGauge(ctx, displaySize, worstCls);
};

/** Build one status bar row */
const buildRow = (days, metricKey, label) => {
  const pct = uptimePct(days, metricKey);
  const nDays = days.length;

  let barsHtml = '';
  for (let i = 0; i < days.length; i++) {
    const d = days[i];
    const m = d.metrics?.[metricKey];
    const color = m ? barColor(m.score) : 'var(--border)';
    const tipDate = esc(d.date);
    const tipLabel = m ? esc(m.label) : 'Aucune donnée';
    const tipMedian = m ? esc(METRIC_LABELS[metricKey].format(m.median)) : '--';
    const tipPts = m ? m.n + ' mesures' : '';

    const tipPerf = m ? (100 * (1 - m.perf)).toFixed(0) : '';
    const tipStab = m ? (100 * (1 - m.stab)).toFixed(0) : '';
    const tipIqr = m ? (m.iqrRatio * 100).toFixed(1) : '';
    const tipQ1 = m ? METRIC_LABELS[metricKey].format(m.q1) : '';
    const tipQ3 = m ? METRIC_LABELS[metricKey].format(m.q3) : '';

    barsHtml += `<div class="sb-bar" style="background:${color}" data-date="${tipDate}" data-label="${tipLabel}" data-median="${tipMedian}" data-pts="${tipPts}" data-score="${m ? m.score.toFixed(2) : ''}" data-perf="${tipPerf}" data-stab="${tipStab}" data-iqr="${tipIqr}" data-q1="${tipQ1}" data-q3="${tipQ3}" data-start="${d.dayStart}" data-end="${d.dayEnd}"></div>`;
  }

  const p = Number(pct);
  const badge = badgeInfo(pct);

  return `<div class="sb-row" data-metric="${metricKey}">
    <div class="sb-header">
      <span class="sb-name">${esc(label)}</span>
      <span class="sb-header-right">
        <span class="sb-pct">${pct}%</span>
        <span class="sb-badge sb-badge-${badge.cls}" data-blabel="${esc(label)}" data-bpct="${pct}" data-blevel="${esc(badge.level)}">${badge.icon}</span>
      </span>
    </div>
    <div class="sb-bars">${barsHtml}</div>
  </div>`;
};

/** Tooltip element (shared, repositioned on hover) */
let tipEl = null;

const ensureTip = () => {
  if (tipEl) return;
  tipEl = document.createElement('div');
  tipEl.className = 'sb-tip';
  document.body.appendChild(tipEl);
};

const showTip = (bar) => {
  ensureTip();
  const date = bar.dataset.date;
  const label = bar.dataset.label;
  const median = bar.dataset.median;
  const pts = bar.dataset.pts;

  const perf = bar.dataset.perf;
  const stab = bar.dataset.stab;
  const score = bar.dataset.score;
  const iqr = bar.dataset.iqr;
  const q1 = bar.dataset.q1;
  const q3 = bar.dataset.q3;

  let html = `<strong>${date}</strong><br><span class="sb-tip-label" style="color:${bar.style.background}">${label}</span>`;
  if (median !== '--') {
    const qualPct = score !== '' ? (100 - parseFloat(score) * 100).toFixed(0) : '--';
    html += `<div class="sb-tip-grid">`;
    html += `<span class="sb-tip-k">Médiane</span><span class="sb-tip-v">${median}</span>`;
    html += `<span class="sb-tip-k">Qualité</span><span class="sb-tip-v">${qualPct}% <span class="sb-tip-dim">(perf ${perf} + stab ${stab})</span></span>`;
    html += `<span class="sb-tip-k">IQR/méd</span><span class="sb-tip-v">${iqr}% <span class="sb-tip-dim">(${q1} → ${q3})</span></span>`;
    html += `</div>`;
  }
  if (pts) html += `<span class="sb-tip-pts">${pts}</span>`;

  tipEl.innerHTML = html;
  tipEl.className = 'sb-tip sb-tip-above';
  tipEl.style.display = 'block';

  const r = bar.getBoundingClientRect();
  tipEl.style.left = `${r.left + r.width / 2}px`;
  tipEl.style.top = `${r.top - 6}px`;
};

const showBadgeTip = (badge) => {
  ensureTip();
  const label = badge.dataset.blabel;
  const pct = badge.dataset.bpct;
  const level = badge.dataset.blevel;

  if (!level) return;

  tipEl.innerHTML = `<strong>Qualit\u00e9 ${label}</strong><br><span class="sb-tip-label">${level}</span>
<div class="sb-tip-grid">
  <span class="sb-tip-k">Jours OK</span><span class="sb-tip-v">${pct}%</span>
  <span class="sb-tip-k">Seuil \u2713</span><span class="sb-tip-v">\u2265 90%</span>
</div>
<span class="sb-tip-pts">Qualit\u00e9 = perf 30% + stab 70%. Jour \u00ab OK \u00bb si qualit\u00e9 \u2265 40%</span>`;
  tipEl.className = 'sb-tip sb-tip-below';
  tipEl.style.display = 'block';

  const r = badge.getBoundingClientRect();
  tipEl.style.left = `${r.left + r.width / 2}px`;
  tipEl.style.top = `${r.bottom + 6}px`;
};

const hideTip = () => {
  if (tipEl) tipEl.style.display = 'none';
};

/** Initialize status bars. Call after data is loaded.
 *  @param {function} [onBarClick] — called with (start, end) when a bar is clicked */
export const initStatusBars = (onBarClick) => {
  const container = document.getElementById('statusBars');
  if (!container || !data.ts) return;

  const days = computeDailyStatus(data.ts, data.dl, data.ul, data.pi, data.LEN, 30);

  if (!days.length) {
    container.style.display = 'none';
    return;
  }

  const nDays = days.length;
  container.innerHTML =
    ROWS.map((r) => buildRow(days, r.key, r.label)).join('') +
    `<div class="sb-footer">
      <span>${nDays} jours</span>
      <span>Auj.</span>
    </div>`;

  // Dynamic favicon: colored dot reflecting today's worst metric
  const today = days[days.length - 1];
  let todayCls = 'none';
  if (today?.metrics) {
    const scores = ROWS.map((r) => today.metrics[r.key]?.score ?? 1);
    const worst = Math.max(...scores);
    // Map score to badge class: <0.3 ok, <0.6 warn, else bad
    todayCls = worst < 0.3 ? 'ok' : worst < 0.6 ? 'warn' : 'bad';
  }
  updateFavicon(todayCls);
  updateNavGauge(todayCls);

  // Event delegation for bar tooltip
  container.addEventListener(
    'mouseenter',
    (e) => {
      const bar = e.target.closest?.('.sb-bar');
      if (bar) {
        showTip(bar);
        return;
      }
      const badge = e.target.closest?.('.sb-badge');
      if (badge) showBadgeTip(badge);
    },
    true,
  );

  container.addEventListener(
    'mouseleave',
    (e) => {
      const bar = e.target.closest?.('.sb-bar');
      const badge = e.target.closest?.('.sb-badge');
      if (bar || badge) hideTip();
    },
    true,
  );

  // Click on bar → navigate to that day's time range
  container.addEventListener('click', (e) => {
    const bar = e.target.closest?.('.sb-bar');
    if (bar && bar.dataset.start && onBarClick) {
      onBarClick(Number(bar.dataset.start), Number(bar.dataset.end));
      hideTip();
      return;
    }
    const badge = e.target.closest?.('.sb-badge');
    if (badge) {
      showBadgeTip(badge);
      setTimeout(hideTip, 4000);
    }
  });
};

/** Highlight bars overlapping the current time range. Call after each render. */
export const highlightActiveDay = () => {
  const bars = document.querySelectorAll('.sb-bar');
  for (const bar of bars) {
    const s = Number(bar.dataset.start);
    const e = Number(bar.dataset.end);
    // Overlap: bar intersects [range.start, range.end]
    bar.classList.toggle('sb-active', s < range.end && e > range.start);
  }
};
