// ── Charts & rendering (Chart.js, stat cards, tooltips) ─────
// Owns: bwChart, piChart, doRender, flushCharts, render.
// Reads/writes shared state via state.js.

import {
  bucketize,
  sortedSlice,
  medianOf,
  pctOf,
  computeHistogram,
  qualityScore,
  filterRange,
  HOUR,
  BAND_THRESHOLD,
  COL,
  fmtDateTz,
  fmtSpd,
  fmtSpd0,
  histogramSVG,
  qualityTooltipHtml,
  statCard,
  makeBandDs,
  makeLineDs,
} from './lib.js';
import { data, range, qualityData, tzAbbr } from './state.js';

const fmtDateTzLocal = (t) => fmtDateTz(t, tzAbbr);

// ── Decile tooltip (click to show/hide, with bar highlight) ─
const dclTip = document.createElement('div');
dclTip.className = 'dcl-tip';
document.body.appendChild(dclTip);
let dclActiveHit = null;

const dclClearSelection = () => {
  if (dclActiveHit) {
    const bar = dclActiveHit.nextElementSibling;
    if (bar) bar.classList.remove('dcl-sel');
  }
  dclActiveHit = null;
  dclTip.style.display = 'none';
};

document.addEventListener('click', (e) => {
  const hit = e.target.closest?.('.dcl-hit');
  if (hit && hit !== dclActiveHit) {
    dclClearSelection();
    dclActiveHit = hit;
    const bar = hit.nextElementSibling;
    if (bar) bar.classList.add('dcl-sel');
    dclTip.innerHTML = `<strong>${hit.dataset.tip}</strong><br><span class="dcl-tip-sub">${hit.dataset.sub}</span>`;
    dclTip.style.display = 'block';
    const r = hit.getBoundingClientRect();
    dclTip.style.left = `${r.left + r.width / 2}px`;
    dclTip.style.top = `${r.top - 4}px`;
  } else {
    dclClearSelection();
  }
});

// ── Quality dot tooltip (click to show/hide) ────────────────
const qTip = document.createElement('div');
qTip.className = 'q-tip';
document.body.appendChild(qTip);
let qTipActive = null;

document.addEventListener('click', (e) => {
  const dot = e.target.closest?.('.q-dot');
  if (dot && dot !== qTipActive) {
    qTipActive = dot;
    const metric = dot.dataset.metric;
    const d = qualityData[metric];
    if (d) {
      qTip.innerHTML = qualityTooltipHtml(metric, d.q, d.median, d.n, d.unit);
      qTip.style.display = 'block';
      const r = dot.getBoundingClientRect();
      qTip.style.left = `${r.left + r.width / 2}px`;
      qTip.style.top = `${r.bottom + 8}px`;
    }
  } else if (!dot || dot === qTipActive) {
    qTipActive = null;
    qTip.style.display = 'none';
  }
});

// ── Gradient helper (needs Canvas context) ──────────────────
const mkGrad = (ctx, hex, h) => {
  const [r, g, b] = hex
    .slice(1)
    .match(/.{2}/g)
    .map((x) => parseInt(x, 16));
  const grad = ctx.createLinearGradient(0, 0, 0, h);
  grad.addColorStop(0, `rgba(${r},${g},${b},0.25)`);
  grad.addColorStop(1, `rgba(${r},${g},${b},0.01)`);
  return grad;
};

// ── Chart instances (created by initCharts) ─────────────────
let bwChart, piChart, bwCtx, piCtx, bwH, piH;
let renderRAF = 0,
  lastMode = '';

const mono = "'Geist Mono',monospace";

const tipStyle = {
  backgroundColor: '#141415',
  borderColor: '#2a2a2d',
  borderWidth: 1,
  titleFont: { family: mono, size: 11 },
  bodyFont: { family: mono, size: 11 },
  padding: 10,
  cornerRadius: 4,
};

const bandTooltipBw = {
  ...tipStyle,
  filter: (c) => !c.dataset._isBand,
  callbacks: {
    label: (c) => {
      if (c.dataset._isBand) return null;
      return `${c.dataset.label} med: ${c.parsed.y.toFixed(1)} Mb/s`;
    },
  },
};

