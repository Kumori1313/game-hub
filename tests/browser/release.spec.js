import { test, expect } from '@playwright/test';

async function enter(page, baseURL, name) {
  await page.goto(`${baseURL}/tic-tac-toe/`);
  await page.getByLabel('Display name', { exact: true }).fill(name);
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Create lobby', exact: true })).toBeEnabled();
}

test('two browsers competing for the last seat admit exactly one guest', async ({ browser, baseURL }) => {
  test.setTimeout(60000);
  const contexts = await Promise.all([0,1,2].map(() => browser.newContext()));
  const [host, ...guests] = await Promise.all(contexts.map(context => context.newPage()));
  const held = [];
  try {
    await enter(host, baseURL, `Race-${Date.now().toString(36)}`);
    await host.getByRole('button', { name: 'Create lobby', exact: true }).click();
    await expect(host.locator('#lobby-room')).toBeVisible();
    const id = new URL(host.url()).searchParams.get('room');
    for (const [index, page] of guests.entries()) {
      await enter(page, baseURL, `Contender ${index+1}`);
      await expect(page.locator(`[data-lobby-id="${id}"]`)).toBeVisible();
      await page.route('**/rpc/room_action', route => {
        if (route.request().postDataJSON()?.p_action === 'join') held.push(route);
        else return route.continue();
      });
    }
    const replies = guests.map(page => page.waitForResponse(response => response.url().endsWith('/rpc/room_action')
      && response.request().postDataJSON()?.p_action === 'join'));
    await Promise.all(guests.map(page => page.locator(`[data-lobby-id="${id}"]`).getByRole('button', { name: 'Join', exact: true }).click()));
    await expect.poll(() => held.length).toBe(2);
    await Promise.all(held.splice(0).map(route => route.continue()));
    const responses = await Promise.all(replies);
    expect(responses.filter(response => response.ok())).toHaveLength(1);
    const winner = guests[responses.findIndex(response => response.ok())];
    const loser = guests[responses.findIndex(response => !response.ok())];
    await expect(winner.locator('#room-members li')).toHaveCount(2);
    await expect(host.locator('#room-members li')).toHaveCount(2, { timeout: 15000 });
    await expect(loser.locator('#lobby-room')).toBeHidden();
    await expect(loser.locator('#lobby-error')).toContainText('full');
    await expect(loser.locator(`[data-lobby-id="${id}"]`)).toContainText('2/2');
    await expect(loser.locator(`[data-lobby-id="${id}"]`).getByRole('button', { name: 'Full', exact: true })).toBeDisabled();
    await expect(host.getByRole('button', { name: 'Start game', exact: true })).toBeEnabled();
  } finally {
    await Promise.all(held.map(route => route.abort().catch(() => {})));
    for (const page of [host,...guests]) {
      try { if (await page.locator('#leave-lobby').isVisible()) await page.locator('#leave-lobby').click({ timeout: 2000 }); } catch {}
    }
    await Promise.all(contexts.map(context => context.close()));
  }
});

test('entry and validation remain keyboard accessible at mobile and tablet widths', async ({ page }) => {
  for (const slug of ['game-hub','tic-tac-toe']) {
    for (const width of [320,768]) {
      await page.setViewportSize({ width, height: 800 });
      await page.goto(`/${slug}/`);
      await expect(page.locator('#guest-form')).toBeVisible();
      await page.keyboard.press('Tab');
      await expect(page.locator('.skip-link')).toBeFocused();
      await page.keyboard.press('Enter');
      await page.getByLabel('Display name', { exact: true }).focus();
      await page.keyboard.press('Enter');
      await expect(page.locator('#guest-error')).toHaveText('Enter a display name.');
      await expect(page.getByLabel('Display name', { exact: true })).toHaveAttribute('aria-invalid','true');
      await expect(page.getByLabel('Display name', { exact: true })).toBeFocused();
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      for (const control of ['#theme-toggle','#display-name','#save-name']) {
        const box = await page.locator(control).boundingBox();
        expect(box.height).toBeGreaterThanOrEqual(44);
      }
    }
  }
});
