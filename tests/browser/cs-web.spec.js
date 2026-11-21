import { expect, test } from '@playwright/test';

test.skip(process.env.TEST_CS_WEB !== 'true', 'Requires the Counter-Attack Web preview on its own origin.');

test('two Game Hub guests launch the external game and synchronize a peer purchase', async ({ browser, baseURL }) => {
  test.setTimeout(120000);
  const [hostContext, guestContext] = await Promise.all([
    browser.newContext({ viewport: { width: 1024, height: 720 } }),
    browser.newContext({ viewport: { width: 1024, height: 720 } }),
  ]);
  const host = await hostContext.newPage();
  const guest = await guestContext.newPage();
  async function enter(page, name) {
    await page.goto(baseURL + '/game-hub/');
    await page.getByLabel('Display name').fill(name);
    await page.getByRole('button', { name: 'Continue', exact: true }).click();
    await page.getByRole('link', { name: 'Open Counter-Attack Web lobbies' }).click();
    await expect(page.getByRole('button', { name: 'Create code-only lobby' })).toBeVisible();
  }
  async function openMatch(page) {
    const popup = page.waitForEvent('popup');
    await page.getByRole('button', { name: 'Open match', exact: true }).click();
    return popup;
  }

  try {
    await enter(host, 'CS Web Host');
    await enter(guest, 'CS Web Guest');
    await host.getByRole('button', { name: 'Create code-only lobby' }).click();
    const invite = host.locator('#cs-invite');
    await expect(invite).toBeVisible();
    await guest.getByLabel('Room code').fill((await invite.textContent()).replace('Room code: ', ''));
    await guest.getByRole('button', { name: 'Join with code' }).click();
    await expect(host.getByRole('button', { name: 'Start match' })).toBeEnabled({ timeout: 15000 });
    await host.getByRole('button', { name: 'Start match' }).click();

    const [gameHost, gameGuest] = await Promise.all([openMatch(host), openMatch(guest)]);
    for (const [page, game] of [[host, gameHost], [guest, gameGuest]]) {
      await game.waitForURL(url => url.origin !== new URL(page.url()).origin);
      await expect(game.getByLabel('First-person game view')).toBeVisible({ timeout: 35000 });
      await expect(game.locator('.csw-hud')).toHaveAttribute('data-phase', /freeze|live/, { timeout: 35000 });
      expect(await game.evaluate(() => localStorage.getItem('game-hub-auth'))).toBeNull();
    }
    await gameGuest.keyboard.press('b');
    await gameGuest.getByRole('button', { name: '6 Equipment' }).click();
    await gameGuest.locator('[data-action="buy-kevlar"]').click({ timeout: 10000 });
    await expect(gameGuest.locator('[data-ui="cash"]')).toHaveText('$150', { timeout: 12000 });
    const gameUrl = gameGuest.url();
    await gameGuest.reload();
    await expect(gameGuest.locator('[data-ui="cash"]')).toHaveText('$150', { timeout: 35000 });
    expect(gameGuest.url()).toBe(gameUrl);

    await host.getByRole('button', { name: 'Leave lobby' }).click();
    await expect(gameGuest.getByRole('status').filter({ hasText: 'lobby has ended' })).toBeVisible({ timeout: 15000 });
    await gameGuest.getByRole('link', { name: 'Back to Game Hub' }).click();
    await expect(gameGuest.getByRole('button', { name: 'Create public lobby' })).toBeVisible();
  } finally {
    await Promise.all([hostContext.close(), guestContext.close()]);
  }
});
