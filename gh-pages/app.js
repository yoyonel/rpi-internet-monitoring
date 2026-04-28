// ── App orchestrator ─────────────────────────────────────────
// Thin entry point: loads data, initializes components.
// All logic lives in dedicated modules.

import { HOUR } from './lib.js';
import { data, range, initData } from './state.js';
import { initSyncStatus } from './sync-status.js';
import { renderAlerts } from './alerts.js';
import { initCharts, render, initialRender, applyZoomPlugin, onRender } from './charts.js';
import { initTimeControls, applyRange } from './time-controls.js';
import { initTimePicker } from './time-picker.js';
import { initStatusBars, highlightActiveDay } from './status-bar.js';

// ── Sync status (no data dependency) ─────────────────────────
initSyncStatus();

// ── Data loading ─────────────────────────────────────────────
const _dataReady = Promise.all([
  fetch('data.json').then((r) => r.json()),
  fetch('alerts.json').then((r) => r.json()),
]);

// ── Alerts (independent of chart data) ───────────────────────
_dataReady.then(([, ALERTS]) => renderAlerts(ALERTS));

// ── Charts & controls (needs data) ──────────────────────────
_dataReady.then(async ([RAW_DATA]) => {
  const yieldToMain = () => new Promise((r) => setTimeout(r, 0));

  if (!RAW_DATA?.results?.[0]?.series?.[0]?.values?.length) {
    document.getElementById('statsRow').innerHTML =
      '<div class="no-data" style="grid-column:1/-1">Aucune donn\u00e9e disponible</div>';
    return;
  }

  // ── Parse InfluxDB response into typed arrays ──────────────
  const { columns: cols, values } = RAW_DATA.results[0].series[0];
  const iT = cols.indexOf('time'),
    iDl = cols.indexOf('download_bandwidth');
  const iUl = cols.indexOf('upload_bandwidth'),
    iPi = cols.indexOf('ping_latency');
  const LEN = values.length;

  const ts = new Float64Array(LEN);
  const dl = new Float64Array(LEN);
  const ul = new Float64Array(LEN);
  const pi = new Float64Array(LEN);

  for (let i = 0; i < LEN; i++) {
    const r = values[i];
    ts[i] = new Date(r[iT]).getTime();
    dl[i] = r[iDl] / 125000;
    ul[i] = r[iUl] / 125000;
    pi[i] = r[iPi];
  }

  initData(ts, dl, ul, pi);
  await yieldToMain();

  // ── Status bars (GitHub-style uptime) ──────────────────────
  initStatusBars(applyRange);
  onRender(highlightActiveDay);
  await yieldToMain();

  // ── Initialize components ──────────────────────────────────
  await initCharts(yieldToMain);
  await yieldToMain();

  initTimeControls();
  initTimePicker();
  await yieldToMain();

  // ── Initial render ─────────────────────────────────────────
  await initialRender(yieldToMain);
  await yieldToMain();

  // ── Lazy-load drag-to-zoom plugin ──────────────────────────
  const onZoomOrPan = ({ chart }) => {
    const { min, max } = chart.scales.x;
    range.start = min;
    range.end = max;
    range.currentH = (range.end - range.start) / HOUR;
    range.isLive = range.end >= range.dataEnd;
    range.isToday = false;
    render();
  };
  const zoomOpts = {
    zoom: {
      drag: {
        enabled: true,
        backgroundColor: 'rgba(127,127,127,0.15)',
        borderColor: 'rgba(127,127,127,0.4)',
        borderWidth: 1,
      },
      mode: 'x',
      onZoomComplete: onZoomOrPan,
    },
  };

  const loadZoom = () => {
    const s1 = document.createElement('script');
    s1.src = 'https://cdn.jsdelivr.net/npm/hammerjs@2';
    s1.onload = () => {
      const s2 = document.createElement('script');
      s2.src = 'https://cdn.jsdelivr.net/npm/chartjs-plugin-zoom@2';
      s2.onload = () => applyZoomPlugin(zoomOpts);
      document.head.appendChild(s2);
    };
    document.head.appendChild(s1);
  };
  if ('requestIdleCallback' in window) requestIdleCallback(loadZoom);
  else setTimeout(loadZoom, 100);
});
