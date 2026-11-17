import { test, expect } from '@playwright/test';

test('browser policy blocks unapproved inline scripts while preserving theme initialization', async ({ page }) => {
  for (const slug of ['game-hub','tic-tac-toe']) {
    await page.goto(`/${slug}/`);
    await expect(page.locator('meta[http-equiv="Content-Security-Policy"]')).toHaveCount(1);
    await page.evaluate(() => {
      window.policyTestExecuted = false;
      const script=document.createElement('script');
      script.textContent='window.policyTestExecuted = true;';
      document.head.append(script);
    });
    expect(await page.evaluate(() => window.policyTestExecuted)).toBe(false);
    await page.locator('#theme-toggle').click();
    const selected=await page.locator('html').getAttribute('data-theme');
    await page.reload();
    await expect(page.locator('html')).toHaveAttribute('data-theme',selected);
    await expect(page.locator('#guest-form')).toBeVisible();
  }
});

test('ended-session responses return the guest to entry without retaining stale credentials', async ({ page }) => {
  await page.route('**/rest/v1/rpc/lobby_action', route => route.fulfill({
    status: 401, contentType: 'application/json',
    body: JSON.stringify({ code: 'PT401', message: 'Your session ended. Sign in again.' }),
  }));
  await page.goto('/tic-tac-toe/');
  await page.getByLabel('Display name', { exact: true }).fill('Session check');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await expect(page.locator('#guest-error')).toHaveText('Your session ended. Enter your name again.');
  await expect(page.locator('#guest-form')).toBeVisible();
  await expect(page.locator('#selection')).toBeHidden();
  expect(await page.evaluate(() => localStorage.getItem('game-hub-auth'))).toBeNull();
});
