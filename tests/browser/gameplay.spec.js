import { test, expect } from '@playwright/test';

const cell = (page, index) => page.locator(`[data-cell="${index}"]`);
async function enter(page, baseURL, name) {
  await page.goto(`${baseURL}/game-hub/`);
  await page.getByLabel('Display name', { exact: true }).fill(name);
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByRole('link', { name: 'Open game', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Create lobby', exact: true })).toBeEnabled();
}
async function startMatch(host, guest) {
  await host.getByRole('button', { name: 'Create lobby', exact: true }).click();
  await expect(host.locator('#lobby-room')).toBeVisible();
  const id = new URL(host.url()).searchParams.get('room');
  await guest.getByRole('button', { name: 'Refresh', exact: true }).click();
  await guest.locator(`[data-lobby-id="${id}"]`).getByRole('button', { name: 'Join', exact: true }).click();
  await expect(host.getByRole('button', { name: 'Start game', exact: true })).toBeEnabled({ timeout: 15000 });
  await host.getByRole('button', { name: 'Start game', exact: true }).click();
  for (const page of [host, guest]) {
    await expect(page.locator('#match-board')).toBeVisible();
    await expect(page.locator('#match-board')).toHaveAttribute('data-revision', '0');
  }
  return (await host.locator('#room-message').textContent()) === 'Your turn (X).' ? [host,guest] : [guest,host];
}
async function revision(pages, value) {
  for (const page of pages) await expect(page.locator('#match-board')).toHaveAttribute('data-revision', String(value), { timeout: 10000 });
}
async function play(host, guest, moves) {
  const [x,o] = (await host.locator('#room-message').textContent()) === 'Your turn (X).' ? [host,guest] : [guest,host];
  for (const [index, position] of moves.entries()) {
    const player = index % 2 ? o : x;
    await expect(cell(player, position)).toBeEnabled();
    await cell(player, position).focus();
    await player.keyboard.press(index % 2 ? 'Space' : 'Enter');
    await revision([host, guest], index + 1);
    for (const page of [host, guest]) await expect(cell(page, position)).toHaveText(index % 2 ? 'O' : 'X');
  }
}
async function cleanup(pages, contexts) {
  for (const page of pages) {
    try {
      page.removeAllListeners('dialog'); page.on('dialog', dialog => dialog.accept());
      if (await page.locator('#leave-lobby').isVisible()) await page.locator('#leave-lobby').click({ timeout: 2000 });
      else if (await page.locator('#back-lobbies').isVisible()) await page.locator('#back-lobbies').click({ timeout: 2000 });
    } catch {}
  }
  await Promise.all(contexts.map(context => context.close()));
}

test('two guests finish X/O wins and a draw, retain results, and start fresh from the hub', async ({ browser, baseURL }) => {
  test.setTimeout(150000);
  const contexts = await Promise.all([0, 1].map(() => browser.newContext({ viewport: { width: 390, height: 844 } })));
  const [host, guest] = await Promise.all(contexts.map(context => context.newPage()));
  try {
    await enter(host, baseURL, `Play-${Date.now().toString(36)}`);
    await enter(guest, baseURL, 'Guest');
    let [x,o] = await startMatch(host, guest);
    await expect(x.locator('#room-message')).toHaveText('Your turn (X).');
    await expect(o.locator('#match-board button:enabled')).toHaveCount(0);
    let submitted = 0;
    x.on('request', request => { if (request.url().endsWith('/rpc/submit_move')) submitted++; });
    await cell(x, 0).focus();
    await x.keyboard.press('Enter');
    await revision([x, o], 1);
    expect(submitted).toBe(1);
    await o.reload();
    await revision([o], 1);
    await expect(cell(o, 0)).toBeDisabled();
    await expect(cell(o, 0)).toHaveAccessibleName('Row 1, column 1: X');
    for (const [position, player, next] of [[3,o,2],[1,x,3],[4,o,4],[2,x,5]]) {
      await expect(cell(player, position)).toBeEnabled(); await cell(player, position).click(); await revision([x,o], next);
    }
    await expect(x.locator('#room-message')).toHaveText('You won (X).');
    await expect(o.locator('#room-message')).toHaveText('X won.');
    for (const page of [x,o]) {
      await expect(page.locator('.winning-cell')).toHaveCount(3);
      await expect(page.locator('#match-board button:enabled')).toHaveCount(0);
    }
    await host.setViewportSize({ width: 1440, height: 1000 });
    await host.screenshot({ path: '/tmp/game-hub-phase6-win-dark.png', fullPage: true });
    await guest.getByRole('button', { name: 'Back to lobbies', exact: true }).click();
    await host.reload();
    await expect(host.locator('#room-message')).toHaveText(host === x ? 'You won (X).' : 'X won.');
    await revision([host], 5);
    await host.getByRole('link', { name: 'Back to Game Hub', exact: true }).click();
    await expect(host).toHaveURL(/\/game-hub\/$/);
    await host.getByRole('link', { name: 'Open game', exact: true }).click();
    await startMatch(host, guest);
    await play(host, guest, [0,1,2,4,3,5,7,6,8]);
    for (const page of [host,guest]) {
      await expect(page.locator('#room-message')).toHaveText('Draw.');
      await expect(page.locator('.winning-cell')).toHaveCount(0);
      await expect(page.locator('#match-board button:enabled')).toHaveCount(0);
    }
    await guest.setViewportSize({ width: 320, height: 740 });
    await guest.locator('#theme-toggle').click();
    expect(await guest.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    const size = await cell(guest, 0).boundingBox();
    expect(size.width).toBeGreaterThanOrEqual(44); expect(size.height).toBeGreaterThanOrEqual(44);
    expect(Math.abs(size.width - size.height)).toBeLessThan(1);
    await guest.screenshot({ path: '/tmp/game-hub-phase6-draw-light-mobile.png', fullPage: true });
    for (const page of [host,guest]) await page.getByRole('button', { name: 'Back to lobbies', exact: true }).click();
    [x,o] = await startMatch(host, guest);
    await play(host, guest, [0,3,1,4,8,5]);
    await expect(x.locator('#room-message')).toHaveText('O won.');
    await expect(o.locator('#room-message')).toHaveText('You won (O).');
    for (const page of [host,guest]) {
      await page.getByRole('link', { name: 'Back to Game Hub', exact: true }).click();
      await expect(page).toHaveURL(/\/game-hub\/$/);
    }
  } finally { await cleanup([host,guest], contexts); }
});

test('pending, late, and lost move replies preserve confirmed state without duplicate clicks', async ({ browser, baseURL }) => {
  test.setTimeout(90000);
  const contexts = await Promise.all([0,1].map(() => browser.newContext()));
  let [host,guest] = await Promise.all(contexts.map(context => context.newPage()));
  let held;
  try {
    await enter(host, baseURL, `Recovery-${Date.now().toString(36)}`);
    await enter(guest, baseURL, 'Opponent');
    [host,guest]=await startMatch(host,guest);
    let requests = 0;
    const hold = async route => { requests++; held = { route, response: await route.fetch() }; };
    await host.route('**/rpc/submit_move', hold);
    await cell(host,0).evaluate(button => { button.click(); button.click(); });
    await expect.poll(() => Boolean(held)).toBe(true);
    await expect(host.locator('#match-board button:enabled')).toHaveCount(0);
    await expect(host.locator('#room-message')).toHaveText('Submitting move…');
    expect(requests).toBe(1);
    await revision([guest],1);
    await cell(guest,4).click();
    await revision([host,guest],2);
    await held.route.fulfill({ response: held.response }); held = null;
    await host.unroute('**/rpc/submit_move',hold);
    await expect(host.locator('#room-message')).toHaveText('Your turn (X).');
    await revision([host],2);
    // The request commits, but its reply is lost. The UI must reconcile instead of replaying it.
    let lostRequests = 0;
    const lose = async route => { lostRequests++; await route.fetch(); await route.abort('failed'); };
    await host.route('**/rpc/submit_move',lose);
    await cell(host,1).click();
    await revision([host,guest],3);
    await expect(host.locator('#room-message')).toHaveText('Waiting for O.');
    await expect(host.locator('#lobby-error')).toBeEmpty();
    expect(lostRequests).toBe(1);
    await host.unroute('**/rpc/submit_move',lose);
    await guest.context().setOffline(true);
    await expect(guest.locator('#selection')).toBeHidden();
    await guest.context().setOffline(false);
    await expect(cell(guest,2)).toBeEnabled();
    await revision([guest],3);
    await guest.reload();
    await revision([guest],3);
    await cell(guest,2).click();
    await revision([host,guest],4);
    // A request that never answers times out, unlocks after a snapshot, and is not replayed.
    let stalledRequests = 0;
    const stall = route => { stalledRequests++; };
    await host.route('**/rpc/submit_move', stall);
    await cell(host,6).click();
    await expect(host.locator('#room-message')).toHaveText('Submitting move…');
    await expect(host.locator('#room-message')).toHaveText('Your turn (X).', { timeout: 20000 });
    await revision([host,guest],4);
    expect(stalledRequests).toBe(1);
    await host.unroute('**/rpc/submit_move', stall);
    // Leaving during play ends it for the other player without awarding a result.
    host.on('dialog', dialog => dialog.accept());
    await host.getByRole('button', { name: 'Leave match', exact: true }).click();
    await expect(guest.locator('#room-title')).toHaveText('Match interrupted', { timeout: 10000 });
    await expect(guest.locator('#match-board button:enabled')).toHaveCount(0);
    await revision([guest],4);
    await expect(guest.locator('.winning-cell')).toHaveCount(0);
  } finally {
    if (held) await held.route.fulfill({ response: held.response }).catch(() => {});
    await cleanup([host,guest], contexts);
  }
});
