// ── Sync status indicator ─────────────────────────────────────
{
  const dot = document.getElementById('syncDot');
  const timeEl = document.querySelector('nav .meta time[datetime]');
  if (dot && timeEl) {
    const iso = timeEl.getAttribute('datetime');
    const updated = new Date(iso);
    if (!isNaN(updated)) {
      // Allow simulating staleness via ?simAge=<minutes> (dev only)
      const simAge = new URLSearchParams(window.location.search).get('simAge');
      const ageMin = simAge !== null ? Number(simAge) : (Date.now() - updated.getTime()) / 60000;
      if (ageMin < 10) {
        dot.className = 'sync-dot sync-ok';
        dot.title = 'Synchronisation OK (< 10 min)';
      } else if (ageMin < 20) {
        dot.className = 'sync-dot sync-warn';
        dot.title = 'Synchronisation dégradée (10–20 min)';
      } else {
        dot.className = 'sync-dot sync-err';
        dot.title = 'Synchronisation en échec (> 20 min)';
      }
    }
  }
}

// ── Data loading ─────────────────────────────────────────────
const _dataReady = Promise.all([
  fetch('data.json').then((r) => r.json()),
  fetch('alerts.json').then((r) => r.json()),
]);

// ── Alerts ───────────────────────────────────────────────────
_dataReady.then(([, ALERTS]) => {
  // Escape HTML to prevent XSS from alert data
  const esc = (s) =>
    String(s).replace(
      /[&<>"']/g,
      (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
    );
  // Support both legacy array format and new {alerts, lastEvaluation} format
  const alertsArr = Array.isArray(ALERTS) ? ALERTS : ALERTS?.alerts;
  const lastEval = Array.isArray(ALERTS) ? null : ALERTS?.lastEvaluation;
  if (!Array.isArray(alertsArr) || !alertsArr.length) {
    document.getElementById('alertsSec').style.display = 'none';
    return;
  }
  // Convert m°C to °C in alert summaries and remove duplicate thresholds
  const fixTemp = (s) => {
    if (!s) return '';
    // Convert millidegrees to degrees: "70000 m°C" → "70.00 °C"
    let r = s.replace(/(\d+)\s*m°C/g, (_, v) => (parseInt(v) / 1000).toFixed(2) + ' °C');
    // Remove "/ 70°C" duplicate after converted threshold: "(threshold: 70.00 °C / 70°C)"
    r = r.replace(/(\d+\.?\d*\s*°C)\s*\/\s*\d+\.?\d*\s*°C/g, '$1');
    return r;
  };

  // Format lastEvaluation timestamp
  const fmtEval = (iso) => {
    if (!iso) return null;
    const d = new Date(iso);
    if (isNaN(d)) return null;
    const p = (n) => (n < 10 ? '0' + n : '' + n);
    const tz = d.toLocaleTimeString('fr-FR', { timeZoneName: 'short' }).split(' ').pop();
    return `${p(d.getDate())}/${p(d.getMonth() + 1)}/${d.getFullYear()} ${p(d.getHours())}:${p(
      d.getMinutes(),
    )}:${p(d.getSeconds())} (${tz})`;
  };
  const evalStr = fmtEval(lastEval);
  const evalHtml = evalStr
    ? `<div class="al-eval">Derni\u00e8re \u00e9valuation\u00a0: <time>${evalStr}</time></div>`
    : '';

  document.getElementById('alertsList').innerHTML =
    evalHtml +
    alertsArr
      .map((a) => {
        const icon =
          a.state === 'firing' ? '\uD83D\uDD34' : a.state === 'pending' ? '\u26A0\uFE0F' : '\u2705';
        const badge = a.state === 'firing' ? 'firing' : a.state === 'pending' ? 'pending' : 'ok';
        const label = a.state === 'inactive' ? 'ok' : a.state;
        return `<div class="al-row">
      <span class="al-icon">${icon}</span>
      <span class="al-name">${esc(a.name)}</span>
      <span class="al-sum">${esc(fixTemp(a.summary))}</span>
      <span class="al-badge ${badge}">${label}</span>
    </div>`;
      })
      .join('');
});

// ── Charts & Data ────────────────────────────────────────────
_dataReady.then(async ([RAW_DATA]) => {
  // Yield to main thread between heavy operations to avoid long tasks (TBT)
  const yieldToMain = () => new Promise((r) => setTimeout(r, 0));

  const statsEl = document.getElementById('statsRow');

  if (!RAW_DATA?.results?.[0]?.series?.[0]?.values?.length) {
    statsEl.innerHTML =
      '<div class="no-data" style="grid-column:1/-1">Aucune donn\u00e9e disponible</div>';
    return;
  }

  const { columns: cols, values } = RAW_DATA.results[0].series[0];
  const iT = cols.indexOf('time'),
    iDl = cols.indexOf('download_bandwidth');
  const iUl = cols.indexOf('upload_bandwidth'),
    iPi = cols.indexOf('ping_latency');
  const LEN = values.length;

  // ── Typed arrays ───────────────────────────────────────────
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

  await yieldToMain();

  // ── LTTB (typed array → [{x,y}]) ──────────────────────────
  const MAX_PTS = 600;
  const lttb = (xArr, yArr, i0, i1, n) => {
    const len = i1 - i0;
    if (len <= n) {
      const out = new Array(len);
      for (let i = 0; i < len; i++) out[i] = { x: xArr[i0 + i], y: yArr[i0 + i] };
      return out;
    }
    const out = [{ x: xArr[i0], y: yArr[i0] }];
    const bs = (len - 2) / (n - 2);
    let a = 0;
    for (let i = 0; i < n - 2; i++) {
      const s = Math.floor((i + 1) * bs) + 1;
      const e = Math.min(Math.floor((i + 2) * bs) + 1, len);
      const ns = Math.min(Math.floor((i + 2) * bs) + 1, len - 1);
      const ne = Math.min(Math.floor((i + 3) * bs) + 1, len);
      let ax = 0,
        ay = 0,
        c = 0;
      for (let j = ns; j < ne; j++) {
        ax += xArr[i0 + j];
        ay += yArr[i0 + j];
        c++;
      }
      if (c) {
        ax /= c;
        ay /= c;
      }
      let ma = -1,
        bi = s;
      const px = xArr[i0 + a],
        py = yArr[i0 + a];
      for (let j = s; j < e; j++) {
        const ar = Math.abs((px - ax) * (yArr[i0 + j] - py) - (px - xArr[i0 + j]) * (ay - py));
        if (ar > ma) {
          ma = ar;
          bi = j;
        }
      }
      out.push({ x: xArr[i0 + bi], y: yArr[i0 + bi] });
      a = bi;
    }
    out.push({ x: xArr[i0 + len - 1], y: yArr[i0 + len - 1] });
    return out;
  };

  // ── Bucketize for band chart ───────────────────────────────
  // Returns array of { x, min, q1, med, q3, max, n }
  const bucketize = (xArr, yArr, i0, i1, bucketMs) => {
    const buckets = [];
    if (i0 >= i1) return buckets;
    const buf = [];
    let bStart = Math.floor(xArr[i0] / bucketMs) * bucketMs;

    const flush = () => {
      if (!buf.length) return;
      buf.sort((a, b) => a - b);
      const n = buf.length,
        mid = n >> 1;
      buckets.push({
        x: bStart + bucketMs / 2,
        min: buf[0],
        q1: buf[Math.floor(n * 0.25)],
        med: n & 1 ? buf[mid] : (buf[mid - 1] + buf[mid]) / 2,
        q3: buf[Math.ceil(n * 0.75) - 1] || buf[n - 1],
        max: buf[n - 1],
        n,
      });
      buf.length = 0;
    };

    for (let i = i0; i < i1; i++) {
      const bKey = Math.floor(xArr[i] / bucketMs) * bucketMs;
      if (bKey !== bStart) {
        flush();
        bStart = bKey;
      }
      buf.push(yArr[i]);
    }
    flush();
    return buckets;
  };

  // ── Stats helpers ──────────────────────────────────────────
  const sortedSlice = (arr, i0, i1) => {
    const tmp = new Float64Array(i1 - i0);
    for (let i = 0; i < tmp.length; i++) tmp[i] = arr[i0 + i];
    tmp.sort();
    return tmp;
  };
  const medianOf = (s) => {
    const n = s.length,
      m = n >> 1;
    return n & 1 ? s[m] : (s[m - 1] + s[m]) / 2;
  };
  const pctOf = (s, p) => {
    const idx = (p / 100) * (s.length - 1);
    const lo = Math.floor(idx),
      hi = Math.ceil(idx);
    return lo === hi ? s[lo] : s[lo] + (s[hi] - s[lo]) * (idx - lo);
  };

  // ── Histogram distribution chart (SVG) ───────────────────
  // Splits [min, max] into 10 equal-width bins, counts samples per bin.
  const computeHistogram = (sorted, min, max) => {
    const NBINS = 10;
    const range = max - min || 1;
    const binW = range / NBINS;
    const bins = Array.from({ length: NBINS }, (_, i) => ({
      lo: min + i * binW,
      hi: min + (i + 1) * binW,
      count: 0,
    }));
    for (const v of sorted) {
      let idx = Math.floor((v - min) / binW);
      if (idx >= NBINS) idx = NBINS - 1; // max value goes in last bin
      if (idx < 0) idx = 0;
      bins[idx].count++;
    }
    return bins;
  };

  const histogramSVG = (bins, avg, median, color, unit, nSamples) => {
    const W = 260,
      H = 76;
    const PAD_T = 10,
      PAD_B = 12,
      PAD_L = 2,
      PAD_R = 2;
    const plotH = H - PAD_T - PAD_B;
    const plotW = W - PAD_L - PAD_R;
    const BAR_GAP = 2;
    const barW = (plotW - BAR_GAP * (bins.length + 1)) / bins.length;
    const bot = PAD_T + plotH;

    const maxCount = Math.max(...bins.map((b) => b.count), 1);
    const toY = (count) => PAD_T + plotH * (1 - count / maxCount);

    const fmtVal = (v) => (unit === 'ms' ? v.toFixed(1) : v.toFixed(0));

    // ── Build SVG ────────────────────────────────────────────
    let s = `<svg class="dcl-svg" viewBox="0 0 ${W} ${H}">`;

    const range = bins[bins.length - 1].hi - bins[0].lo || 1;
    const valToX = (v) => PAD_L + BAR_GAP + ((v - bins[0].lo) / range) * (plotW - BAR_GAP * 2);

    // Histogram bars (drawn first so markers render on top)
    bins.forEach((bin, i) => {
      const x = PAD_L + BAR_GAP + i * (barW + BAR_GAP);
      const barY = toY(bin.count);
      const barH = Math.max(bin.count > 0 ? 1 : 0, bot - barY);
      const pct = nSamples > 0 ? ((bin.count / nSamples) * 100).toFixed(0) : 0;
      const tipMain = `${bin.count} mesure${bin.count > 1 ? 's' : ''} (${pct}%)`;
      const tipSub = `${fmtVal(bin.lo)} \u2013 ${fmtVal(bin.hi)} ${unit}`;
      const HIT_PAD = 1;

      // Transparent hit area
      s += `<rect x="${(x - HIT_PAD).toFixed(1)}" y="${PAD_T}" width="${(barW + HIT_PAD * 2).toFixed(1)}" height="${plotH}" fill="transparent" class="dcl-hit" data-tip="${tipMain}" data-sub="${tipSub}"/>`;
      // Visible bar
      s += `<rect x="${x.toFixed(1)}" y="${barY.toFixed(1)}" width="${barW.toFixed(1)}" height="${barH.toFixed(1)}" rx="1.5" fill="${color}" class="dcl-bar${bin.count === maxCount ? ' dcl-p50' : ''}" pointer-events="none"/>`;
    });

    // Avg vertical marker (on top of bars, white outline for contrast)
    const avgX = valToX(avg);
    s += `<line x1="${avgX.toFixed(1)}" y1="${PAD_T}" x2="${avgX.toFixed(1)}" y2="${bot}" stroke="var(--bg)" stroke-width="3" opacity=".5"/>`;
    s += `<line x1="${avgX.toFixed(1)}" y1="${PAD_T}" x2="${avgX.toFixed(1)}" y2="${bot}" stroke="${color}" stroke-width="1.5" stroke-dasharray="4,3" opacity=".9"/>`;
    s += `<text x="${avgX.toFixed(1)}" y="${PAD_T - 1.5}" fill="${color}" font-size="7" text-anchor="middle" opacity=".9">avg</text>`;

    // Median vertical marker (on top of bars, white outline for contrast)
    const medX = valToX(median);
    s += `<line x1="${medX.toFixed(1)}" y1="${PAD_T}" x2="${medX.toFixed(1)}" y2="${bot}" stroke="var(--bg)" stroke-width="3" opacity=".5"/>`;
    s += `<line x1="${medX.toFixed(1)}" y1="${PAD_T}" x2="${medX.toFixed(1)}" y2="${bot}" stroke="var(--text)" stroke-width="1.5" stroke-dasharray="2,2" opacity=".9"/>`;
    s += `<text x="${medX.toFixed(1)}" y="${PAD_T - 1.5}" fill="var(--text)" font-size="7" text-anchor="middle" font-weight="600">m\u00e9d</text>`;

    // Bottom labels: bin range boundaries (min and max + middle tick)
    const fmtShort = (v) =>
      unit === 'ms' ? v.toFixed(0) : v >= 1000 ? (v / 1000).toFixed(1) + 'k' : v.toFixed(0);
    s += `<text x="${PAD_L + BAR_GAP}" y="${H - 1}" fill="var(--text3)" font-size="6" text-anchor="start">${fmtShort(bins[0].lo)}</text>`;
    const midBin = Math.floor(bins.length / 2);
    const midX = PAD_L + BAR_GAP + midBin * (barW + BAR_GAP) + barW / 2;
    s += `<text x="${midX.toFixed(1)}" y="${H - 1}" fill="var(--text3)" font-size="6" text-anchor="middle">${fmtShort(bins[midBin].lo)}</text>`;
    s += `<text x="${W - PAD_R - BAR_GAP}" y="${H - 1}" fill="var(--text3)" font-size="6" text-anchor="end">${fmtShort(bins[bins.length - 1].hi)}</text>`;

    s += '</svg>';
    return s;
  };

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

  // ── Quality dot tooltip (click to show/hide) ───────────────
  let _qualityData = {};
  const qTip = document.createElement('div');
  qTip.className = 'q-tip';
  document.body.appendChild(qTip);
  let qTipActive = null;

  document.addEventListener('click', (e) => {
    const dot = e.target.closest?.('.q-dot');
    if (dot && dot !== qTipActive) {
      qTipActive = dot;
      const metric = dot.dataset.metric;
      const d = _qualityData[metric];
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

  // ── Constants ──────────────────────────────────────────────
  const HOUR = 3_600_000;
  const BAND_THRESHOLD = 48; // hours: above this → band mode
  const presets = [6, 12, 24, 48, 168, 720];
  const COL = { dl: '#7eb6f6', ul: '#c982e0', pi: '#f2a93b' };
  const dataEnd = ts[LEN - 1];
  let currentH = 48,
    rangeEnd = dataEnd + 600_000;
  let rangeStart = rangeEnd - currentH * HOUR;
  let isLive = true,
    renderRAF = 0,
    lastMode = '';

  const pad2 = (n) => (n < 10 ? '0' + n : '' + n);
  const tzAbbr = new Date().toLocaleTimeString('fr-FR', { timeZoneName: 'short' }).split(' ').pop();
  const fmtDate = (t) => {
    const d = new Date(t);
    return `${pad2(d.getDate())}/${pad2(d.getMonth() + 1)} ${pad2(d.getHours())}:${pad2(
      d.getMinutes(),
    )}`;
  };
  const fmtDateTz = (t) => `${fmtDate(t)} ${tzAbbr}`;
  const fmtSpd = (v) =>
    v >= 1000
      ? `${(v / 1000).toFixed(1)}<span class="u">Gb/s</span>`
      : `${v.toFixed(0)}<span class="u">Mb/s</span>`;
  const fmtSpd0 = (v) => (v >= 1000 ? (v / 1000).toFixed(1) + ' G' : v.toFixed(0));

  const bsearch = (target, first) => {
    let lo = 0,
      hi = LEN - 1,
      r = first ? LEN : -1;
    while (lo <= hi) {
      const m = (lo + hi) >> 1;
      if (first) {
        if (ts[m] >= target) {
          r = m;
          hi = m - 1;
        } else lo = m + 1;
      } else {
        if (ts[m] <= target) {
          r = m;
          lo = m + 1;
        } else hi = m - 1;
      }
    }
    return r;
  };

  const filterRange = (s, e) => {
    const i0 = bsearch(s, true),
      i1 = bsearch(e, false);
    return i0 <= i1 && i0 < LEN ? [i0, i1 + 1] : null;
  };

  const bucketSize = () => (currentH <= 168 ? 2 * HOUR : currentH <= 720 ? 6 * HOUR : 24 * HOUR);

  // ── Gradient ───────────────────────────────────────────────
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
  const rgba = (hex, a) => {
    const [r, g, b] = hex
      .slice(1)
      .match(/.{2}/g)
      .map((x) => parseInt(x, 16));
    return `rgba(${r},${g},${b},${a})`;
  };

  // ── Chart config ───────────────────────────────────────────
  Chart.defaults.color = '#555';
  Chart.defaults.borderColor = '#2a2a2d';

  const mono = "'Geist Mono',monospace";
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
  const tooltipDismissPlugin = {
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
  };
  Chart.register(tooltipDismissPlugin);

  const tipStyle = {
    backgroundColor: '#141415',
    borderColor: '#2a2a2d',
    borderWidth: 1,
    titleFont: { family: mono, size: 11 },
    bodyFont: { family: mono, size: 11 },
    padding: 10,
    cornerRadius: 4,
  };

  // ── Drag-to-zoom (chartjs-plugin-zoom) — loaded lazily ─────
  const onZoomOrPan = ({ chart }) => {
    const { min, max } = chart.scales.x;
    rangeStart = min;
    rangeEnd = max;
    currentH = (rangeEnd - rangeStart) / HOUR;
    isLive = rangeEnd >= dataEnd;
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

  // Charts created once, datasets swapped per mode
  const bwCtx = document.getElementById('bwChart').getContext('2d');
  const bwH = document.getElementById('bwChart').parentElement.clientHeight || 300;
  await yieldToMain();

  const bwChart = new Chart(bwCtx, {
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
              const ds = c.dataset;
              if (ds._isBand) return null; // hide band tooltip lines
              return `${ds.label}: ${c.parsed.y.toFixed(1)} Mb/s`;
            },
          },
          filter: (c) => c.dataset.label && !c.dataset._isBand,
        },
      },
    },
  });

  await yieldToMain();

  const piCtx = document.getElementById('piChart').getContext('2d');
  const piH = document.getElementById('piChart').parentElement.clientHeight || 200;
  const piChart = new Chart(piCtx, {
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
            label: (c) => {
              if (c.dataset._isBand) return null;
              return `${c.parsed.y.toFixed(1)} ms`;
            },
          },
          filter: (c) => !c.dataset._isBand,
        },
      },
    },
  });

  // ── Dataset factories ──────────────────────────────────────
  const dsLine = {
    tension: 0.15,
    pointRadius: 0,
    pointHitRadius: 6,
    pointHoverRadius: 3,
    borderWidth: 1.5,
  };

  // Band datasets: Q3 fill→Q1, Q1 invisible, median solid
  const makeBandDs = (buckets, color, label) => [
    {
      // Q3 upper boundary → fills down to Q1
      ...dsLine,
      data: buckets.map((b) => ({ x: b.x, y: b.q3 })),
      borderColor: 'transparent',
      borderWidth: 0,
      pointRadius: 0,
      backgroundColor: rgba(color, 0.15),
      fill: '+1',
      _isBand: true,
      tension: 0.3,
    },
    {
      // Q1 lower boundary
      ...dsLine,
      data: buckets.map((b) => ({ x: b.x, y: b.q1 })),
      borderColor: rgba(color, 0.3),
      borderWidth: 0.5,
      pointRadius: 0,
      fill: false,
      _isBand: true,
      tension: 0.3,
    },
    {
      // Median line
      ...dsLine,
      data: buckets.map((b) => ({ x: b.x, y: b.med })),
      borderColor: color,
      borderWidth: 2,
      pointRadius: 0,
      fill: false,
      label,
      tension: 0.3,
    },
    {
      // Min whisker (very faint)
      ...dsLine,
      data: buckets.map((b) => ({ x: b.x, y: b.min })),
      borderColor: rgba(color, 0.12),
      borderWidth: 1,
      pointRadius: 0,
      borderDash: [2, 3],
      fill: false,
      _isBand: true,
      tension: 0.3,
    },
    {
      // Max whisker (very faint)
      ...dsLine,
      data: buckets.map((b) => ({ x: b.x, y: b.max })),
      borderColor: rgba(color, 0.12),
      borderWidth: 1,
      pointRadius: 0,
      borderDash: [2, 3],
      fill: false,
      _isBand: true,
      tension: 0.3,
    },
  ];

  const makeLineDs = (xArr, yArr, i0, i1, color, label, ctx, h) => [
    {
      ...dsLine,
      label,
      data: lttb(xArr, yArr, i0, i1, MAX_PTS),
      borderColor: color,
      backgroundColor: mkGrad(ctx, color, h),
      fill: true,
    },
  ];

  // ── Stat card builder ──────────────────────────────────────
  // ── Quality score (composite: performance + stability) ────
  // Performance thresholds: { good, bad } — below bad → score=1, above good → score=0
  // For ping: inverted (lower is better)
  const QUALITY_THRESHOLDS = {
    dl: { good: 800, bad: 500 },
    ul: { good: 500, bad: 200 },
    pi: { good: 20, bad: 50 }, // inverted: low=good
  };
  const PERF_WEIGHT = 0.3,
    STAB_WEIGHT = 0.7;

  const qualityScore = (metric, median, sorted, avg, nPts) => {
    const th = QUALITY_THRESHOLDS[metric];
    // Performance score (0=nominal, 1=critical)
    let perf;
    if (metric === 'pi') {
      perf = median <= th.good ? 0 : median >= th.bad ? 1 : (median - th.good) / (th.bad - th.good);
    } else {
      perf = median >= th.good ? 0 : median <= th.bad ? 1 : (th.good - median) / (th.good - th.bad);
    }
    // Stability via IQR / median (robust to outliers)
    // IQR = Q3 - Q1 = interquartile range (middle 50% of data)
    // Normalized by median to be scale-independent
    // Thresholds: ≤ 0.05 = very stable, ≥ 0.30 = very unstable
    const q1 = pctOf(sorted, 25);
    const q3 = pctOf(sorted, 75);
    const iqr = q3 - q1;
    const iqrRatio = median > 0 ? iqr / median : 0;
    const IQR_GOOD = 0.05,
      IQR_BAD = 0.3;
    const stab =
      iqrRatio <= IQR_GOOD
        ? 0
        : iqrRatio >= IQR_BAD
          ? 1
          : (iqrRatio - IQR_GOOD) / (IQR_BAD - IQR_GOOD);
    // Composite
    const score = Math.min(1, Math.max(0, PERF_WEIGHT * perf + STAB_WEIGHT * stab));
    const hue = 120 * (1 - score);
    const color = `hsl(${hue.toFixed(0)}, 85%, 50%)`;
    return { score, perf, stab, q1, q3, iqr, iqrRatio, color, hue };
  };

  const fmtPct = (v) => (v * 100).toFixed(0) + '%';

  const qualityTooltipHtml = (metric, q, median, nPts, unit) => {
    const th = QUALITY_THRESHOLDS[metric];
    const thDir = metric === 'pi' ? '\u2264' : '\u2265';
    const thBad = metric === 'pi' ? '\u2265' : '\u2264';
    const label =
      q.score < 0.3
        ? 'Excellent'
        : q.score < 0.6
          ? 'Correct'
          : q.score < 0.8
            ? 'D\u00e9grad\u00e9'
            : 'Critique';
    return `<div class="q-tip-title">${label} <span style="color:${q.color}">(${fmtPct(1 - q.score)})</span></div>
<div class="q-tip-grid">
  <span class="q-tip-label">Performance</span><span class="q-tip-val">${fmtPct(1 - q.perf)}</span>
  <span class="q-tip-detail">m\u00e9diane ${median.toFixed(1)} ${unit} (vert ${thDir} ${th.good}, rouge ${thBad} ${th.bad})</span>
  <span class="q-tip-label">Stabilit\u00e9</span><span class="q-tip-val">${fmtPct(1 - q.stab)}</span>
  <span class="q-tip-detail">IQR/m\u00e9d = ${(q.iqrRatio * 100).toFixed(1)}% (Q1=${q.q1.toFixed(1)}, Q3=${q.q3.toFixed(1)}, IQR=${q.iqr.toFixed(1)} ${unit})</span>
  <span class="q-tip-detail">vert \u2264 5%, rouge \u2265 30%</span>
  <span class="q-tip-label">Pond\u00e9ration</span><span class="q-tip-val">${(PERF_WEIGHT * 100).toFixed(0)}/${(STAB_WEIGHT * 100).toFixed(0)}</span>
  <span class="q-tip-detail">perf \u00d7 ${PERF_WEIGHT} + stab \u00d7 ${STAB_WEIGHT}</span>
</div>`;
  };

  const statCard = (
    cls,
    label,
    mainVal,
    chartSVG,
    summary,
    lastVal,
    nPts,
    timeRange,
    qualityInfo,
  ) =>
    `<div class="stat ${cls}">
      <div class="v">${mainVal}${qualityInfo ? `<span class="q-dot" data-metric="${cls}" style="background:${qualityInfo.color};box-shadow:0 0 6px ${qualityInfo.color}"></span>` : ''}</div>
      <div class="l">${label} <span class="l-sub">m\u00e9diane</span></div>
      <div class="dcl-wrap">${chartSVG}</div>
      <div class="stat-sum">${summary}</div>
      <div class="stat-last">LAST <strong>${lastVal}</strong></div>
      <div class="pts">${timeRange} \u00b7 ${nPts} pts</div>
    </div>`;

  // ── Band tooltip (shows bucket stats) ──────────────────────
  const bandTooltipBw = {
    ...tipStyle,
    filter: (c) => !c.dataset._isBand,
    callbacks: {
      label: (c) => {
        if (c.dataset._isBand) return null;
        const val = c.parsed.y.toFixed(1);
        return `${c.dataset.label} med: ${val} Mb/s`;
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

  // ── Render ─────────────────────────────────────────────────
  const doRender = () => {
    // Dismiss any active decile tooltip (stats cards are about to be rebuilt)
    dclClearSelection();

    const rng = filterRange(rangeStart, rangeEnd);
    const mode = currentH > BAND_THRESHOLD ? 'band' : 'line';

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

      // Padded range: include one sample before/after for continuous curves
      const p0 = Math.max(0, i0 - 1);
      const p1 = Math.min(LEN, i1 + 1);

      // ── Stats ──────────────────────────────────────────────
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
        const d = dl[i],
          u = ul[i],
          p = pi[i];
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
      const dlSorted = sortedSlice(dl, i0, i1);
      const ulSorted = sortedSlice(ul, i0, i1);
      const piSorted = sortedSlice(pi, i0, i1);
      const dlMed = medianOf(dlSorted),
        ulMed = medianOf(ulSorted),
        piMed = medianOf(piSorted);
      const piP95 = pctOf(piSorted, 95);

      const trLabel = `${fmtDateTz(rangeStart)} \u2192 ${fmtDateTz(rangeEnd)}`;

      const dlHist = computeHistogram(dlSorted, dlMn, dlMx);
      const ulHist = computeHistogram(ulSorted, ulMn, ulMx);
      const piHist = computeHistogram(piSorted, piMn, piMx);

      const dlQ = qualityScore('dl', dlMed, dlSorted, dlAvg, n);
      const ulQ = qualityScore('ul', ulMed, ulSorted, ulAvg, n);
      const piQ = qualityScore('pi', piMed, piSorted, piAvg, n);

      // Store quality data for tooltip on click
      _qualityData = {
        dl: { q: dlQ, median: dlMed, n, unit: 'Mb/s' },
        ul: { q: ulQ, median: ulMed, n, unit: 'Mb/s' },
        pi: { q: piQ, median: piMed, n, unit: 'ms' },
      };

      statsEl.innerHTML =
        statCard(
          'dl',
          'Download',
          fmtSpd(dlMed),
          histogramSVG(dlHist, dlAvg, dlMed, COL.dl, 'Mb/s', n),
          `min ${fmtSpd0(dlMn)} \u00b7 avg ${fmtSpd0(dlAvg)} \u00b7 max ${fmtSpd0(dlMx)}`,
          fmtSpd0(dl[i1 - 1]),
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
          fmtSpd0(ul[i1 - 1]),
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
          pi[i1 - 1].toFixed(1),
          n,
          trLabel,
          piQ,
        );

      // ── Legend ─────────────────────────────────────────────
      const bandLabel =
        mode === 'band' ? ' <span style="color:var(--text3)">(m\u00e9diane + IQR)</span>' : '';
      document.getElementById('bwLeg').innerHTML = `
        <span><i style="background:${COL.dl}"></i>download${bandLabel}</span>
        <span><i style="background:${COL.ul}"></i>upload</span>`;
      document.getElementById('piLeg').innerHTML = `
        <span><i style="background:${COL.pi}"></i>latency${bandLabel}</span>`;

      // ── Datasets (padded range for edge continuity) ────────
      if (mode === 'band') {
        const bMs = bucketSize();
        const dlB = bucketize(ts, dl, p0, p1, bMs);
        const ulB = bucketize(ts, ul, p0, p1, bMs);
        const piB = bucketize(ts, pi, p0, p1, bMs);

        bwChart.data.datasets = [
          ...makeBandDs(dlB, COL.dl, 'download'),
          ...makeBandDs(ulB, COL.ul, 'upload'),
        ];
        bwChart.options.plugins.tooltip = bandTooltipBw;

        piChart.data.datasets = makeBandDs(piB, COL.pi, 'latency');
        piChart.options.plugins.tooltip = bandTooltipPi;
      } else {
        bwChart.data.datasets = [
          ...makeLineDs(ts, dl, p0, p1, COL.dl, 'download', bwCtx, bwH),
          ...makeLineDs(ts, ul, p0, p1, COL.ul, 'upload', bwCtx, bwH),
        ];
        bwChart.options.plugins.tooltip = {
          ...tipStyle,
          callbacks: {
            label: (c) => `${c.dataset.label}: ${c.parsed.y.toFixed(1)} Mb/s`,
          },
        };

        piChart.data.datasets = makeLineDs(ts, pi, p0, p1, COL.pi, 'latency', piCtx, piH);
        piChart.options.plugins.tooltip = {
          ...tipStyle,
          callbacks: {
            label: (c) => `${c.parsed.y.toFixed(1)} ms`,
          },
        };
      }
    }

    bwChart.options.scales.x.min = rangeStart;
    bwChart.options.scales.x.max = rangeEnd;

    piChart.options.scales.x.min = rangeStart;
    piChart.options.scales.x.max = rangeEnd;

    document.getElementById('rangeLabel').textContent = `${fmtDateTz(
      rangeStart,
    )}  \u2192  ${fmtDateTz(rangeEnd)}`;
    document
      .querySelectorAll('.rb')
      .forEach((b) => b.classList.toggle('on', parseInt(b.dataset.hours) === currentH));
    lastMode = mode;
  };

  const flushCharts = () => {
    bwChart.update('none');
    piChart.update('none');
  };

  const render = () => {
    cancelAnimationFrame(renderRAF);
    renderRAF = requestAnimationFrame(() => {
      doRender();
      flushCharts();
    });
  };

  // ── Time controls ──────────────────────────────────────────
  const setRange = (h) => {
    currentH = h;
    if (isLive) rangeEnd = dataEnd + 600_000;
    rangeStart = rangeEnd - currentH * HOUR;
    render();
  };

  const shift = (dir) => {
    const s = currentH * HOUR * 0.5 * dir;
    rangeStart += s;
    rangeEnd += s;
    isLive = rangeEnd >= dataEnd;
    render();
  };

  document.querySelectorAll('.rb').forEach((b) =>
    b.addEventListener('click', () => {
      isLive = true;
      setRange(parseInt(b.dataset.hours));
    }),
  );
  document.getElementById('btnBack').addEventListener('click', () => shift(-1));
  document.getElementById('btnFwd').addEventListener('click', () => shift(1));
  document.getElementById('btnZoomIn').addEventListener('click', () => {
    const i = presets.indexOf(currentH);
    if (i > 0) setRange(presets[i - 1]);
    else if (currentH > presets[0]) setRange(presets[0]);
  });
  document.getElementById('btnZoomOut').addEventListener('click', () => {
    const i = presets.indexOf(currentH);
    if (i >= 0 && i < presets.length - 1) setRange(presets[i + 1]);
    else if (i < 0) {
      for (const p of presets) {
        if (p > currentH) {
          setRange(p);
          break;
        }
      }
    }
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowLeft') shift(-1);
    else if (e.key === 'ArrowRight') shift(1);
    else if (e.key === '+' || e.key === '=') document.getElementById('btnZoomIn').click();
    else if (e.key === '-') document.getElementById('btnZoomOut').click();
  });

  // Double-click on chart → reset to default 48 h live view
  const resetToLive = () => {
    isLive = true;
    setRange(48);
  };
  document.getElementById('bwChart').addEventListener('dblclick', resetToLive);
  document.getElementById('piChart').addEventListener('dblclick', resetToLive);

  // ── Middle-click drag to pan ───────────────────────────────
  ['bwChart', 'piChart'].forEach((id) => {
    const canvas = document.getElementById(id);
    let panning = false,
      startX = 0,
      startRange = 0;
    canvas.addEventListener('mousedown', (e) => {
      if (e.button !== 1) return; // middle button only
      e.preventDefault();
      panning = true;
      startX = e.clientX;
      startRange = rangeStart;
      canvas.style.cursor = 'grabbing';
    });
    window.addEventListener('mousemove', (e) => {
      if (!panning) return;
      const chart = Chart.getChart(id);
      const xScale = chart.scales.x;
      const pxRange = xScale.right - xScale.left;
      const msPerPx = (rangeEnd - rangeStart) / pxRange;
      const dx = startX - e.clientX; // drag left → move range forward
      const shift = dx * msPerPx;
      rangeStart = startRange + shift;
      rangeEnd = rangeStart + currentH * HOUR;
      isLive = rangeEnd >= dataEnd;
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
    // Prevent default middle-click scroll behavior
    canvas.addEventListener('auxclick', (e) => {
      if (e.button === 1) e.preventDefault();
    });
  });

  await yieldToMain();

  // ── Grafana-style time range picker ────────────────────────
  (() => {
    const picker = document.getElementById('trPicker');
    const btn = document.getElementById('rangeLabelBtn');
    const calEl = document.getElementById('trCal');
    const fromIn = document.getElementById('trFrom');
    const toIn = document.getElementById('trTo');
    const recentSec = document.getElementById('trRecentSec');
    const recentEl = document.getElementById('trRecent');
    const relEl = document.getElementById('trRel');

    let pickerOpen = false;
    let calYear, calMonth; // currently displayed month
    let selFrom = null,
      selTo = null; // calendar selection state (timestamps)
    const dataStart = ts[0];

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
      selFrom = rangeStart;
      selTo = rangeEnd;
      fromIn.value = toLocalISO(rangeStart);
      toIn.value = toLocalISO(rangeEnd);
      const d = new Date(rangeStart);
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
      rangeStart = s;
      rangeEnd = e;
      currentH = (rangeEnd - rangeStart) / HOUR;
      isLive = rangeEnd >= dataEnd;
      addRecent(s, e);
      render();
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
        isLive = true;
        currentH = h;
        rangeEnd = dataEnd + 600_000;
        rangeStart = rangeEnd - currentH * HOUR;
        render();
        togglePicker();
      });
      relEl.appendChild(b);
    });
    const renderRelActive = () => {
      relEl.querySelectorAll('button').forEach((b) => {
        const h = parseFloat(b.dataset.hours);
        b.classList.toggle('active', Math.abs(h - currentH) < 0.01 && isLive);
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
      const startDay = (first.getDay() + 6) % 7; // Mon=0
      const daysInMonth = new Date(calYear, calMonth + 1, 0).getDate();
      const prevDays = new Date(calYear, calMonth, 0).getDate();
      const today = new Date();
      const todayStr = `${today.getFullYear()}-${today.getMonth()}-${today.getDate()}`;

      // Use picker selection (from inputs) for calendar highlighting
      const hFrom = selFrom || 0;
      const hTo = selTo || 0;

      let html = `<div class="tr-cal-hd">
        <button id="trCalPrev">&lsaquo;</button>
        <span>${MONTHS[calMonth]} ${calYear}</span>
        <button id="trCalNext">&rsaquo;</button>
      </div><table><tr>${DAYS.map((d) => `<th>${d}</th>`).join('')}</tr><tr>`;

      let cell = 0;
      // Previous month padding
      for (let i = startDay - 1; i >= 0; i--) {
        const day = prevDays - i;
        html += `<td><button class="other">${day}</button></td>`;
        cell++;
      }
      // Current month
      for (let d = 1; d <= daysInMonth; d++) {
        if (cell && cell % 7 === 0) html += '</tr><tr>';
        const dt = new Date(calYear, calMonth, d);
        const dayStart = dt.getTime();
        const dayEnd = dayStart + 86400000;
        const str = `${calYear}-${calMonth}-${d}`;
        const cls = [];
        if (str === todayStr) cls.push('today');
        if (dayEnd < dataStart || dayStart > dataEnd + 600_000) cls.push('no-data');
        else if (hFrom && hTo) {
          // Highlight based on picker From/To selection
          const rS = Math.min(hFrom, hTo);
          const rE = Math.max(hFrom, hTo);
          if (dayStart >= rS && dayEnd <= rE) cls.push('in-range');
          if ((dayStart <= rS && dayEnd > rS) || (dayStart < rE && dayEnd >= rE)) cls.push('sel');
        }
        html += `<td><button class="${cls.join(' ')}" data-ts="${dayStart}">${d}</button></td>`;
        cell++;
      }
      // Next month padding
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

      // Day click: first click → set From, second click → set To
      calEl.querySelectorAll('td button[data-ts]').forEach((b) => {
        if (b.classList.contains('no-data')) return;
        b.addEventListener('click', (e) => {
          e.stopPropagation();
          const t = parseInt(b.dataset.ts);
          if (!selFrom || selTo) {
            // First click or reset: set From
            selFrom = t;
            selTo = null;
            fromIn.value = toLocalISO(t);
            toIn.value = '';
          } else {
            // Second click: set To (ensure From < To)
            const a = Math.min(selFrom, t);
            const z = Math.max(selFrom, t) + 86400000; // end of the later day
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
          rangeStart = parseInt(b.dataset.s);
          rangeEnd = parseInt(b.dataset.e);
          currentH = (rangeEnd - rangeStart) / HOUR;
          isLive = rangeEnd >= dataEnd;
          render();
          togglePicker();
        }),
      );
    };
  })();

  await yieldToMain();

  // Initial render — split chart updates to avoid long tasks
  doRender();
  bwChart.update('none');
  await yieldToMain();
  piChart.update('none');
  await yieldToMain();

  // ── Lazy-load hammerjs + chartjs-plugin-zoom after first paint ──
  const loadZoom = () => {
    const s1 = document.createElement('script');
    s1.src = 'https://cdn.jsdelivr.net/npm/hammerjs@2';
    s1.onload = () => {
      const s2 = document.createElement('script');
      s2.src = 'https://cdn.jsdelivr.net/npm/chartjs-plugin-zoom@2';
      s2.onload = () => {
        bwChart.options.plugins.zoom = zoomOpts;
        bwChart.update('none');
        setTimeout(() => {
          piChart.options.plugins.zoom = zoomOpts;
          piChart.update('none');
        }, 0);
      };
      document.head.appendChild(s2);
    };
    document.head.appendChild(s1);
  };
  if ('requestIdleCallback' in window) requestIdleCallback(loadZoom);
  else setTimeout(loadZoom, 100);
});
