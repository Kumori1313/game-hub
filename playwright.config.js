import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests/browser',
  workers: 1,
  use: { browserName: process.env.E2E_BROWSER ?? 'chromium', baseURL: process.env.E2E_BASE_URL ?? 'http://127.0.0.1:4175', viewport: { width: 390, height: 844 } },
  webServer: process.env.E2E_BASE_URL ? undefined : { command: process.env.VITE_ENABLE_RELAY_ROOM === 'true' ? 'node --experimental-strip-types scripts/serve-session-test.mjs' : 'node scripts/serve-session-test.mjs', url: 'http://127.0.0.1:4175/game-hub/', reuseExistingServer: false },
});
