// ── Time range controls (nav buttons, keyboard, middle-click pan) ──
// Mutates range state, calls render() after each change.

import { HOUR, PRESETS } from './lib.js';
import { range, data } from './state.js';
import { render } from './charts.js';

/** Set range to "today": midnight local → now */
const setToday = () => {
  const now = new Date();
  range.start = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  range.end = range.dataEnd + 600_000;
  range.currentH = (range.end - range.start) / HOUR;
  range.isLive = true;
  range.isToday = true;
  render();
};

const setRange = (h) => {
  range.currentH = h;
  if (range.isLive) range.end = range.dataEnd + 600_000;
  range.start = range.end - range.currentH * HOUR;
  range.isToday = false;
  render();
};

const shift = (dir) => {
  const s = range.currentH * HOUR * 0.5 * dir;
  range.start += s;
  range.end += s;
  range.isLive = range.end >= range.dataEnd;
  range.isToday = false;
  render();
};

/** Reset to default live "today" view */
export const resetToLive = () => {
  setToday();
};

/** Apply an arbitrary absolute range (used by time-picker). */
export const applyRange = (start, end) => {
  range.start = start;
  range.end = end;
  range.currentH = (range.end - range.start) / HOUR;
  range.isLive = range.end >= range.dataEnd;
  range.isToday = false;
  render();
};

/** Bind all time control DOM elements. Call once at init. */
export const initTimeControls = () => {
  // Today button
  document.getElementById('btnToday').addEventListener('click', setToday);

  // Preset buttons (e.g. 24h, 48h, 7d …)
  document.querySelectorAll('.rb:not(#btnToday)').forEach((b) =>
    b.addEventListener('click', () => {
      range.isLive = true;
      range.isToday = false;
      setRange(parseInt(b.dataset.hours));
    }),
  );

  // Back / Forward
  document.getElementById('btnBack').addEventListener('click', () => shift(-1));
  document.getElementById('btnFwd').addEventListener('click', () => shift(1));

  // Zoom In / Out (snap to preset steps)
  document.getElementById('btnZoomIn').addEventListener('click', () => {
    const i = PRESETS.indexOf(range.currentH);
    if (i > 0) setRange(PRESETS[i - 1]);
    else if (range.currentH > PRESETS[0]) setRange(PRESETS[0]);
  });
  document.getElementById('btnZoomOut').addEventListener('click', () => {
    const i = PRESETS.indexOf(range.currentH);
    if (i >= 0 && i < PRESETS.length - 1) setRange(PRESETS[i + 1]);
    else if (i < 0) {
      for (const p of PRESETS) {
        if (p > range.currentH) {
          setRange(p);
          break;
        }
      }
    }
  });

  // Keyboard shortcuts
  document.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowLeft') shift(-1);
    else if (e.key === 'ArrowRight') shift(1);
    else if (e.key === '+' || e.key === '=') document.getElementById('btnZoomIn').click();
    else if (e.key === '-') document.getElementById('btnZoomOut').click();
  });

  // Double-click on chart → reset to live 48h
  document.getElementById('bwChart').addEventListener('dblclick', resetToLive);
  document.getElementById('piChart').addEventListener('dblclick', resetToLive);

  // ── Middle-click drag to pan ───────────────────────────────
  ['bwChart', 'piChart'].forEach((id) => {
    const canvas = document.getElementById(id);
    let panning = false,
      startX = 0,
      startRange = 0;
    canvas.addEventListener('mousedown', (e) => {
      if (e.button !== 1) return;
      e.preventDefault();
      panning = true;
      startX = e.clientX;
      startRange = range.start;
      canvas.style.cursor = 'grabbing';
    });
    window.addEventListener('mousemove', (e) => {
      if (!panning) return;
      const chart = Chart.getChart(id);
      const xScale = chart.scales.x;
      const pxRange = xScale.right - xScale.left;
      const msPerPx = (range.end - range.start) / pxRange;
      const dx = startX - e.clientX;
      const ms = dx * msPerPx;
      range.start = startRange + ms;
      range.end = range.start + range.currentH * HOUR;
      range.isLive = range.end >= range.dataEnd;
      render();
    });
    const stopPan = () => {
      if (!panning) return;
      panning = false;
      canvas.style.cursor = 'crosshair';
    };
    window.addEventListener('mouseup', (e) => {
      if (e.button === 1) stopPan();
    });
    canvas.addEventListener('auxclick', (e) => {
      if (e.button === 1) e.preventDefault();
    });
  });
};
