import { chromium } from 'playwright';
import fs from 'node:fs';
import http from 'node:http';
import { spawn } from 'node:child_process';

function isServerUp(urlStr) {
  return new Promise((resolve) => {
    try {
      const u = new URL(urlStr);
      const req = http.get({ hostname: u.hostname, port: u.port || 80, path: '/' }, (res) => {
        resolve(res.statusCode === 200);
      });
      req.on('error', () => resolve(false));
      req.setTimeout(1000, () => {
        req.destroy();
        resolve(false);
      });
    } catch {
      resolve(false);
    }
  });
}

(async () => {
  const url = process.argv[2] || 'http://localhost:8080';
  let serverProcess = null;

  // Auto-start preview server if not running
  const up = await isServerUp(url);
  if (!up && (url.includes('localhost') || url.includes('127.0.0.1'))) {
    const port = new URL(url).port || '8080';
    console.log(`Starting local preview server on :${port}...`);
    serverProcess = spawn('bash', ['scripts/preview-dev.sh', port], {
      stdio: 'ignore',
      detached: true,
    });
    for (let i = 0; i < 30; i++) {
      await new Promise((r) => setTimeout(r, 400));
      if (await isServerUp(url)) break;
    }
  }

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

  console.log(`Navigating to ${url}...`);
  await page.goto(url, { waitUntil: 'networkidle', timeout: 12000 });
  await page.waitForTimeout(500);

  fs.mkdirSync('/tmp/preview-screens', { recursive: true });

  // 1. Initial view (Today or default)
  await page.screenshot({ path: '/tmp/preview-screens/01-default.png' });
  console.log('  📸 Screenshot: /tmp/preview-screens/01-default.png');

  // 2. Click 24h
  await page.click('.rb[data-hours="24"]');
  await page.waitForTimeout(400);
  await page.screenshot({ path: '/tmp/preview-screens/02-24h.png' });
  console.log('  📸 Screenshot: /tmp/preview-screens/02-24h.png');

  // 3. Click 2j
  await page.click('.rb[data-hours="48"]');
  await page.waitForTimeout(400);
  await page.screenshot({ path: '/tmp/preview-screens/03-2j.png' });
  console.log('  📸 Screenshot: /tmp/preview-screens/03-2j.png');

  // 4. Click 7j
  await page.click('.rb[data-hours="168"]');
  await page.waitForTimeout(400);
  await page.screenshot({ path: '/tmp/preview-screens/04-7j.png' });
  console.log('  📸 Screenshot: /tmp/preview-screens/04-7j.png');

  // 5. Click 30j
  await page.click('.rb[data-hours="720"]');
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

  // 7. Test Alerts expand
  const alertsSec = await page.$('#alertsSec');
  if (alertsSec) {
    await page.click('#alertsSec');
    await page.waitForTimeout(400);
    await page.screenshot({ path: '/tmp/preview-screens/07-alerts-open.png' });
    console.log('  📸 Screenshot: /tmp/preview-screens/07-alerts-open.png');
  }

  await browser.close();

  if (serverProcess) {
    try {
      process.kill(-serverProcess.pid);
    } catch {}
  }

  if (errors.length > 0) {
    console.error(`\n❌ Found ${errors.length} browser errors!`);
    process.exit(1);
  }
  console.log('\n✅ All presets rendered cleanly without any browser error!');
})();
