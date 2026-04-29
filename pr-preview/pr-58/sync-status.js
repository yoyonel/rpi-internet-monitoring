// ── Sync status indicator (nav bar dot) ─────────────────────
// Self-contained: reads DOM once at load, no shared state needed.

export const initSyncStatus = () => {
  const dot = document.getElementById('syncDot');
  const timeEl = document.querySelector('nav .meta time[datetime]');
  if (!dot || !timeEl) return;

  const iso = timeEl.getAttribute('datetime');
  const updated = new Date(iso);
  if (isNaN(updated)) return;

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
};
