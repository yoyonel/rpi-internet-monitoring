// ── Shared mutable state for all UI components ──────────────
// Single source of truth: imported by charts, controls, picker.
// No DOM access. Pure data store.

import { HOUR } from './lib.js';

/** @type {{ ts: Float64Array, dl: Float64Array, ul: Float64Array, pi: Float64Array, LEN: number }} */
export const data = { ts: null, dl: null, ul: null, pi: null, LEN: 0 };

export const range = {
  start: 0,
  end: 0,
  currentH: 48,
  isLive: true,
  dataEnd: 0,
};

export const qualityData = {};

/** Timezone abbreviation resolved once at startup */
export const tzAbbr = new Date()
  .toLocaleTimeString('fr-FR', { timeZoneName: 'short' })
  .split(' ')
  .pop();

/** Initialize state from parsed InfluxDB data */
export const initData = (ts, dl, ul, pi) => {
  data.ts = ts;
  data.dl = dl;
  data.ul = ul;
  data.pi = pi;
  data.LEN = ts.length;
  range.dataEnd = ts[ts.length - 1];
  range.end = range.dataEnd + 600_000;
  range.start = range.end - range.currentH * HOUR;
};
