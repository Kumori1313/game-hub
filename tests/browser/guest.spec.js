import { test, expect } from '@playwright/test';

async function enter(page, name) {
  await expect(page.locator('#guest-status')).toContainText('No account');
  await page.getByLabel('Display name', { exact: true }).fill(name);
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await expect(page.locator('#identity')).toContainText(name.trim());
  await expect(page.locator('#selection')).toBeVisible();
}

async function guestId(page) {
  return page.evaluate(() => JSON.parse(localStorage.getItem('game-hub-auth'))?.user.id);
}

test('guest identity and safe display name survive game navigation, refresh, and name change', async ({ page }) => {
  await page.goto('/game-hub/');
  await enter(page, '<img src=x onerror=x>');
  await expect(page.locator('#identity img')).toHaveCount(0);
  const id = await guestId(page);
  expect(id).toBeTruthy();
  await page.getByRole('link', { name: 'Choose Tic-Tac-Toe' }).click();
  await expect(page).toHaveURL(/\/tic-tac-toe\/$/);
  await expect(page.locator('#selection')).toBeVisible();
  expect(await guestId(page)).toBe(id);
  await page.reload();
  await expect(page.locator('#selection')).toBeVisible();
  await page.getByRole('button', { name: 'Change name' }).click();
  await page.getByLabel('Display name', { exact: true }).fill('Sam 🦊');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await expect(page.locator('#guest-name')).toHaveText('Sam 🦊');
  expect(await guestId(page)).toBe(id);
  await page.getByRole('link', { name: 'Back to Game Hub' }).click();
  await expect(page.locator('#guest-name')).toHaveText('Sam 🦊');
  expect(await guestId(page)).toBe(id);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test('validation, network failure, retry, offline recovery, and cleared identity', async ({ page, context }) => {
  await page.goto('/game-hub/');
  await expect(page.locator('#guest-status')).toContainText('No account');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await expect(page.locator('#guest-error')).toHaveText('Enter a display name.');
  await page.getByLabel('Display name', { exact: true }).fill('a'.repeat(25));
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await expect(page.locator('#guest-error')).toContainText('24 characters');
  await page.getByLabel('Display name', { exact: true }).fill('Alex');
  await page.route('**/auth/v1/signup*', route => route.fulfill({ status: 503, contentType: 'application/json', body: '{"msg":"Unavailable"}' }));
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await expect(page.locator('#guest-error')).toContainText('couldn’t save');
  await expect(page.getByLabel('Display name', { exact: true })).toHaveValue('Alex');
  await page.getByRole('button', { name: 'Retry connection' }).click();
  await expect(page.getByLabel('Display name', { exact: true })).toHaveValue('Alex');
  await page.unroute('**/auth/v1/signup*');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await expect(page.locator('#selection')).toBeVisible();
  await context.setOffline(true);
  await expect(page.locator('#guest-error')).toContainText('Reconnect');
  await expect(page.locator('#selection')).toBeHidden();
  await context.setOffline(false);
  await expect(page.locator('#selection')).toBeVisible();
  await page.evaluate(() => localStorage.clear());
  await page.goto('/tic-tac-toe/');
  await expect(page.locator('#guest-form')).toBeVisible();
  await expect(page.locator('#selection')).toBeHidden();
  await expect(page.locator('#guest-status')).toContainText('Enter a name');
});

test('independent browsers can share a name without sharing an identity', async ({ browser, baseURL }) => {
  const first = await browser.newContext();
  const second = await browser.newContext();
  for (const context of [first, second]) {
    const page = await context.newPage();
    await page.goto(`${baseURL}/game-hub/`);
    await enter(page, 'Same name');
  }
  expect(await guestId(first.pages()[0])).not.toBe(await guestId(second.pages()[0]));
  await first.close();
  await second.close();
});

test('keyboard entry works at 320px and exposes the ready state accessibly', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 740 });
  await page.goto('/game-hub/');
  await expect(page.locator('#guest-form')).toBeVisible();
  await page.keyboard.press('Tab');
  await expect(page.getByLabel('Display name', { exact: true })).toBeFocused();
  await page.keyboard.type('Keyboard guest');
  await page.keyboard.press('Enter');
  await expect(page.getByRole('link', { name: 'Choose Tic-Tac-Toe' })).toBeFocused();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: '/tmp/game-hub-phase3.png', fullPage: true });
  await page.keyboard.press('Enter');
  await expect(page.locator('#selection')).toBeVisible();
  await page.screenshot({ path: '/tmp/tic-tac-toe-phase3.png', fullPage: true });
});
