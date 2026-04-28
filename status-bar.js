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
const barColor = (score) => {
  const hue = 120 * (1 - score);
  return `hsl(${hue.toFixed(0)}, 40%, 28%)`;
};

/** Compute uptime percentage for a metric across all days with data */
const uptimePct = (days, metricKey) => {
  let good = 0,
    total = 0;
  for (const d of days) {
    if (!d.metrics) continue;
    total++;
    if (d.metrics[metricKey].score < 0.6) good++;
  }
  return total > 0 ? ((good / total) * 100).toFixed(2) : '--';
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

  const badgeClass =
    pct === '--' ? 'none' : Number(pct) >= 99 ? 'ok' : Number(pct) >= 95 ? 'warn' : 'bad';
  const badgeIcon = pct === '--' ? '' : Number(pct) >= 99 ? '✓' : '!';
  const badgeLevel =
    pct === '--'
      ? ''
      : Number(pct) >= 99
        ? 'Excellent'
        : Number(pct) >= 95
          ? 'Correct'
          : 'D\u00e9grad\u00e9';

  return `<div class="sb-row" data-metric="${metricKey}">
    <div class="sb-header">
      <span class="sb-name">${esc(label)}</span>
      <span class="sb-badge sb-badge-${badgeClass}" data-blabel="${esc(label)}" data-bpct="${pct}" data-blevel="${esc(badgeLevel)}">${badgeIcon}</span>
    </div>
    <div class="sb-bars">${barsHtml}</div>
    <div class="sb-footer">
      <span>${nDays} jours</span>
      <span>${pct} % qualité</span>
      <span>Auj.</span>
    </div>
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
  const iqr = bar.dataset.iqr;
  const q1 = bar.dataset.q1;
  const q3 = bar.dataset.q3;

  let html = `<strong>${date}</strong><br><span class="sb-tip-label" style="color:${bar.style.background}">${label}</span>`;
  if (median !== '--') {
    html += `<div class="sb-tip-grid">`;
    html += `<span class="sb-tip-k">Médiane</span><span class="sb-tip-v">${median}</span>`;
    html += `<span class="sb-tip-k">Performance</span><span class="sb-tip-v">${perf}%</span>`;
    html += `<span class="sb-tip-k">Stabilité</span><span class="sb-tip-v">${stab}%</span>`;
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
  <span class="sb-tip-k">Seuil \u2713</span><span class="sb-tip-v">\u2265 99%</span>
  <span class="sb-tip-k">Pond\u00e9ration</span><span class="sb-tip-v">perf 30% + stab 70%</span>
</div>
<span class="sb-tip-pts">Un jour est \u00ab OK \u00bb si son score < 0.6</span>`;
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

  container.innerHTML = ROWS.map((r) => buildRow(days, r.key, r.label)).join('');

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
