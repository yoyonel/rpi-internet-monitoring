import { defineConfig } from '@playwright/test';
import fs from 'node:fs';

const baseURL = process.env.E2E_BASE_URL || 'http://localhost:8080';
const isRemote = baseURL.startsWith('https://');
const chromiumPath =
  process.env.CHROMIUM_PATH ||
  (fs.existsSync('/usr/bin/chromium')
    ? '/usr/bin/chromium'
    : fs.existsSync('/usr/bin/google-chrome')
      ? '/usr/bin/google-chrome'
      : undefined);

export default defineConfig({
  testDir: './tests',
  testMatch: process.env.PLAYWRIGHT_TEST_MATCH || '**/e2e.spec.js',
  /* Remote GH Pages can be slow — give enough room */
  timeout: isRemote ? 60_000 : 30_000,
  retries: isRemote ? 2 : 1,
  expect: { timeout: 10_000 },
  use: {
    baseURL,
    headless: true,
    actionTimeout: isRemote ? 25_000 : 10_000,
    navigationTimeout: isRemote ? 30_000 : 15_000,
    launchOptions: chromiumPath
      ? { executablePath: chromiumPath, args: ['--no-sandbox'] }
      : undefined,
  },
  webServer: isRemote
    ? undefined
    : {
        command: `bash scripts/preview-dev.sh ${new URL(baseURL).port || 8080}`,
        url: baseURL,
        reuseExistingServer: !process.env.CI,
        timeout: 20_000,
      },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
});