const bandTooltipPi = {
  ...tipStyle,
  filter: (c) => !c.dataset._isBand,
  callbacks: {
    label: (c) => (c.dataset._isBand ? null : `med: ${c.parsed.y.toFixed(1)} ms`),
  },
};

/** Create Chart.js instances. Call once after data is loaded. */
export const initCharts = async (yieldToMain) => {
  // Wait for Chart.js global to be available (loaded via <script defer>)
  if (typeof Chart === 'undefined') {
    await new Promise((resolve) => {
      const check = () => (typeof Chart !== 'undefined' ? resolve() : setTimeout(check, 50));
      check();
    });
  }
  Chart.defaults.color = '#555';
  Chart.defaults.borderColor = '#2a2a2d';

  const scaleX = {
    type: 'time',
    time: {
      tooltipFormat: 'dd/MM HH:mm',
      displayFormats: { hour: 'HH:mm', day: 'dd/MM' },
    },
    grid: { color: '#1e2228' },
    ticks: { font: { family: mono, size: 10 }, maxTicksLimit: 12 },
    title: {
      display: true,
      text: `Heure (${tzAbbr})`,
      font: { family: mono, size: 10 },
      color: '#666',
      padding: { top: 2 },
    },
  };

  const baseOpts = (ar) => ({
    responsive: true,
    maintainAspectRatio: true,
    aspectRatio: innerWidth < 600 ? 1.5 : ar,
    animation: false,
    parsing: false,
    normalized: true,
    interaction: { mode: 'index', intersect: false },
    events: ['click'],
    scales: { x: { ...scaleX } },
    plugins: { legend: { display: false } },
  });

  // Plugin: click on visible tooltip dismisses it
  Chart.register({
    id: 'tooltipDismiss',
    beforeEvent(chart, args) {
      const evt = args.event;
      if (evt.type !== 'click') return;
      const tt = chart.tooltip;
      if (!tt || !tt.opacity) return;
      const { x, y, width, height } = tt;
      const pad = 6;
      if (
        evt.x >= x - pad &&
        evt.x <= x + width + pad &&
        evt.y >= y - pad &&
        evt.y <= y + height + pad
      ) {
        tt.setActiveElements([], { x: 0, y: 0 });
        chart.update('none');
        args.changed = true;
        return false;
      }
    },
  });

  bwCtx = document.getElementById('bwChart').getContext('2d');
  bwH = document.getElementById('bwChart').parentElement.clientHeight || 300;
  await yieldToMain();

  bwChart = new Chart(bwCtx, {
    type: 'line',
    data: { datasets: [] },
    options: {
      ...baseOpts(2.8),
      scales: {
        x: { ...scaleX },
        y: {
          beginAtZero: true,
          grid: { color: '#1e2228' },
          ticks: {
            font: { family: mono, size: 10 },
            callback: (v) => (v >= 1000 ? (v / 1000).toFixed(1) + ' Gb/s' : v + ' Mb/s'),
          },
        },
      },
      plugins: {
        legend: { display: false },
        tooltip: {
          ...tipStyle,
          callbacks: {
            label: (c) => {
              if (c.dataset._isBand) return null;
              return `${c.dataset.label}: ${c.parsed.y.toFixed(1)} Mb/s`;
            },
          },
          filter: (c) => c.dataset.label && !c.dataset._isBand,
        },
      },
    },
  });

  await yieldToMain();

  piCtx = document.getElementById('piChart').getContext('2d');
  piH = document.getElementById('piChart').parentElement.clientHeight || 200;
  piChart = new Chart(piCtx, {
    type: 'line',
    data: { datasets: [] },
    options: {
      ...baseOpts(4),
      scales: {
        x: { ...scaleX },
        y: {
          beginAtZero: true,
          grid: { color: '#1e2228' },
          ticks: {
            font: { family: mono, size: 10 },
            callback: (v) => v + ' ms',
          },
        },
      },
      plugins: {
        legend: { display: false },
        tooltip: {
          ...tipStyle,
          callbacks: {
            label: (c) => (c.dataset._isBand ? null : `${c.parsed.y.toFixed(1)} ms`),
          },
          filter: (c) => !c.dataset._isBand,
        },
      },
    },
  });
};

/** Bucket size based on current time range */
const bucketSize = () =>
  range.currentH <= 168 ? 2 * HOUR : range.currentH <= 720 ? 6 * HOUR : 24 * HOUR;

