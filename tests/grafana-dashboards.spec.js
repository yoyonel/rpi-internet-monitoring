// @ts-check
import { test, expect } from '@playwright/test';

const GRAFANA = process.env.GRAFANA_URL || 'http://localhost:3000';
const USER = process.env.GRAFANA_USER || 'admin';
const PASS = process.env.GRAFANA_PASS || 'simpass';

/**
 * Dashboard pairs: InfluxDB (reference) ↔ VictoriaMetrics (migration target).
 * Both must show the same data when running in dual-write mode.
 */
const DASHBOARD_PAIRS = [
  {
    name: 'Speedtest',
    influx: { uid: 'speedtest-dashboard', panels: 5 },
    vm: { uid: 'speedtest-vm-dashboard', panels: 5 },
  },
  {
    name: 'System Metrics',
    influx: { uid: 'system-metrics-dashboard', panels: 14 },
    vm: { uid: 'system-metrics-vm-dashboard', panels: 14 },
  },
  {
    name: 'Docker Containers',
    influx: { uid: 'rpi-docker-dashboard', panels: 12 },
    vm: { uid: 'rpi-docker-vm-dashboard', panels: 12 },
  },
  {
    name: 'RPi Alerts',
    influx: { uid: 'rpi-alerts-dashboard', panels: 12 },
    vm: { uid: 'rpi-alerts-vm-dashboard', panels: 12 },
  },
];

const AUTH = `Basic ${Buffer.from(`${USER}:${PASS}`).toString('base64')}`;
const HEADERS = { Authorization: AUTH };

/** Navigate to a dashboard with a fixed time window */
function dashUrl(uid) {
  return `${GRAFANA}/d/${uid}?orgId=1&from=now-1h&to=now&timezone=browser`;
}

/** Wait for Grafana panels to finish loading */
async function waitForPanelsLoaded(page) {
  await page.waitForLoadState('networkidle');
  // Give Grafana extra time for canvas rendering
  await page.waitForTimeout(3000);
}

/** Login to Grafana */
async function login(page) {
  await page.goto(`${GRAFANA}/login`);
  await page.fill('input[name="user"]', USER);
  await page.fill('input[name="password"]', PASS);
  await page.click('button[type="submit"]');
  await page.waitForURL('**/**');
}

/**
 * Capture a full-page screenshot of a dashboard.
 * Hides the Grafana header/nav to reduce visual noise.
 */
async function screenshotDashboard(page, uid, filename) {
  await page.goto(dashUrl(uid));
  await waitForPanelsLoaded(page);

  // Hide Grafana chrome (top nav, sidenav) for cleaner comparison
  await page.addStyleTag({
    content: `
      nav, .main-view header, [data-testid="top-nav"], 
      [class*="NavToolbar"], [class*="sidemenu"] { display: none !important; }
      .main-view { padding-top: 0 !important; margin-left: 0 !important; }
    `,
  });
  await page.waitForTimeout(500);

  await page.screenshot({
    path: `test-results/${filename}`,
    fullPage: true,
  });
}

/**
 * Count panel errors and "No data" indicators on the current page.
 */
async function countPanelIssues(page) {
  const errors = await page
    .locator(
      '[data-testid*="Panel status error"], .panel-info-corner--error, [aria-label*="Panel error"]',
    )
    .count();

  const noData = await page.locator('text="No data"').count();

  return { errors, noData };
}

// ── API-level tests (fast, no browser rendering) ─────────────

test.describe('Grafana API checks', () => {
  test('VM datasource is reachable', async ({ request }) => {
    const resp = await request.get(`${GRAFANA}/api/datasources/uid/victoriametrics`, {
      headers: HEADERS,
    });
    expect(resp.ok(), 'VM datasource not found — is the stack running?').toBe(true);
    const ds = await resp.json();
    expect(ds.type).toBe('prometheus');
  });

  test('all 8 dashboards are provisioned', async ({ request }) => {
    const resp = await request.get(`${GRAFANA}/api/search?type=dash-db`, {
      headers: HEADERS,
    });
    expect(resp.ok()).toBe(true);
    const dashboards = await resp.json();
    const uids = dashboards.map((d) => d.uid);
    for (const pair of DASHBOARD_PAIRS) {
      expect(uids, `Missing InfluxDB dashboard: ${pair.influx.uid}`).toContain(pair.influx.uid);
      expect(uids, `Missing VM dashboard: ${pair.vm.uid}`).toContain(pair.vm.uid);
    }
  });

  test('VM datasource returns metrics', async ({ request }) => {
    // Query VM directly to check it has data
    const resp = await request.get(
      'http://localhost:8428/api/v1/query?query=count({__name__!=""})',
      { timeout: 10_000 },
    );
    expect(resp.ok()).toBe(true);
    const data = await resp.json();
    const count = parseInt(data?.data?.result?.[0]?.value?.[1] || '0', 10);
    expect(count, 'VictoriaMetrics has no metrics — dual-write may not be active').toBeGreaterThan(
      0,
    );
  });
});

// ── Visual comparison: screenshot InfluxDB vs VM dashboards ──

test.describe('Dashboard visual comparison', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  for (const pair of DASHBOARD_PAIRS) {
    test(`${pair.name} — VM dashboard renders without errors`, async ({ page }) => {
      // Screenshot VM dashboard
      await screenshotDashboard(
        page,
        pair.vm.uid,
        `vm-${pair.name.toLowerCase().replace(/\s+/g, '-')}.png`,
      );
      const vmIssues = await countPanelIssues(page);

      // Check no errors on VM dashboard
      expect(vmIssues.errors, `VM ${pair.name}: ${vmIssues.errors} panel error(s)`).toBe(0);

      // Screenshot InfluxDB dashboard (reference)
      await screenshotDashboard(
        page,
        pair.influx.uid,
        `influx-${pair.name.toLowerCase().replace(/\s+/g, '-')}.png`,
      );
      const influxIssues = await countPanelIssues(page);

      // VM should not have MORE "No data" panels than InfluxDB
      expect(
        vmIssues.noData,
        `VM ${pair.name} has ${vmIssues.noData} "No data" vs InfluxDB ${influxIssues.noData}`,
      ).toBeLessThanOrEqual(influxIssues.noData + 1); // +1 tolerance for alertlist

      console.log(
        `  ${pair.name}: InfluxDB(errors=${influxIssues.errors}, noData=${influxIssues.noData}) vs VM(errors=${vmIssues.errors}, noData=${vmIssues.noData})`,
      );
    });
  }
});
