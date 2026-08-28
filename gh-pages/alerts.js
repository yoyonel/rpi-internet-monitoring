// ── Alerts panel (RPi health alerts from Grafana) ───────────
// Self-contained: receives alerts JSON, renders to #alertsList.

/** Escape HTML to prevent XSS from alert data */
const esc = (s) =>
  String(s).replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );

/** Convert m°C to °C in alert summaries and remove duplicate thresholds */
const fixTemp = (s) => {
  if (!s) return '';
  let r = s.replace(/(\d+)\s*m°C/g, (_, v) => (parseInt(v) / 1000).toFixed(2) + ' °C');
  r = r.replace(/(\d+\.?\d*\s*°C)\s*\/\s*\d+\.?\d*\s*°C/g, '$1');
  return r;
};

/** Format lastEvaluation timestamp */
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

export const renderAlerts = (ALERTS) => {
  // Support both legacy array format and new {alerts, lastEvaluation} format
  const alertsArr = Array.isArray(ALERTS) ? ALERTS : ALERTS?.alerts;
  const lastEval = Array.isArray(ALERTS) ? null : ALERTS?.lastEvaluation;

  if (!Array.isArray(alertsArr) || !alertsArr.length) {
    document.getElementById('alertsSec').style.display = 'none';
    return;
  }

  const evalStr = fmtEval(lastEval);
  const evalHtml = evalStr
    ? `<div class="al-eval">Derni\u00e8re \u00e9valuation\u00a0: <time>${evalStr}</time></div>`
    : '';

  const nFiring = alertsArr.filter((a) => a.state === 'firing').length;
  const nPending = alertsArr.filter((a) => a.state === 'pending').length;
  const sumBadge = document.getElementById('alertsSummaryBadge');
  if (sumBadge) {
    if (nFiring > 0) {
      sumBadge.innerHTML = `<wa-badge variant="danger">${nFiring} actif${nFiring > 1 ? 's' : ''}</wa-badge>`;
    } else if (nPending > 0) {
      sumBadge.innerHTML = `<wa-badge variant="warning">${nPending} en attente</wa-badge>`;
    } else {
      sumBadge.innerHTML = `<wa-badge variant="success">OK</wa-badge>`;
    }
  }

  document.getElementById('alertsList').innerHTML =
    evalHtml +
    alertsArr
      .map((a) => {
        const variant =
          a.state === 'firing' ? 'danger' : a.state === 'pending' ? 'warning' : 'success';
        const iconName =
          a.state === 'firing'
            ? 'circle-xmark'
            : a.state === 'pending'
              ? 'triangle-exclamation'
              : 'circle-check';
        const label = a.state === 'inactive' ? 'ok' : a.state;
        return `<div class="al-row">
      <span class="al-icon"><wa-icon name="${iconName}"></wa-icon></span>
      <span class="al-name">${esc(a.name)}</span>
      <span class="al-sum">${esc(fixTemp(a.summary))}</span>
      <wa-badge class="al-badge" variant="${variant}">${label}</wa-badge>
    </div>`;
      })
      .join('');
};