const statsEl = document.getElementById('statsRow');

const doRender = () => {
  dclClearSelection();

  const rng = filterRange(data.ts, data.LEN, range.start, range.end);
  const mode = range.currentH > BAND_THRESHOLD ? 'band' : 'line';

  if (!rng) {
    statsEl.innerHTML =
      '<div class="no-data" style="grid-column:1/-1">Aucune donn\u00e9e sur cette p\u00e9riode</div>';
    document.getElementById('bwLeg').innerHTML = '';
    document.getElementById('piLeg').innerHTML = '';
    bwChart.data.datasets = [];
    piChart.data.datasets = [];
  } else {
    const [i0, i1] = rng;
    const n = i1 - i0;
    const p0 = Math.max(0, i0 - 1);
    const p1 = Math.min(data.LEN, i1 + 1);

    // ── Stats ────────────────────────────────────────────────
    let dlS = 0,
      ulS = 0,
      piS = 0;
    let dlMx = -Infinity,
      dlMn = Infinity,
      ulMx = -Infinity,
      ulMn = Infinity;
    let piMn = Infinity,
      piMx = -Infinity;
    for (let i = i0; i < i1; i++) {
      const d = data.dl[i],
        u = data.ul[i],
        p = data.pi[i];
      dlS += d;
      ulS += u;
      piS += p;
      if (d > dlMx) dlMx = d;
      if (d < dlMn) dlMn = d;
      if (u > ulMx) ulMx = u;
      if (u < ulMn) ulMn = u;
      if (p > piMx) piMx = p;
      if (p < piMn) piMn = p;
    }
    const dlAvg = dlS / n,
      ulAvg = ulS / n,
      piAvg = piS / n;
    const dlSorted = sortedSlice(data.dl, i0, i1);
    const ulSorted = sortedSlice(data.ul, i0, i1);
    const piSorted = sortedSlice(data.pi, i0, i1);
    const dlMed = medianOf(dlSorted),
      ulMed = medianOf(ulSorted),
      piMed = medianOf(piSorted);

    const trLabel = `${fmtDateTzLocal(range.start)} \u2192 ${fmtDateTzLocal(range.end)}`;

    const dlHist = computeHistogram(dlSorted, dlMn, dlMx);
    const ulHist = computeHistogram(ulSorted, ulMn, ulMx);
    const piHist = computeHistogram(piSorted, piMn, piMx);

    const dlQ = qualityScore('dl', dlMed, dlSorted, dlAvg, n);
    const ulQ = qualityScore('ul', ulMed, ulSorted, ulAvg, n);
    const piQ = qualityScore('pi', piMed, piSorted, piAvg, n);

    // Store quality data for tooltip on click
    qualityData.dl = { q: dlQ, median: dlMed, n, unit: 'Mb/s' };
    qualityData.ul = { q: ulQ, median: ulMed, n, unit: 'Mb/s' };
    qualityData.pi = { q: piQ, median: piMed, n, unit: 'ms' };

    statsEl.innerHTML =
      statCard(
        'dl',
        'Download',
        fmtSpd(dlMed),
        histogramSVG(dlHist, dlAvg, dlMed, COL.dl, 'Mb/s', n),
        `min ${fmtSpd0(dlMn)} \u00b7 avg ${fmtSpd0(dlAvg)} \u00b7 max ${fmtSpd0(dlMx)}`,
        fmtSpd0(data.dl[i1 - 1]),
        n,
        trLabel,
        dlQ,
      ) +
      statCard(
        'ul',
        'Upload',
        fmtSpd(ulMed),
        histogramSVG(ulHist, ulAvg, ulMed, COL.ul, 'Mb/s', n),
        `min ${fmtSpd0(ulMn)} \u00b7 avg ${fmtSpd0(ulAvg)} \u00b7 max ${fmtSpd0(ulMx)}`,
        fmtSpd0(data.ul[i1 - 1]),
        n,
        trLabel,
        ulQ,
      ) +
      statCard(
        'pi',
        'Ping',
        `${piMed.toFixed(1)}<span class="u">ms</span>`,
        histogramSVG(piHist, piAvg, piMed, COL.pi, 'ms', n),
        `min ${piMn.toFixed(1)} \u00b7 avg ${piAvg.toFixed(1)} \u00b7 max ${piMx.toFixed(1)}`,
        data.pi[i1 - 1].toFixed(1),
        n,
        trLabel,
        piQ,
      );

    // ── Legend ────────────────────────────────────────────────
    const bandLabel =
      mode === 'band' ? ' <span style="color:var(--text3)">(m\u00e9diane + IQR)</span>' : '';
    document.getElementById('bwLeg').innerHTML = `
      <span><i style="background:${COL.dl}"></i>download${bandLabel}</span>
      <span><i style="background:${COL.ul}"></i>upload</span>`;
    document.getElementById('piLeg').innerHTML = `
      <span><i style="background:${COL.pi}"></i>latency${bandLabel}</span>`;

    // ── Datasets ─────────────────────────────────────────────
    if (mode === 'band') {
      const bMs = bucketSize();
      const dlB = bucketize(data.ts, data.dl, p0, p1, bMs);
      const ulB = bucketize(data.ts, data.ul, p0, p1, bMs);
      const piB = bucketize(data.ts, data.pi, p0, p1, bMs);

      bwChart.data.datasets = [
        ...makeBandDs(dlB, COL.dl, 'download'),
        ...makeBandDs(ulB, COL.ul, 'upload'),
      ];
      bwChart.options.plugins.tooltip = bandTooltipBw;
      piChart.data.datasets = makeBandDs(piB, COL.pi, 'latency');
      piChart.options.plugins.tooltip = bandTooltipPi;
    } else {
      bwChart.data.datasets = [
        ...makeLineDs(data.ts, data.dl, p0, p1, COL.dl, 'download', mkGrad(bwCtx, COL.dl, bwH)),
        ...makeLineDs(data.ts, data.ul, p0, p1, COL.ul, 'upload', mkGrad(bwCtx, COL.ul, bwH)),
      ];
      bwChart.options.plugins.tooltip = {
        ...tipStyle,
        callbacks: {
          label: (c) => `${c.dataset.label}: ${c.parsed.y.toFixed(1)} Mb/s`,
        },
      };
      piChart.data.datasets = makeLineDs(
        data.ts,
        data.pi,
        p0,
        p1,
        COL.pi,
        'latency',
        mkGrad(piCtx, COL.pi, piH),
      );
      piChart.options.plugins.tooltip = {
        ...tipStyle,
        callbacks: { label: (c) => `${c.parsed.y.toFixed(1)} ms` },
      };
    }
  }

  bwChart.options.scales.x.min = range.start;
  bwChart.options.scales.x.max = range.end;
  piChart.options.scales.x.min = range.start;
  piChart.options.scales.x.max = range.end;

  document.getElementById('rangeLabel').textContent = `${fmtDateTzLocal(
    range.start,
  )}  \u2192  ${fmtDateTzLocal(range.end)}`;
  document.querySelectorAll('.rb').forEach((b) => {
    if (b.id === 'btnToday') {
      b.classList.toggle('on', range.isToday);
    } else {
      b.classList.toggle('on', !range.isToday && parseInt(b.dataset.hours) === range.currentH);
    }
  });
  lastMode = mode;
};

const flushCharts = () => {
  bwChart.update('none');
  piChart.update('none');
};

/** Schedule a render on next animation frame (debounced). */
let renderHook = null;

/** Register a callback to run after each render. */
export const onRender = (fn) => {
  renderHook = fn;
};

export const render = () => {
  cancelAnimationFrame(renderRAF);
  renderRAF = requestAnimationFrame(() => {
    doRender();
    flushCharts();
    if (renderHook) renderHook();
  });
};

/** Run initial render with split updates to avoid long tasks. */
export const initialRender = async (yieldToMain) => {
  doRender();
  if (renderHook) renderHook();
  bwChart.update('none');
  await yieldToMain();
  piChart.update('none');
};

/** Apply zoom plugin options to both charts (called after lazy-load). */
export const applyZoomPlugin = (zoomOpts) => {
  bwChart.options.plugins.zoom = zoomOpts;
  bwChart.update('none');
  setTimeout(() => {
    piChart.options.plugins.zoom = zoomOpts;
    piChart.update('none');
  }, 0);
};
