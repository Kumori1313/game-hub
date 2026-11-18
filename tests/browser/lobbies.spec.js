import { test, expect } from '@playwright/test';

async function enter(page, baseURL, name) {
  await page.goto(`${baseURL}/tic-tac-toe/`);
  await expect(page.locator('#guest-form')).toBeVisible();
  await page.getByLabel('Display name', { exact: true }).fill(name);
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await expect(page.locator('#selection')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Create lobby', exact: true })).toBeEnabled();
}

test('two guests discover, join, leave, start, refresh, and interrupt a shared match', async ({ browser, baseURL }) => {
  test.setTimeout(90000);
  const contexts = await Promise.all([0,1,2].map(() => browser.newContext()));
  const [host, guest, outsider] = await Promise.all(contexts.map(context => context.newPage()));
  const name = `Host-${Date.now().toString(36)}`;
  try {
    await enter(host,baseURL,name);
    await host.getByRole('button', { name: 'Create lobby', exact: true }).click();
    await expect(host.locator('#lobby-room')).toBeVisible();
    await expect(host.getByRole('button', { name: 'Start game', exact: true })).toBeDisabled();
    const id = new URL(host.url()).searchParams.get('room');
    expect(id).toBeTruthy();
    await enter(guest,baseURL,'<b>Guest</b>');
    const row = guest.locator(`[data-lobby-id="${id}"]`);
    await expect(row).toContainText(name, { timeout: 15000 });
    await row.getByRole('button', { name: 'Join', exact: true }).click();
    await expect(guest.locator('#lobby-room')).toBeVisible();
    await expect(guest.getByRole('button', { name: 'Start game', exact: true })).toBeHidden();
    await expect(host.locator('#room-members li')).toHaveCount(2, { timeout: 15000 });
    await expect(host.locator('#room-members b')).toHaveCount(0);
    await host.setViewportSize({ width: 1440, height: 900 });
    await host.screenshot({ path: '/tmp/game-hub-lobby.png', fullPage: true });
    await expect(host.locator('#lobby-app')).toHaveAttribute('data-presence', 'connected', { timeout: 15000 });
    await expect(guest.locator('#lobby-app')).toHaveAttribute('data-presence', 'connected', { timeout: 15000 });
    await expect(host.getByRole('button', { name: 'Start game', exact: true })).toBeEnabled({ timeout: 15000 });
    await enter(outsider,baseURL,'Observer');
    await expect(outsider.locator(`[data-lobby-id="${id}"]`).getByRole('button', { name: 'Full', exact: true })).toBeDisabled();
    await outsider.goto(`${baseURL}/tic-tac-toe/?lobby=${id}`);
    await expect(outsider.locator('#lobby-error')).toContainText('can’t enter');
    await expect(outsider.locator('#lobby-room')).toBeHidden();
    await guest.getByRole('button', { name: 'Leave lobby', exact: true }).click();
    await expect(host.locator('#room-members li')).toHaveCount(1, { timeout: 15000 });
    await expect(host.getByRole('button', { name: 'Start game', exact: true })).toBeDisabled();
    await guest.locator(`[data-lobby-id="${id}"]`).getByRole('button', { name: 'Join', exact: true }).click();
    await expect(host.getByRole('button', { name: 'Start game', exact: true })).toBeEnabled({ timeout: 15000 });
    await host.getByRole('button', { name: 'Start game', exact: true }).click();
    for (const page of [host,guest]) {
      await expect(page).toHaveURL(new RegExp(`lobby=${id}`), { timeout: 15000 });
      await expect(page.locator('#room-title')).toHaveText('Tic-Tac-Toe');
      await expect(page.locator('#room-message')).toContainText(page === host ? 'Your turn (X).' : 'Waiting for X.');
    }
    await guest.reload();
    await expect(guest.locator('#room-members li')).toHaveCount(2);
    await expect(guest.locator('#room-title')).toHaveText('Tic-Tac-Toe');
    host.on('dialog', dialog => dialog.accept());
    await host.getByRole('button', { name: 'Leave match', exact: true }).click();
    await expect(guest.locator('#room-title')).toHaveText('Match interrupted', { timeout: 15000 });
    await expect(guest.locator('#room-message')).toContainText('host left');
    await guest.getByRole('button', { name: 'Back to lobbies', exact: true }).click();
    await expect(guest.locator('#lobby-discovery')).toBeVisible();
  } finally {
    // Best-effort clean shutdown, also when an assertion fails.
    for (const page of [host,guest]) {
      try {
        page.removeAllListeners('dialog'); page.on('dialog', dialog => dialog.accept());
        if (await page.locator('#leave-lobby').isVisible()) await page.locator('#leave-lobby').click({ timeout: 2000 });
      } catch {}
    }
    await Promise.all(contexts.map(context => context.close()));
  }
});

test('waiting rooms survive another tab closing and recover offline state', async ({ browser, baseURL }) => {
  test.setTimeout(60000);
  const context = await browser.newContext({ viewport: { width: 320, height: 740 } });
  const page = await context.newPage();
  try {
    await enter(page,baseURL,`Tabs-${Date.now().toString(36)}`);
    await page.getByRole('button', { name: 'Create lobby', exact: true }).click();
    await expect(page.locator('#lobby-room')).toBeVisible();
    const roomUrl = page.url();
    const other = await context.newPage();
    await other.goto(roomUrl);
    await expect(other.locator('#room-members li')).toHaveCount(1);
    await other.close();
    await page.reload();
    await expect(page.locator('#lobby-room')).toBeVisible();
    await expect(page.locator('#room-title')).not.toHaveText('Lobby closed');
    const currentId = new URL(page.url()).searchParams.get('room');
    await page.goto(`${baseURL}/tic-tac-toe/?room=00000000-0000-4000-8000-000000000000`);
    await expect(page).toHaveURL(new RegExp(`room=${currentId}`));
    await expect(page.locator('#lobby-error')).toContainText('current lobby has been restored');
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await context.setOffline(true);
    await expect(page.locator('#selection')).toBeHidden();
    await context.setOffline(false);
    await expect(page.locator('#selection')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Leave lobby', exact: true })).toBeEnabled();
    await page.screenshot({ path: '/tmp/game-hub-lobby-mobile.png', fullPage: true });
    await page.getByRole('link', { name: 'Back to Game Hub', exact: true }).click();
    await expect(page).toHaveURL(/\/game-hub\/$/);
    await page.getByRole('link', { name: 'Open game', exact: true }).click();
    await expect(page.locator('#lobby-discovery')).toBeVisible();
    await expect(page.locator('#lobby-room')).toBeHidden();
  } finally { await context.close(); }
});
