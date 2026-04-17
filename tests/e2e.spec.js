import { test, expect } from '@playwright/test';

const BASE = (process.env.E2E_BASE_URL || 'http://localhost:8080').replace(/\/+$/, '') + '/';

/**
 * Wait until the app has finished rendering (stats cards + charts).
 * Uses a generous timeout to survive slow networks (GH Pages CDN).
 */
async function waitForAppReady(page) {
  await page.waitForFunction(
    () =>
      document.querySelector('#statsRow .stat .v')?.textContent?.trim() &&
      (Chart.getChart('bwChart')?.data?.datasets?.[0]?.data?.length ?? 0) > 0,
    { timeout: 25_000 },
  );
}

/**
 * Navigate to the app and wait for full hydration.
 * Uses 'commit' navigation (faster first paint) + explicit JS readiness wait.
 */
async function gotoAndWait(page) {
  await page.goto(BASE, { waitUntil: 'commit' });
  await waitForAppReady(page);
}

// ═════════════════════════════════════════════════════════════
// Read-only checks — share a SINGLE page load (biggest speed win)
// ═════════════════════════════════════════════════════════════
test.describe('read-only checks', () => {
  test.describe.configure({ mode: 'serial' });

  /** @type {import('@playwright/test').Page} */
  let page;
  const consoleErrors = [];

  test.beforeAll(async ({ browser }) => {
    page = await browser.newPage();
    page.on('pageerror', (err) => consoleErrors.push(err.message));
    await gotoAndWait(page);
  });

  test.afterAll(async () => {
    await page?.close();
  });

  // ── 1. Page loads without JS errors ─────────────────────────
  test('no JavaScript errors in console', async () => {
    expect(consoleErrors).toEqual([]);
  });

  // ── 2. Data is parsed and stats are rendered ────────────────
  test('stats cards display values', async () => {
    const cards = page.locator('#statsRow .stat');
    await expect(cards).toHaveCount(3);

    for (const card of await cards.all()) {
      const val = card.locator('.v');
      await expect(val).not.toBeEmpty();
      await expect(val).toHaveText(/\d/);
    }
  });

  // ── 3. Charts are rendered with data ────────────────────────
  test('bandwidth chart has data', async () => {
    const dataLen = await page.evaluate(() => {
      const chart = Chart.getChart('bwChart');
      return chart?.data?.datasets?.[0]?.data?.length ?? 0;
    });
    expect(dataLen).toBeGreaterThan(0);
  });

  test('ping chart has data', async () => {
    const dataLen = await page.evaluate(() => {
      const chart = Chart.getChart('piChart');
      return chart?.data?.datasets?.[0]?.data?.length ?? 0;
    });
    expect(dataLen).toBeGreaterThan(0);
  });

  // ── 4. Alerts section is populated ──────────────────────────
  test('alerts are displayed', async () => {
    const alertsSec = page.locator('#alertsSec');
    await expect(alertsSec).toBeVisible();

    const rows = alertsSec.locator('.al-row');
    expect(await rows.count()).toBeGreaterThan(0);

    for (const row of await rows.all()) {
      await expect(row.locator('.al-name')).not.toBeEmpty();
      await expect(row.locator('.al-badge')).not.toBeEmpty();
    }
  });

  // ── 5. No template placeholders left ────────────────────────
  test('no unreplaced template placeholders', async () => {
    const html = await page.content();
    for (const token of [
      '__SPEEDTEST_DATA__',
      '__ALERTS_DATA__',
      '__LAST_UPDATE__',
      '__GENERATED_AT__',
    ]) {
      expect(html).not.toContain(token);
    }
  });

  // ── 6. Data point count is reasonable ───────────────────────
  test('data contains a reasonable number of points', async () => {
    const count = await page.evaluate(async () => {
      const resp = await fetch('data.json');
      const data = await resp.json();
      return data?.results?.[0]?.series?.[0]?.values?.length ?? 0;
    });
    expect(count).toBeGreaterThan(100);
  });

  // ── 7. Drag-to-zoom plugin is loaded and configured ─────────
  test('drag-to-zoom plugin is configured on charts', async () => {
    const config = await page.evaluate(() => {
      const bw = Chart.getChart('bwChart');
      const pi = Chart.getChart('piChart');
      return {
        bwDrag: bw?.options?.plugins?.zoom?.zoom?.drag?.enabled,
        piDrag: pi?.options?.plugins?.zoom?.zoom?.drag?.enabled,
        bwMode: bw?.options?.plugins?.zoom?.zoom?.mode,
        piMode: pi?.options?.plugins?.zoom?.zoom?.mode,
        hasZoomFn: typeof bw?.zoom === 'function',
        hasResetFn: typeof bw?.resetZoom === 'function',
      };
    });
    expect(config.bwDrag).toBe(true);
    expect(config.piDrag).toBe(true);
    expect(config.bwMode).toBe('x');
    expect(config.piMode).toBe('x');
    expect(config.hasZoomFn).toBe(true);
    expect(config.hasResetFn).toBe(true);
  });

  // ── 8. Capture screenshot for PR comment ───────────────────
  test('capture preview screenshot', async () => {
    // Wait for Chart.js animations to settle (default 1s)
    await page.waitForFunction(
      () => !Chart.getChart('bwChart')?.animating && !Chart.getChart('piChart')?.animating,
      { timeout: 5_000 },
    );
    await page.screenshot({
      path: 'test-results/preview.png',
      fullPage: true,
    });
  });
});

