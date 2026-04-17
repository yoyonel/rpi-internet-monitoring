import { defineConfig } from '@playwright/test';

const baseURL = process.env.E2E_BASE_URL || 'http://localhost:8080';
const isRemote = baseURL.startsWith('https://');

export default defineConfig({
  testDir: './tests',
  /* Remote GH Pages can be slow — give enough room */
  timeout: isRemote ? 60_000 : 30_000,
  retries: isRemote ? 2 : 1,
  expect: { timeout: 10_000 },
  use: {
    baseURL,
    headless: true,
    actionTimeout: 10_000,
    navigationTimeout: isRemote ? 30_000 : 15_000,
  },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
});
