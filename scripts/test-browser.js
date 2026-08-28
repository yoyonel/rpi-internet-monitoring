import { chromium } from 'playwright';
import fs from 'node:fs';

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium',
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
  });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });

  const errors = [];
  page.on('console', (msg) => {
    if (msg.type() === 'error') {
      errors.push(msg.text());
    }
    console.log(`[BROWSER ${msg.type().toUpperCase()}] ${msg.text()}`);
  });
  page.on('pageerror', (err) => {
    errors.push(err.message);
    console.error(`[PAGE ERROR] ${err.message}`);
  });

  const url = process.argv[2] || 'http://localhost:8080';
  console.log(`Navigating to ${url}...`);
  await page.goto(url, { waitUntil: 'networkidle', timeout: 8000 });
  await page.waitForTimeout(500);

  fs.mkdirSync('/tmp/preview-screens', { recursive: true });

  // 1. Initial view (Today or default)
  await page.screenshot({ path: '/tmp/preview-screens/01-default.png' });
  console.log('  📸 Screenshot: /tmp/preview-screens/01-default.png');

  // 2. Click 24h
  await page.click('button[data-hours="24"]');
  await page.waitForTimeout(400);
  await page.screenshot({ path: '/tmp/preview-screens/02-24h.png' });
  console.log('  📸 Screenshot: /tmp/preview-screens/02-24h.png');

  // 3. Click 2j
  await page.click('button[data-hours="48"]');
  await page.waitForTimeout(400);
  await page.screenshot({ path: '/tmp/preview-screens/03-2j.png' });
  console.log('  📸 Screenshot: /tmp/preview-screens/03-2j.png');

  // 4. Click 7j
  await page.click('button[data-hours="168"]');
  await page.waitForTimeout(400);
  await page.screenshot({ path: '/tmp/preview-screens/04-7j.png' });
  console.log('  📸 Screenshot: /tmp/preview-screens/04-7j.png');

  // 5. Click 30j
  await page.click('button[data-hours="720"]');
  await page.waitForTimeout(400);
  await page.screenshot({ path: '/tmp/preview-screens/05-30j.png' });
  console.log('  📸 Screenshot: /tmp/preview-screens/05-30j.png');

  // 6. Test Drag Zoom (Left click + drag on Bandwidth chart)
  const bwCanvas = await page.$('#bwChart');
  const box = await bwCanvas.boundingBox();
  console.log('  Testing Left Click + Drag on bwChart...');
  await page.mouse.move(box.x + box.width * 0.25, box.y + box.height * 0.5);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width * 0.65, box.y + box.height * 0.5, { steps: 10 });
  await page.mouse.up();
  await page.waitForTimeout(600);
  await page.screenshot({ path: '/tmp/preview-screens/06-after-drag-zoom.png' });
  console.log('  📸 Screenshot: /tmp/preview-screens/06-after-drag-zoom.png');

  await browser.close();

  if (errors.length > 0) {
    console.error(`\n❌ Found ${errors.length} browser errors!`);
    process.exit(1);
  }
  console.log('\n✅ All presets rendered cleanly without any browser error!');
})();
