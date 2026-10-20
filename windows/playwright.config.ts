import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  testMatch: ['ui.spec.ts', 'setup-ui.spec.ts', 'model-filter-ui.spec.ts', 'security-approval-ui.spec.ts'],
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  workers: 1,
  use: {
    baseURL: 'http://127.0.0.1:1420',
    viewport: { width: 1000, height: 800 },
    browserName: 'chromium',
    channel: process.env.CI ? undefined : 'chrome',
    headless: true,
    reducedMotion: 'reduce',
  },
  webServer: {
    command: 'npm run dev',
    url: 'http://127.0.0.1:1420',
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },
});
