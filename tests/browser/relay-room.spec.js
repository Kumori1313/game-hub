import { test, expect } from '@playwright/test';

test('two hub guests play Relay Room, leave, and start a new room', async ({browser,baseURL}) => {
  test.skip(process.env.VITE_ENABLE_RELAY_ROOM !== 'true','Requires the configured local Relay Room runtime');
  test.setTimeout(240000);
  const contexts = await Promise.all([0,1,2].map(i => browser.newContext(i === 1 ? {viewport:{width:390,height:844},hasTouch:true,isMobile:true} : {viewport:{width:980,height:690}})));
  const [host,guest,outsider] = await Promise.all(contexts.map(c => c.newPage()));
  for (const page of [host,guest,outsider]) page.setDefaultTimeout(12000);
  async function enter(page,name) {
    await page.goto(baseURL+'/game-hub/');
    await page.getByLabel('Display name',{exact:true}).fill(name);
    await page.getByRole('button',{name:'Continue',exact:true}).click();
    await page.locator('#relay-room-link').click();
    await expect(page.locator('#hub-info')).toHaveText('Signed in as '+name);
  }
  try {
    // Exercise keyboard-only look so synthetic headless pointer warps cannot turn the operator at spawn.
    for (const page of [host,guest]) await page.addInitScript(() => { Object.defineProperty(HTMLCanvasElement.prototype,'requestPointerLock',{value:undefined}); });
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
    const states = new Map();
    const plans = new Map([[host,[]],[guest,[]]]);
    for (const [page,received] of plans) {
      page.on('websocket', socket => {
        if (!socket.url().endsWith('/relay-room/live')) return;
        socket.on('framereceived',({payload}) => {
          const message = JSON.parse(String(payload));
          if (message.type === 'state') states.set(page,message.state);
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
    const firstRound = states.get(host).round;
    const plan = plans.get(host)[0];
    expect(plan.version).toBe(2);
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
    await guest.locator('#settings').tap();
    await guest.getByLabel('Reduce camera motion').check();
    await guest.locator('#volume').press('Home');
    await guest.getByRole('button',{name:'Done',exact:true}).tap();
    await guest.reload();
    await expect(guest.locator('#enter')).toBeEnabled();
    await guest.locator('#settings').tap();
    await expect(guest.getByLabel('Reduce camera motion')).toBeChecked();
    await expect(guest.locator('#volume')).toHaveValue('0');
    await guest.getByRole('button',{name:'Done',exact:true}).tap();
    // Walk the generated aisles with normal controls and operate the paired floor pads.
    await host.locator('#debug').click();
    await host.locator('#enter').click();
    await guest.locator('#enter').tap();
    const bays = new Map(plan.rooms.map(r => [r.id,r]));
    const intake = plan.rooms.find(r => r.kind === 'intake');
    const relay = bays.get(plan.objectiveId), exit = bays.get(plan.exitId);
    function path(from,to) {
      const queue = [[from]];
      const seen = new Set([from]);
      for (const chain of queue) {
        const bay = chain.at(-1);
        if (bay === to) return chain;
        for (const edge of plan.passages) {
          const next = edge.a === bay.id ? bays.get(edge.b) : edge.b === bay.id ? bays.get(edge.a) : null;
          if (next && !seen.has(next)) { seen.add(next); queue.push([...chain,next]); }
        }
      }
      throw Error('Disconnected facility');
    }
    async function walk(page,axis,to) {
      const coordinate = () => states.get(page).players.find(p => p.id === (page === host ? 1 : 2))[axis];
      const direction = Math.sign(to-coordinate());
      if (Math.abs(to-coordinate()) < 0.35) return;
      const key = axis === 'x' ? (direction > 0 ? 'd' : 'a') : (direction > 0 ? 's' : 'w');
      await page.keyboard.down(key);
      try {
        await expect.poll(async () => {
          const hint = await page.locator('#action').textContent();
          if (/Open bulkhead|Bulkhead within reach/.test(hint)) await page.keyboard.press('r');
          return direction*(to-coordinate());
        },{intervals:[90],timeout:11000,message:'Walking '+axis+' to '+to}).toBeLessThan(0.25);
      } finally { await page.keyboard.up(key); }
    }
    async function travel(page,from,to) {
      for (const bay of path(from,to)) {
        await walk(page,'x',bay.x);
        await walk(page,'z',bay.z);
      }
    }
    const receiver = plan.callout === 'black-start' ? plan.rooms.find(r => r.kind === 'switchboard') : intake;
    await travel(guest,intake,receiver);
    if (plan.callout === 'black-start') {
      await expect(guest.locator('#operate')).toHaveText('Charge switchboard');
      await guest.locator('#operate').tap();
    }
    await travel(host,intake,relay);
    await expect(host.locator('#action')).toContainText('Send test tone');
    await host.keyboard.press('q');
    await expect(guest.locator('#action')).toContainText('Answer relay');
    await guest.locator('#operate').tap();
    await expect(host.locator('#warning')).toContainText('Knocking above');
    await guest.screenshot({path:'/tmp/relay-shift-mobile.png'});
    await guest.locator('#debug').tap();
    await expect(guest.locator('#stats')).toContainText('Frame p95');
    const stats = await guest.locator('#stats').innerText();
    console.log('Touch viewport ('+browser.version()+', '+plan.callout+')',stats.split('\n').filter(line => /Frame p95|Scene ready|RX\/TX/.test(line)).join(' | '));
    await guest.locator('#debug').tap();
    await expect(host.locator('#warning')).toContainText('You are down',{timeout:10000});
    await host.reload();
    await expect(host.locator('#enter')).toBeEnabled();
    await host.locator('#enter').click();
    await expect(host.locator('#warning')).toContainText('You are down');
    await travel(guest,receiver,relay);
    await expect(guest.locator('#action')).toContainText('Revive partner');
    await guest.locator('#operate').tap();
    await expect(host.locator('#warning')).not.toContainText('You are down');
    // Travel together between strikes and extract as soon as both arrive.
    await Promise.all([travel(host,relay,exit),travel(guest,relay,exit)]);
    await expect(guest.locator('#action')).toContainText('Extract crew');
    await guest.locator('#operate').tap();
    for (const page of [host,guest]) await expect(page.locator('#result-title')).toHaveText('Crew extracted');
    await host.screenshot({path:'/tmp/relay-shift-result.png'});
    await host.locator('#replay').click();
    await expect(host.locator('#hub-select')).toBeVisible();
    await expect(guest.locator('#hub-select')).toBeVisible({timeout:10000});
    await guest.locator('#hub-back').click();
    await expect(guest).toHaveURL(/\/game-hub\//);
    await guest.locator('#relay-room-link').click();
    await guest.locator('#hub-create').click();
    await host.getByRole('button',{name:/Join Relay guest/}).click({timeout:10000});
    await guest.locator('#hub-start').click();
    await expect(host.locator('#connection')).toContainText('2/2 online');
    expect(new URL(host.url()).searchParams.get('lobby')).not.toBe(room);
    await expect.poll(() => states.get(host)?.mission?.stage).toBe(plans.get(host).at(-1).callout === 'black-start' ? 'prime' : 'trace');
    // A forced seed deliberately repeats across lobbies; the protocol round is always fresh.
    expect(states.get(host).round).not.toBe(firstRound);
    await guest.locator('#live-leave').click();
    await expect(host.locator('#hub-select')).toBeVisible({timeout:12000});
  } finally { await Promise.all(contexts.map(c => c.close())); }
});
