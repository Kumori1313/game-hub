import { test, expect } from '@playwright/test';

test('two hub guests play Relay Room, leave, and start a new room', async ({browser,baseURL}) => {
  test.skip(process.env.VITE_ENABLE_RELAY_ROOM !== 'true','Requires the configured local Relay Room runtime');
  test.setTimeout(100000);
  const contexts = await Promise.all([0,1,2].map(() => browser.newContext({viewport:{width:980,height:690}})));
  const [host,guest,outsider] = await Promise.all(contexts.map(c => c.newPage()));
  async function enter(page,name) {
    await page.goto(baseURL+'/game-hub/');
    await page.getByLabel('Display name',{exact:true}).fill(name);
    await page.getByRole('button',{name:'Continue',exact:true}).click();
    await page.locator('#relay-room-link').click();
    await expect(page.locator('#hub-info')).toHaveText('Signed in as '+name);
  }
  try {
    await Promise.all([enter(host,'Relay host'),enter(guest,'Relay guest'),enter(outsider,'Bystander')]);
    await host.locator('#hub-visibility').selectOption('private');
    await host.locator('#hub-create').click();
    await expect(host.locator('#hub-invite')).toContainText('Room code:');
    const code = (await host.locator('#hub-invite').innerText()).split(': ')[1];
    const room = new URL(host.url()).searchParams.get('room');
    await outsider.goto(baseURL+'/relay-room/?lobby='+room);
    await expect(outsider.locator('#hub-error')).toContainText('not a member');
    await expect(outsider.locator('#hub-public')).not.toContainText('Relay host');
    await outsider.locator('#hub-code').fill('bad');
    await outsider.getByRole('button',{name:'Join with code'}).click();
    await expect(outsider.locator('#hub-error')).toContainText('unavailable');
    await guest.locator('#hub-code').fill(code);
    await guest.getByRole('button',{name:'Join with code'}).click();
    await expect(guest.locator('#hub-members li')).toHaveCount(2);
    await guest.reload();
    await expect(guest.locator('#hub-members li')).toHaveCount(2);
    await host.locator('#hub-start').click();
    await expect(guest.locator('#enter')).toBeEnabled();
    await expect(host.locator('#connection')).toContainText('2/2 online');
    expect(new URL(guest.url()).searchParams.get('lobby')).toBe(room);
    // A valid outsider guest cannot open the known live lobby, even with its ID.
    const denied = await outsider.evaluate(id => new Promise((resolve,reject) => {
      const ws = new WebSocket('ws://'+location.host+'/relay-room/live');
      ws.onopen = () => ws.send(JSON.stringify({type:'join',ticket:null,admission:{
        lobby:id,round:1,token:JSON.parse(localStorage.getItem('game-hub-auth')).access_token,
      }}));
      ws.onmessage = () => { ws.close(); reject(Error('Outsider received live data')); };
      ws.onclose = e => resolve(e.code);
    }),room);
    expect(denied).toBe(1008);
    await host.locator('#enter').click();
    await guest.locator('#debug').click();
    await host.keyboard.press('e');
    await expect(guest.locator('#stats')).toContainText('P1 · on');
    await host.reload();
    await expect(host.locator('#connection')).toContainText('2/2 online');
    await host.locator('#debug').click();
    await expect(host.locator('#stats')).toContainText('P1 · on');
    await host.screenshot({path:'/tmp/relay-hub-live.png'});
    await host.locator('#live-leave').click();
    await expect(host).toHaveURL(/\/game-hub\//);
    await expect(guest.locator('#hub-select')).toBeVisible({timeout:10000});
    await guest.locator('#hub-back').click();
    await expect(guest).toHaveURL(/\/game-hub\//);
    for (const p of [host,guest]) await p.locator('#relay-room-link').click();
    await guest.locator('#hub-create').click();
    await host.getByRole('button',{name:/Join Relay guest/}).click({timeout:10000});
    await guest.locator('#hub-start').click();
    await expect(host.locator('#connection')).toContainText('2/2 online');
    expect(new URL(host.url()).searchParams.get('lobby')).not.toBe(room);
    await guest.locator('#live-leave').click();
  } finally { await Promise.all(contexts.map(c => c.close())); }
});