// ═════════════════════════════════════════════════════════════
// Interactive tests — share a second page, run in serial order
// ═════════════════════════════════════════════════════════════
test.describe('interactive', () => {
  test.describe.configure({ mode: 'serial' });

  /** @type {import('@playwright/test').Page} */
  let page;

  test.beforeAll(async ({ browser }) => {
    page = await browser.newPage();
    await gotoAndWait(page);
  });

  test.afterAll(async () => {
    await page?.close();
  });

  // ── 9. Time range buttons work ──────────────────────────────
  test('time range buttons update the view', async () => {
    const rangeLabel = page.locator('#rangeLabel');
    const initialText = await rangeLabel.textContent();

    await page.locator('.rb[data-hours="6"]').click();
    await expect(rangeLabel).not.toHaveText(initialText);
  });

  // ── 10. Double-click on chart resets to default 48 h view ────
  test('double-click on chart resets to live view', async () => {
    // Ensure we're on 6h (may already be from previous test)
    await page.locator('.rb[data-hours="6"]').click();
    await expect(page.locator('.rb[data-hours="6"]')).toHaveClass(/on/);

    await page.locator('#bwChart').dblclick();
    await expect(page.locator('.rb[data-hours="48"]')).toHaveClass(/on/);
  });

  // ── 11. Time range picker opens and has content ─────────────
  test('time range picker opens with calendar and presets', async () => {
    const picker = page.locator('#trPicker');
    // Ensure picker is closed (may have leaked from previous test)
    if (await picker.isVisible()) {
      await page.keyboard.press('Escape');
      await expect(picker).toBeHidden();
    }

    await page.locator('#rangeLabelBtn').click();
    await expect(picker).toBeVisible();

    const calDays = picker.locator('.tr-cal td button');
    expect(await calDays.count()).toBeGreaterThan(20);

    const relBtns = picker.locator('.tr-rel button');
    expect(await relBtns.count()).toBeGreaterThanOrEqual(10);

    await expect(page.locator('#trFrom')).toBeVisible();
    await expect(page.locator('#trTo')).toBeVisible();

    const rangeLabel = page.locator('#rangeLabel');
    const initialText = await rangeLabel.textContent();
    await relBtns.filter({ hasText: '6 heures' }).click();
    await expect(picker).toBeHidden();
    await expect(rangeLabel).not.toHaveText(initialText);
  });
});
