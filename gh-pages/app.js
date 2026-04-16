// ── Alerts ───────────────────────────────────────────────────
(() => {
  if (!Array.isArray(ALERTS) || !ALERTS.length) return;
  document.getElementById("alertsSec").style.display = "";
  // Convert m°C to °C in alert summaries
  const fixTemp = (s) =>
    s
      ? s.replace(
          /(\d+)\s*m°C/g,
          (_, v) => (parseInt(v) / 1000).toFixed(2) + " °C",
        )
      : "";

  document.getElementById("alertsList").innerHTML = ALERTS.map((a) => {
    const icon =
      a.state === "firing" ? "\uD83D\uDD34" : a.state === "pending" ? "\u26A0\uFE0F" : "\u2705";
    const badge =
      a.state === "firing" ? "firing" : a.state === "pending" ? "pending" : "ok";
    const label = a.state === "inactive" ? "ok" : a.state;
    return `<div class="al-row">
      <span class="al-icon">${icon}</span>
      <span class="al-name">${a.name}</span>
      <span class="al-sum">${fixTemp(a.summary)}</span>
      <span class="al-badge ${badge}">${label}</span>
    </div>`;
  }).join("");
})();

// ── Charts & Data ────────────────────────────────────────────
(() => {
  const statsEl = document.getElementById("statsRow");

  if (!RAW_DATA?.results?.[0]?.series?.[0]?.values?.length) {
    statsEl.innerHTML =
      '<div class="no-data" style="grid-column:1/-1">Aucune donn\u00e9e disponible</div>';
    return;
  }

  const { columns: cols, values } = RAW_DATA.results[0].series[0];
  const iT = cols.indexOf("time"),
    iDl = cols.indexOf("download_bandwidth");
  const iUl = cols.indexOf("upload_bandwidth"),
    iPi = cols.indexOf("ping_latency");
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

  // ── LTTB (typed array → [{x,y}]) ──────────────────────────
  const MAX_PTS = 600;
  const lttb = (xArr, yArr, i0, i1, n) => {
    const len = i1 - i0;
    if (len <= n) {
      const out = new Array(len);
      for (let i = 0; i < len; i++)
        out[i] = { x: xArr[i0 + i], y: yArr[i0 + i] };
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
        const ar = Math.abs(
          (px - ax) * (yArr[i0 + j] - py) -
            (px - xArr[i0 + j]) * (ay - py),
        );
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

  // ── Constants ──────────────────────────────────────────────
  const HOUR = 3_600_000;
  const BAND_THRESHOLD = 48; // hours: above this → band mode
  const presets = [6, 12, 24, 48, 168, 720];
  const COL = { dl: "#7eb6f6", ul: "#c982e0", pi: "#f2a93b" };
  const dataEnd = ts[LEN - 1];
  let currentH = 48,
    rangeEnd = dataEnd + 600_000;
  let rangeStart = rangeEnd - currentH * HOUR;
  let isLive = true,
    renderRAF = 0,
    lastMode = "";

  const pad2 = (n) => (n < 10 ? "0" + n : "" + n);
  const fmtDate = (t) => {
    const d = new Date(t);
    return `${pad2(d.getDate())}/${pad2(d.getMonth() + 1)} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
  };
  const fmtSpd = (v) =>
    v >= 1000
      ? `${(v / 1000).toFixed(1)}<span class="u">Gb/s</span>`
      : `${v.toFixed(0)}<span class="u">Mb/s</span>`;
  const fmtSpd0 = (v) =>
    v >= 1000 ? (v / 1000).toFixed(1) + " G" : v.toFixed(0);

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

  const bucketSize = () =>
    currentH <= 168 ? 2 * HOUR : currentH <= 720 ? 6 * HOUR : 24 * HOUR;

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
  Chart.defaults.color = "#555";
  Chart.defaults.borderColor = "#2a2a2d";

  const mono = "'Geist Mono',monospace";
  const scaleX = {
    type: "time",
    time: {
      tooltipFormat: "dd/MM HH:mm",
      displayFormats: { hour: "HH:mm", day: "dd/MM" },
    },
    grid: { color: "#1e2228" },
    ticks: { font: { family: mono, size: 10 }, maxTicksLimit: 12 },
  };
  const baseOpts = (ar) => ({
    responsive: true,
    maintainAspectRatio: true,
    aspectRatio: innerWidth < 600 ? 1.5 : ar,
    animation: false,
    parsing: false,
    normalized: true,
    interaction: { mode: "index", intersect: false },
    scales: { x: { ...scaleX } },
    plugins: { legend: { display: false } },
  });
  const tipStyle = {
    backgroundColor: "#141415",
    borderColor: "#2a2a2d",
    borderWidth: 1,
    titleFont: { family: mono, size: 11 },
    bodyFont: { family: mono, size: 11 },
    padding: 10,
    cornerRadius: 4,
  };

  // Charts created once, datasets swapped per mode
  const bwCtx = document.getElementById("bwChart").getContext("2d");
  const bwH =
    document.getElementById("bwChart").parentElement.clientHeight || 300;
  const bwChart = new Chart(bwCtx, {
    type: "line",
    data: { datasets: [] },
    options: {
      ...baseOpts(2.8),
      scales: {
        x: { ...scaleX },
        y: {
          beginAtZero: true,
          grid: { color: "#1e2228" },
          ticks: {
            font: { family: mono, size: 10 },
            callback: (v) =>
              v >= 1000 ? (v / 1000).toFixed(1) + " Gb/s" : v + " Mb/s",
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

  const piCtx = document.getElementById("piChart").getContext("2d");
  const piH =
    document.getElementById("piChart").parentElement.clientHeight || 200;
  const piChart = new Chart(piCtx, {
    type: "line",
    data: { datasets: [] },
    options: {
      ...baseOpts(4),
      scales: {
        x: { ...scaleX },
        y: {
          beginAtZero: true,
          grid: { color: "#1e2228" },
          ticks: {
            font: { family: mono, size: 10 },
            callback: (v) => v + " ms",
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
      borderColor: "transparent",
      borderWidth: 0,
      pointRadius: 0,
      backgroundColor: rgba(color, 0.15),
      fill: "+1",
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
  const statCard = (cls, label, mainVal, items, nPts, timeRange) =>
    `<div class="stat ${cls}">
      <div class="v">${mainVal}</div>
      <div class="l">${label} <span style="font-size:.85em;opacity:.5">m\u00e9diane</span></div>
      <dl class="sg">${items.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join("")}</dl>
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
      label: (c) =>
        c.dataset._isBand ? null : `med: ${c.parsed.y.toFixed(1)} ms`,
    },
  };

  // ── Render ─────────────────────────────────────────────────
  const doRender = () => {
    const rng = filterRange(rangeStart, rangeEnd);
    const mode = currentH > BAND_THRESHOLD ? "band" : "line";

    if (!rng) {
      statsEl.innerHTML =
        '<div class="no-data" style="grid-column:1/-1">Aucune donn\u00e9e sur cette p\u00e9riode</div>';
      document.getElementById("bwLeg").innerHTML = "";
      document.getElementById("piLeg").innerHTML = "";
      bwChart.data.datasets = [];
      piChart.data.datasets = [];
    } else {
      const [i0, i1] = rng;
      const n = i1 - i0;

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

      const trLabel = `${fmtDate(rangeStart)} \u2192 ${fmtDate(rangeEnd)}`;

      statsEl.innerHTML =
        statCard(
          "dl",
          "Download",
          fmtSpd(dlMed),
          [
            ["min", fmtSpd0(dlMn)],
            ["avg", fmtSpd0(dlAvg)],
            ["max", fmtSpd0(dlMx)],
            ["last", fmtSpd0(dl[i1 - 1])],
          ],
          n,
          trLabel,
        ) +
        statCard(
          "ul",
          "Upload",
          fmtSpd(ulMed),
          [
            ["min", fmtSpd0(ulMn)],
            ["avg", fmtSpd0(ulAvg)],
            ["max", fmtSpd0(ulMx)],
            ["last", fmtSpd0(ul[i1 - 1])],
          ],
          n,
          trLabel,
        ) +
        statCard(
          "pi",
          "Ping",
          `${piMed.toFixed(1)}<span class="u">ms</span>`,
          [
            ["min", piMn.toFixed(1)],
            ["med", piMed.toFixed(1)],
            ["p95", piP95.toFixed(1)],
            ["max", piMx.toFixed(1)],
          ],
          n,
          trLabel,
        );

      // ── Legend ─────────────────────────────────────────────
      const bandLabel =
        mode === "band"
          ? ' <span style="color:var(--text3)">(m\u00e9diane + IQR)</span>'
          : "";
      document.getElementById("bwLeg").innerHTML = `
        <span><i style="background:${COL.dl}"></i>download${bandLabel}</span>
        <span><i style="background:${COL.ul}"></i>upload</span>`;
      document.getElementById("piLeg").innerHTML = `
        <span><i style="background:${COL.pi}"></i>latency${bandLabel}</span>`;

      // ── Datasets ───────────────────────────────────────────
      if (mode === "band") {
        const bMs = bucketSize();
        const dlB = bucketize(ts, dl, i0, i1, bMs);
        const ulB = bucketize(ts, ul, i0, i1, bMs);
        const piB = bucketize(ts, pi, i0, i1, bMs);

        bwChart.data.datasets = [
          ...makeBandDs(dlB, COL.dl, "download"),
          ...makeBandDs(ulB, COL.ul, "upload"),
        ];
        bwChart.options.plugins.tooltip = bandTooltipBw;

        piChart.data.datasets = makeBandDs(piB, COL.pi, "latency");
        piChart.options.plugins.tooltip = bandTooltipPi;
      } else {
        bwChart.data.datasets = [
          ...makeLineDs(ts, dl, i0, i1, COL.dl, "download", bwCtx, bwH),
          ...makeLineDs(ts, ul, i0, i1, COL.ul, "upload", bwCtx, bwH),
        ];
        bwChart.options.plugins.tooltip = {
          ...tipStyle,
          callbacks: {
            label: (c) =>
              `${c.dataset.label}: ${c.parsed.y.toFixed(1)} Mb/s`,
          },
        };

        piChart.data.datasets = makeLineDs(
          ts,
          pi,
          i0,
          i1,
          COL.pi,
          "latency",
          piCtx,
          piH,
        );
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
    bwChart.update("none");

    piChart.options.scales.x.min = rangeStart;
    piChart.options.scales.x.max = rangeEnd;
    piChart.update("none");

    document.getElementById("rangeLabel").textContent =
      `${fmtDate(rangeStart)}  \u2192  ${fmtDate(rangeEnd)}`;
    document
      .querySelectorAll(".rb")
      .forEach((b) =>
        b.classList.toggle("on", parseInt(b.dataset.hours) === currentH),
      );
    lastMode = mode;
  };

  const render = () => {
    cancelAnimationFrame(renderRAF);
    renderRAF = requestAnimationFrame(doRender);
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

  document
    .querySelectorAll(".rb")
    .forEach((b) =>
      b.addEventListener("click", () => {
        isLive = true;
        setRange(parseInt(b.dataset.hours));
      }),
    );
  document.getElementById("btnBack").addEventListener("click", () => shift(-1));
  document.getElementById("btnFwd").addEventListener("click", () => shift(1));
  document.getElementById("btnZoomIn").addEventListener("click", () => {
    const i = presets.indexOf(currentH);
    if (i > 0) setRange(presets[i - 1]);
    else if (currentH > presets[0]) setRange(presets[0]);
  });
  document.getElementById("btnZoomOut").addEventListener("click", () => {
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
  document.addEventListener("keydown", (e) => {
    if (e.key === "ArrowLeft") shift(-1);
    else if (e.key === "ArrowRight") shift(1);
    else if (e.key === "+" || e.key === "=")
      document.getElementById("btnZoomIn").click();
    else if (e.key === "-") document.getElementById("btnZoomOut").click();
  });

  doRender();
})();
