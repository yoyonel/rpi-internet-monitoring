// ── Grafana-style time range picker (calendar + relative presets) ──
// Self-contained UI component. Mutates range via time-controls.applyRange().

import { HOUR, fmtDate, fmtDateTz } from './lib.js';
import { range, data, tzAbbr } from './state.js';
import { render } from './charts.js';
import { applyRange } from './time-controls.js';

const fmtDateTzLocal = (t) => fmtDateTz(t, tzAbbr);

/** Initialize the time picker. Call once after data is loaded. */
export const initTimePicker = () => {
  const picker = document.getElementById('trPicker');
  const btn = document.getElementById('rangeLabelBtn');
  const calEl = document.getElementById('trCal');
  const fromIn = document.getElementById('trFrom');
  const toIn = document.getElementById('trTo');
  const recentSec = document.getElementById('trRecentSec');
  const recentEl = document.getElementById('trRecent');
  const relEl = document.getElementById('trRel');

  let pickerOpen = false;
  let calYear, calMonth;
  let selFrom = null,
    selTo = null;
  const dataStart = data.ts[0];

  // Relative presets (label, hours)
  const relPresets = [
    ['5 min', 5 / 60],
    ['15 min', 0.25],
    ['30 min', 0.5],
    ['1 heure', 1],
    ['3 heures', 3],
    ['6 heures', 6],
    ['12 heures', 12],
    ['24 heures', 24],
    ['2 jours', 48],
    ['7 jours', 168],
    ['30 jours', 720],
  ];

  // Recent ranges (stored in memory, max 5)
  let recentRanges = [];
  const addRecent = (s, e) => {
    const key = `${s}|${e}`;
    recentRanges = recentRanges.filter((r) => `${r[0]}|${r[1]}` !== key);
    recentRanges.unshift([s, e]);
    if (recentRanges.length > 5) recentRanges.length = 5;
    renderRecent();
  };

  // ── Toggle ──
  const togglePicker = () => {
    pickerOpen = !pickerOpen;
    picker.style.display = pickerOpen ? '' : 'none';
    btn.classList.toggle('open', pickerOpen);
    if (pickerOpen) syncPickerToRange();
  };
  btn.addEventListener('click', togglePicker);

  // Close on outside click
  document.addEventListener('click', (e) => {
    if (pickerOpen && !picker.contains(e.target) && !btn.contains(e.target)) {
      pickerOpen = false;
      picker.style.display = 'none';
      btn.classList.remove('open');
    }
  });

  // ── Sync picker inputs to current range ──
  const toLocalISO = (t) => {
    const d = new Date(t);
    const off = d.getTimezoneOffset();
    const local = new Date(d.getTime() - off * 60000);
    return local.toISOString().slice(0, 16);
  };
  const syncPickerToRange = () => {
    selFrom = range.start;
    selTo = range.end;
    fromIn.value = toLocalISO(range.start);
    toIn.value = toLocalISO(range.end);
    const d = new Date(range.start);
    calYear = d.getFullYear();
    calMonth = d.getMonth();
    renderCal();
    renderRelActive();
  };

  // ── Apply absolute range ──
  const applyAbsolute = () => {
    const s = new Date(fromIn.value).getTime();
    const e = new Date(toIn.value).getTime();
    if (!s || !e || s >= e) return;
    addRecent(s, e);
    applyRange(s, e);
    togglePicker();
  };
  document.getElementById('trApply').addEventListener('click', applyAbsolute);

  // Sync calendar highlight when inputs change manually
  fromIn.addEventListener('change', () => {
    const t = new Date(fromIn.value).getTime();
    if (t) selFrom = t;
    if (toIn.value) selTo = new Date(toIn.value).getTime();
    renderCal();
  });
  toIn.addEventListener('change', () => {
    if (fromIn.value) selFrom = new Date(fromIn.value).getTime();
    const t = new Date(toIn.value).getTime();
    if (t) selTo = t;
    renderCal();
  });

  // ── Relative presets ──
  relPresets.forEach(([label, h]) => {
    const b = document.createElement('button');
    b.textContent = label;
    b.dataset.hours = h;
    b.addEventListener('click', () => {
      range.isLive = true;
      range.currentH = h;
      range.end = range.dataEnd + 600_000;
      range.start = range.end - range.currentH * HOUR;
      render();
      togglePicker();
    });
    relEl.appendChild(b);
  });
  const renderRelActive = () => {
    relEl.querySelectorAll('button').forEach((b) => {
      const h = parseFloat(b.dataset.hours);
      b.classList.toggle('active', Math.abs(h - range.currentH) < 0.01 && range.isLive);
    });
  };

  // ── Calendar ──
  const DAYS = ['Lu', 'Ma', 'Me', 'Je', 'Ve', 'Sa', 'Di'];
  const MONTHS = [
    'Janvier',
    'F\u00e9vrier',
    'Mars',
    'Avril',
    'Mai',
    'Juin',
    'Juillet',
    'Ao\u00fbt',
    'Septembre',
    'Octobre',
    'Novembre',
    'D\u00e9cembre',
  ];
  const renderCal = () => {
    const first = new Date(calYear, calMonth, 1);
    const startDay = (first.getDay() + 6) % 7;
    const daysInMonth = new Date(calYear, calMonth + 1, 0).getDate();
    const prevDays = new Date(calYear, calMonth, 0).getDate();
    const today = new Date();
    const todayStr = `${today.getFullYear()}-${today.getMonth()}-${today.getDate()}`;

    const hFrom = selFrom || 0;
    const hTo = selTo || 0;

    let html = `<div class="tr-cal-hd">
      <button id="trCalPrev">&lsaquo;</button>
      <span>${MONTHS[calMonth]} ${calYear}</span>
      <button id="trCalNext">&rsaquo;</button>
    </div><table><tr>${DAYS.map((d) => `<th>${d}</th>`).join('')}</tr><tr>`;

    let cell = 0;
    for (let i = startDay - 1; i >= 0; i--) {
      const day = prevDays - i;
      html += `<td><button class="other">${day}</button></td>`;
      cell++;
    }
    for (let d = 1; d <= daysInMonth; d++) {
      if (cell && cell % 7 === 0) html += '</tr><tr>';
      const dt = new Date(calYear, calMonth, d);
      const dayStart = dt.getTime();
      const dayEnd = dayStart + 86400000;
      const str = `${calYear}-${calMonth}-${d}`;
      const cls = [];
      if (str === todayStr) cls.push('today');
      if (dayEnd < dataStart || dayStart > range.dataEnd + 600_000) cls.push('no-data');
      else if (hFrom && hTo) {
        const rS = Math.min(hFrom, hTo);
        const rE = Math.max(hFrom, hTo);
        if (dayStart >= rS && dayEnd <= rE) cls.push('in-range');
        if ((dayStart <= rS && dayEnd > rS) || (dayStart < rE && dayEnd >= rE)) cls.push('sel');
      }
      html += `<td><button class="${cls.join(' ')}" data-ts="${dayStart}">${d}</button></td>`;
      cell++;
    }
    let nd = 1;
    while (cell % 7 !== 0) {
      html += `<td><button class="other">${nd++}</button></td>`;
      cell++;
    }
    html += '</tr></table>';
    calEl.innerHTML = html;

    // Calendar nav
    document.getElementById('trCalPrev').addEventListener('click', (e) => {
      e.stopPropagation();
      calMonth--;
      if (calMonth < 0) {
        calMonth = 11;
        calYear--;
      }
      renderCal();
    });
    document.getElementById('trCalNext').addEventListener('click', (e) => {
      e.stopPropagation();
      calMonth++;
      if (calMonth > 11) {
        calMonth = 0;
        calYear++;
      }
      renderCal();
    });

    // Day click: first → From, second → To
    calEl.querySelectorAll('td button[data-ts]').forEach((b) => {
      if (b.classList.contains('no-data')) return;
      b.addEventListener('click', (e) => {
        e.stopPropagation();
        const t = parseInt(b.dataset.ts);
        if (!selFrom || selTo) {
          selFrom = t;
          selTo = null;
          fromIn.value = toLocalISO(t);
          toIn.value = '';
        } else {
          const a = Math.min(selFrom, t);
          const z = Math.max(selFrom, t) + 86400000;
          selFrom = a;
          selTo = z;
          fromIn.value = toLocalISO(a);
          toIn.value = toLocalISO(z);
        }
        renderCal();
      });
    });
  };

  // ── Recent ranges ──
  const renderRecent = () => {
    if (!recentRanges.length) {
      recentSec.style.display = 'none';
      return;
    }
    recentSec.style.display = '';
    recentEl.innerHTML = recentRanges
      .map(
        ([s, e]) =>
          `<button data-s="${s}" data-e="${e}">${fmtDate(s)} \u2192 ${fmtDate(e)}</button>`,
      )
      .join('');
    recentEl.querySelectorAll('button').forEach((b) =>
      b.addEventListener('click', () => {
        applyRange(parseInt(b.dataset.s), parseInt(b.dataset.e));
        togglePicker();
      }),
    );
  };
};
