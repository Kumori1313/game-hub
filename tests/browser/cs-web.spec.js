import { expect, test } from '@playwright/test';

test.skip(process.env.TEST_CS_WEB !== 'true', 'Requires the Counter-Attack Web preview on its own origin.');

for (const relay of [false, true]) {
  test(`Counter-Attack Web synchronizes gameplay over ${relay ? 'the fallback relay' : 'a direct connection with late ICE candidates'}`, async ({ browser, baseURL }) => {
    test.setTimeout(160000);
    const [hostContext, guestContext] = await Promise.all([
      browser.newContext({
        viewport: { width: 850, height: 650 },
        ...(relay ? { hasTouch: true, isMobile: true } : {}),
      }),
      browser.newContext({ viewport: { width: 850, height: 650 } }),
    ]);

    for (const context of [hostContext, guestContext]) {
      await context.addInitScript(forceRelay => {
        const observe = (packet, transport) => {
          if (packet?.type === 'frame' && packet.frame?.players) {
            window.matchFrame = packet.frame;
            window.matchTransport = transport;
          }
        };
        window.addEventListener('message', event => {
          if (event.data?.type !== 'cs-web-connect') return;
          event.ports[0].addEventListener('message', ({ data }) => {
            if (data?.type === 'relay-packet') observe(data.envelope.packet, 'relay');
          });
        });
        const Peer = window.RTCPeerConnection;
        window.RTCPeerConnection = class extends Peer {
          constructor(...args) {
            if (forceRelay) throw new Error('Direct transport disabled by the test');
            super(...args);
            this.addEventListener('datachannel', ({ channel }) => {
              channel.addEventListener('message', ({ data }) => observe(JSON.parse(data), 'direct'));
            });
          }

          get localDescription() {
            const description = super.localDescription;
            if (!description) return description;
            // Make late events the only way the other browser learns candidates.
            return { type: description.type, sdp: description.sdp.replace(/^a=(?:candidate:|end-of-candidates).*\r?\n/gm, '') };
          }

          set onicecandidate(handler) {
            super.onicecandidate = event => setTimeout(() => handler?.call(this, event), 4500);
          }
        };
      }, relay);
    }

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
      await page.getByRole('button', { name: 'Open match', exact: true }).click();
      const iframe = await page.locator('#cs-frame iframe').elementHandle();
      return iframe.contentFrame();
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
        await expect(game.getByLabel('First-person game view')).toBeVisible({ timeout: 45000 });
        await expect(game.locator('.csw-hud')).toHaveAttribute('data-phase', /freeze|live/, { timeout: 45000 });
        expect(await game.evaluate(() => localStorage.getItem('game-hub-auth'))).toBeNull();
      }

      await expect.poll(() => gameGuest.evaluate(() => window.matchTransport)).toBe(relay ? 'relay' : 'direct');
      if (relay) await gameHost.locator('.csw-touch').getByRole('button', { name: 'Buy' }).tap();
      else await gameHost.getByLabel('First-person game view').press('b');
      await gameHost.locator('[data-action="buy-deagle"]').click();
      await expect.poll(() => gameGuest.evaluate(() => window.matchFrame?.players[0].weapon)).toBe('deagle');

      await gameGuest.getByLabel('First-person game view').press('b');
      await gameGuest.getByRole('button', { name: '6 Equipment' }).click();
      await gameGuest.locator('[data-action="buy-kevlar"]').click();
      await expect(gameGuest.locator('[data-ui="cash"]')).toHaveText('$150', { timeout: 12000 });
      await gameGuest.evaluate(() => location.reload());
      await expect(gameGuest.locator('[data-ui="cash"]')).toHaveText('$150', { timeout: 45000 });

      // Suppress host rendering to model a background tab. Its simulation must
      // still progress, accept guest movement, and replicate the new position.
      await gameHost.evaluate(() => { window.requestAnimationFrame = () => 0; });
      await expect(gameGuest.locator('.csw-hud')).toHaveAttribute('data-phase', 'live', { timeout: 45000 });
      const before = await gameGuest.evaluate(() => window.matchFrame.players[5]);
      await gameGuest.getByLabel('First-person game view').focus();
      await guest.keyboard.down('w');
      try {
        await expect.poll(async () => {
          const after = await gameGuest.evaluate(() => window.matchFrame.players[5]);
          return Math.hypot(after.x - before.x, after.z - before.z);
        }, { timeout: 5000 }).toBeGreaterThan(0.2);
      } finally {
        await guest.keyboard.up('w');
      }

      await host.getByRole('button', { name: 'Leave match', exact: true }).click();
      await expect(gameGuest.getByRole('status').filter({ hasText: 'lobby has ended' })).toBeVisible({ timeout: 15000 });
      await guest.getByRole('button', { name: 'Return to lobby' }).click();
      await expect(guest.getByRole('button', { name: 'Create public lobby' })).toBeVisible();
    } finally {
      await Promise.all([hostContext.close(), guestContext.close()]);
    }
  });
}
