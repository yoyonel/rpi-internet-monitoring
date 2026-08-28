// ── Sync status indicator (nav bar dot) ─────────────────────
import { data } from './state.js';

export const initSyncStatus = () => {
  const dot = document.getElementById('syncDot');
  if (!dot) return;

  const lastTs = data.LEN > 0 ? data.ts[data.LEN - 1] : null;
  const timeEl = document.querySelector('nav .meta time[datetime]');
  const fallbackDate = timeEl ? new Date(timeEl.getAttribute('datetime')).getTime() : Date.now();
  const sampleTime = lastTs || fallbackDate;

  // Allow simulating staleness via ?simAge=<minutes> (dev only)
  const simAge = new URLSearchParams(window.location.search).get('simAge');
  const ageMin = simAge !== null ? Number(simAge) : (Date.now() - sampleTime) / 60000;

  if (ageMin < 15) {
    dot.className = 'sync-dot sync-ok';
    dot.setAttribute('variant', 'success');
    dot.title = 'Synchronisation OK (< 15 min)';
  } else if (ageMin < 30) {
    dot.className = 'sync-dot sync-warn';
    dot.setAttribute('variant', 'warning');
    dot.title = `Synchronisation dégradée (${Math.round(ageMin)} min)`;
  } else {
    dot.className = 'sync-dot sync-err';
    dot.setAttribute('variant', 'danger');
    const hours = Math.floor(ageMin / 60);
    const days = Math.floor(hours / 24);
    const ageStr = days > 0 ? `${days}j ${hours % 24}h` : `${hours}h`;
    dot.title = `Données obsolètes (dernière mesure il y a ${ageStr})`;
  }
};
