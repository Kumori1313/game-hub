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
    // Exercise keyboard-only look so synthetic headless pointer warps cannot turn the operator at spawn.
    await host.addInitScript(() => { Object.defineProperty(HTMLCanvasElement.prototype,'requestPointerLock',{value:undefined}); });
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
    const plans = new Map([[host,[]],[guest,[]]]);
    for (const [page,received] of plans) {
      page.on('websocket', socket => {
        if (!socket.url().endsWith('/relay-room/live')) return;
        socket.on('framereceived',({payload}) => {
          const message = JSON.parse(String(payload));
          if (message.type === 'joined') received.push(message.layout);
        });
      });
    }
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
    const plan = plans.get(host)[0];
    expect(plan.version).toBe(1);
    expect(plans.get(guest)[0]).toEqual(plan);
    // Face north from Intake and walk up to the first bulkhead using real inputs.
    await host.keyboard.down('w');
    try { await expect(host.locator('#action')).toContainText('Open bulkhead',{timeout:10000}); }
    finally { await host.keyboard.up('w'); }
    await host.keyboard.press('r');
    const entranceDoor = plan.passages.find(p => p.a === 'bay-0').id;
    await expect(guest.locator('#stats')).toContainText('Open doors  '+entranceDoor);
    await host.reload();
    await expect(host.locator('#connection')).toContainText('2/2 online');
    await host.locator('#debug').click();
    await expect(host.locator('#stats')).toContainText('P1 · on');
    expect(plans.get(host).at(-1)).toEqual(plan);
    expect(plans.get(host).length).toBeGreaterThan(1);
    await expect(host.locator('#stats')).toContainText('Open doors  '+entranceDoor);
    await expect(host.locator('#layout-map')).toBeVisible();
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
