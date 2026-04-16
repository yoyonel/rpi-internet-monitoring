import { test, expect } from '@playwright/test';

// Collect all JS console errors during each test
let consoleErrors;
test.beforeEach(async ({ page }) => {
  consoleErrors = [];
  page.on('pageerror', (err) => consoleErrors.push(err.message));
  await page.goto('/');
});

// ── 1. Page loads without JS errors ─────────────────────────
test('no JavaScript errors in console', async () => {
  expect(consoleErrors).toEqual([]);
});

// ── 2. Data is parsed and stats are rendered ────────────────
test('stats cards display values', async ({ page }) => {
  const statsRow = page.locator('#statsRow');

  // 3 stat cards: Download, Upload, Ping
  const cards = statsRow.locator('.stat');
  await expect(cards).toHaveCount(3);

  // Each card has a non-empty headline value
  for (const card of await cards.all()) {
    const val = card.locator('.v');
    await expect(val).not.toBeEmpty();
    // Value should contain a number (e.g. "145.3 Mbps" or "12.5 ms")
    await expect(val).toHaveText(/\d/);
  }
});

// ── 3. Charts are rendered with data ────────────────────────
test('bandwidth chart has data', async ({ page }) => {
  const dataLen = await page.evaluate(() => {
    const chart = Chart.getChart('bwChart');
    return chart?.data?.datasets?.[0]?.data?.length ?? 0;
  });
  expect(dataLen).toBeGreaterThan(0);
});

test('ping chart has data', async ({ page }) => {
  const dataLen = await page.evaluate(() => {
    const chart = Chart.getChart('piChart');
    return chart?.data?.datasets?.[0]?.data?.length ?? 0;
  });
  expect(dataLen).toBeGreaterThan(0);
});

// ── 4. Alerts section is populated ──────────────────────────
test('alerts are displayed', async ({ page }) => {
  const alertsSec = page.locator('#alertsSec');
  // Section should be visible (not display:none) when alerts exist
  await expect(alertsSec).toBeVisible();

  const rows = alertsSec.locator('.al-row');
  const count = await rows.count();
  expect(count).toBeGreaterThan(0);

  // Each alert row has a name and a badge
  for (const row of await rows.all()) {
    await expect(row.locator('.al-name')).not.toBeEmpty();
    await expect(row.locator('.al-badge')).not.toBeEmpty();
  }
});

// ── 5. Time range buttons work ──────────────────────────────
test('time range buttons update the view', async ({ page }) => {
  const rangeLabel = page.locator('#rangeLabel');
  const initialText = await rangeLabel.textContent();

  // Click "7j" button
  await page.click('.rb[data-hours="168"]');
  const newText = await rangeLabel.textContent();

  expect(newText).not.toBe(initialText);
});

// ── 6. No template placeholders left ────────────────────────
test('no unreplaced template placeholders', async ({ page }) => {
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

// ── 7. Data point count is reasonable ───────────────────────
test('data contains a reasonable number of points', async ({ page }) => {
  const count = await page.evaluate(() => {
    return RAW_DATA?.results?.[0]?.series?.[0]?.values?.length ?? 0;
  });
  // Expect at least 100 data points (10 min intervals × 24h = 144/day)
  expect(count).toBeGreaterThan(100);
});
