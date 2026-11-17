import { test, expect } from '@playwright/test';

const theme = page => page.locator('html');

test('dark default ignores the OS theme; explicit choices persist before first paint across both sites', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'light' });
  await page.goto('/game-hub/');
  await expect(theme(page)).toHaveAttribute('data-theme', 'dark');
  await page.getByRole('button', { name: 'Switch to light mode' }).click();
  await expect(theme(page)).toHaveAttribute('data-theme', 'light');
  await page.reload();
  await expect(theme(page)).toHaveAttribute('data-theme', 'light');
  await page.goto('/tic-tac-toe/');
  await expect(theme(page)).toHaveAttribute('data-theme', 'light');
  await page.getByRole('button', { name: 'Switch to dark mode' }).click();
  await page.goto('/game-hub/');
  await expect(theme(page)).toHaveAttribute('data-theme', 'dark');
  await page.evaluate(() => localStorage.setItem('game-hub-theme', 'invalid'));
  await page.reload();
  await expect(theme(page)).toHaveAttribute('data-theme', 'dark');
  const source = await (await page.request.get('/game-hub/')).text();
  expect(source.indexOf("localStorage.getItem('game-hub-theme')")).toBeLessThan(source.indexOf('<body>'));
});

test('theme controls work with the keyboard and preserve unsaved names and guest identity', async ({ page }) => {
  await page.goto('/game-hub/');
  await expect(page.locator('#guest-form')).toBeVisible();
  await page.getByLabel('Display name', { exact: true }).fill('Theme guest');
  await page.getByRole('button', { name: 'Switch to light mode' }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByLabel('Display name', { exact: true })).toHaveValue('Theme guest');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await expect(page.locator('#selection')).toBeVisible();
  const id = await page.evaluate(() => JSON.parse(localStorage.getItem('game-hub-auth')).user.id);
  await page.getByRole('button', { name: 'Change name' }).click();
  await page.getByLabel('Display name', { exact: true }).fill('Unsaved edit');
  await page.getByRole('button', { name: 'Switch to dark mode' }).click();
  await expect(page.getByLabel('Display name', { exact: true })).toHaveValue('Unsaved edit');
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('game-hub-auth')).user.id)).toBe(id);
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  await page.getByRole('link', { name: 'Open game' }).click();
  await expect(page.locator('#selection')).toBeVisible();
  await expect(theme(page)).toHaveAttribute('data-theme', 'dark');
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('game-hub-auth')).user.id)).toBe(id);
});

test('storage failure keeps dark fallback and a working page-local toggle', async ({ page }) => {
  await page.addInitScript(() => {
    Storage.prototype.getItem = () => { throw new Error('Storage unavailable'); };
    Storage.prototype.setItem = () => { throw new Error('Storage unavailable'); };
  });
  await page.goto('/game-hub/');
  await expect(theme(page)).toHaveAttribute('data-theme', 'dark');
  await page.getByRole('button', { name: 'Switch to light mode' }).click();
  await expect(theme(page)).toHaveAttribute('data-theme', 'light');
  await page.reload();
  await expect(theme(page)).toHaveAttribute('data-theme', 'dark');
});

test('side illustration changes with scroll and is static with reduced motion', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 600 });
  await page.goto('/game-hub/');
  await expect(page.locator('#side-visual')).toBeVisible();
  const before = await page.locator('#side-visual').getAttribute('data-step');
  await page.evaluate(() => scrollTo(0, document.documentElement.scrollHeight));
  await expect(page.locator('#side-visual')).toHaveAttribute('data-step', '5');
  expect(before).not.toBe('5');
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await expect(page.locator('#side-visual')).toHaveAttribute('data-step', '5');
  await page.evaluate(() => scrollTo(0, 200));
  await page.locator('#side-visual').scrollIntoViewIfNeeded();
  await expect(page.locator('#side-visual')).toHaveAttribute('data-step', '5');
  expect(await page.locator('.move').first().evaluate(el => getComputedStyle(el).transitionDuration)).toBe('0s');
});

test('both themes have readable tokens, correct art paths, and responsive entry/error layouts', async ({ page }) => {
  for (const slug of ['game-hub', 'tic-tac-toe']) {
    for (const width of [1440, 320]) {
      await page.setViewportSize({ width, height: 900 });
      await page.goto(`/${slug}/`);
      for (const mode of ['dark', 'light']) {
        if (await theme(page).getAttribute('data-theme') !== mode) await page.locator('#theme-toggle').click();
        await expect(page.locator('#guest-form')).toBeVisible();
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
        const art = await page.locator('.hero-art').evaluate(el => getComputedStyle(el).backgroundImage);
        expect(art).toContain(`/${slug}/art/playfield.svg`);
        const response = await page.request.get(`/${slug}/art/playfield.svg`);
        expect(response.ok()).toBe(true);
        const ratios = await page.evaluate(() => {
          const style = getComputedStyle(document.documentElement);
          const luminance = hex => {
            const rgb = hex.trim().slice(1).match(/../g).map(n => parseInt(n, 16) / 255).map(n => n <= .04045 ? n / 12.92 : ((n + .055) / 1.055) ** 2.4);
            return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722;
          };
          const ratio = (a, b) => { const x = luminance(style.getPropertyValue(a)); const y = luminance(style.getPropertyValue(b)); return (Math.max(x, y) + .05) / (Math.min(x, y) + .05); };
          return [ratio('--text', '--page'), ratio('--muted', '--page'), ratio('--accent-ink', '--accent'), ratio('--error', '--page'), ratio('--control-line', '--field')];
        });
        for (const ratio of ratios.slice(0, 4)) expect(ratio).toBeGreaterThanOrEqual(4.5);
        expect(ratios[4]).toBeGreaterThanOrEqual(3);
        await page.screenshot({ path: `/tmp/${slug}-${mode}-${width}.png`, fullPage: true });
        await page.getByRole('button', { name: 'Continue', exact: true }).click();
        await expect(page.locator('#guest-error')).toContainText('Enter a display name.');
      }
    }
  }
});
