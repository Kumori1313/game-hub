import { test, expect } from '@playwright/test';

test('two hub guests play Relay Room, leave, and start a new room', async ({browser,baseURL}) => {
  const published = process.env.RELAY_RELEASE_SMOKE === 'true';
  if (published && baseURL !== 'https://kumori1313.github.io') throw Error('Use the trusted Pages origin for the release smoke test.');
  test.skip(!published && process.env.VITE_ENABLE_RELAY_ROOM !== 'true','Requires the configured local Relay Room game');
  test.setTimeout(240000);
  const contexts = await Promise.all((published ? [0,1] : [0,1,2]).map(i => browser.newContext(i === 1 ? {viewport:{width:390,height:844},hasTouch:true,isMobile:true} : {viewport:{width:980,height:690}})));
  const [host,guest,outsider] = await Promise.all(contexts.map(c => c.newPage()));
  for (const page of [host,guest,...(outsider ? [outsider] : [])]) page.setDefaultTimeout(12000);
  async function enter(page,name) {
    await page.goto(baseURL+'/game-hub/');
    await page.getByLabel('Display name',{exact:true}).fill(name);
    await page.getByRole('button',{name:'Continue',exact:true}).click();
    await expect(page.locator('#identity')).toContainText(name);
    if (published) await page.goto(baseURL+'/relay-room/');
    else await page.locator('#relay-room-link').click();
    await expect(page.locator('#hub-info')).toHaveText('Signed in as '+name);
  }
  try {
    // Exercise keyboard-only look so synthetic headless pointer warps cannot turn the operator at spawn.
    for (const page of [host,guest]) await page.addInitScript(() => { Object.defineProperty(HTMLCanvasElement.prototype,'requestPointerLock',{value:undefined}); });
    await Promise.all([enter(host,'Relay host'),enter(guest,'Relay guest'),...(outsider ? [enter(outsider,'Bystander')] : [])]);
    await host.locator('#hub-visibility').selectOption('private');
    await expect(host.getByRole('checkbox', { name: 'Use a 16-character code' })).not.toBeChecked();
    await host.locator('#hub-create').click();
    await expect(host.locator('#hub-invite')).toHaveText(/^Room code: [23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}$/);
    const code = (await host.locator('#hub-invite').innerText()).split(': ')[1];
    const room = new URL(host.url()).searchParams.get('room');
    if (outsider) {
      await outsider.goto(baseURL+'/relay-room/?lobby='+room);
      await expect(outsider.locator('#hub-error')).toContainText('not a member');
      await expect(outsider.locator('#hub-public')).not.toContainText('Relay host');
      await outsider.locator('#hub-code').fill('bad');
      await outsider.getByRole('button',{name:'Join with code'}).click();
      await expect(outsider.locator('#hub-error')).toContainText('unavailable');
    }
    await guest.locator('#hub-code').fill(code);
    await guest.getByRole('button',{name:'Join with code'}).click();
    await expect(guest.locator('#hub-members li')).toHaveCount(2);
    await guest.reload();
    await expect(guest.locator('#hub-members li')).toHaveCount(2);
    const states = new Map();
    const plans = new Map([[host,[]],[guest,[]]]);
    for (const [page,received] of plans) {
      page.on('websocket', socket => {
        if (!new URL(socket.url()).pathname.endsWith('/realtime/v1/websocket')) return;
        function observe({payload}) {
          const wire = JSON.parse(String(payload));
          const [topic,event,body] = Array.isArray(wire) ? wire.slice(2) : [wire.topic,wire.event,wire.payload];
          if (!topic?.endsWith(':host') || event !== 'broadcast') return;
          const message = body.payload;
          if (message.type === 'welcome') received.push(message.layout);
          if (message.state) states.set(page,message.state);
        }
        socket.on('framereceived',observe);
        socket.on('framesent',observe);
      });
    }
    await host.locator('#hub-start').click();
    await expect(guest.locator('#enter')).toBeEnabled();
    await expect(host.locator('#connection')).toContainText('2/2 online');
    expect(new URL(guest.url()).searchParams.get('lobby')).toBe(room);
    const duplicate = await contexts[0].newPage();
    await duplicate.goto(host.url());
    await expect(duplicate.locator('#connection')).toContainText('Already playing in another tab');
    await duplicate.close();
    for (const page of [host,guest]) {
      await page.keyboard.press('g');
      await expect(page.locator('#debug,#layout-map,#outage,#diagnostics,#stats,#orders,#brief-instructions')).toHaveCount(0);
    }
    const guestUrl = guest.url();
    await guest.goto('about:blank');
    await expect(host.locator('#connection')).toContainText('1/2 online');
    await guest.goto(guestUrl);
    await expect(guest.locator('#connection')).toContainText('2/2 online');
    await expect(host.locator('#connection')).toContainText('2/2 online');
    await host.locator('#enter').click();
    await host.keyboard.press('e');
    await expect.poll(() => states.get(guest)?.lamp.owner).toBe(1);
    expect(states.get(guest).lamp.on).toBe(true);
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
    await expect.poll(() => states.get(guest)?.opened).toContain(entranceDoor);
    await host.reload();
    await expect(host.locator('#connection')).toContainText('2/2 online');
    await expect.poll(() => states.get(host)?.lamp.owner).toBe(1);
    expect(plans.get(host).at(-1)).toEqual(plan);
    await expect.poll(() => plans.get(host).length).toBeGreaterThan(1);
    expect(states.get(host).opened).toContain(entranceDoor);
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
    for (const page of [host,guest]) {
      await expect(page.locator('#result-title')).toHaveText('Crew extracted');
      const reference = await page.locator('#report-reference').inputValue();
      expect(reference).toMatch(/^Build (?:local|[0-9a-f]{12}) · Layout v[0-9]+ · Seed [0-9]+$/);
      expect(reference).toContain('Layout v'+plan.version+' · Seed '+plan.seed);
    }
    await contexts[0].grantPermissions(['clipboard-read','clipboard-write']);
    await host.getByRole('button',{name:'Copy reference'}).click();
    await expect(host.locator('#copy-reference')).toHaveText('Copied');
    expect(await host.evaluate(() => navigator.clipboard.readText())).toBe(await host.locator('#report-reference').inputValue());
    await host.screenshot({path:'/tmp/relay-shift-result.png'});
    await host.locator('#replay').click();
    await expect(host.locator('#hub-select')).toBeVisible();
    await expect(guest.locator('#hub-select')).toBeVisible({timeout:10000});
    await guest.locator('#hub-back').click();
    await expect(guest).toHaveURL(/\/game-hub\//);
    if (published) {
      await guest.goto(baseURL+'/relay-room/');
      await guest.locator('#hub-visibility').selectOption('private');
      await guest.locator('#hub-create').click();
      await expect(guest.locator('#hub-invite')).toContainText('Room code:');
      await host.locator('#hub-code').fill((await guest.locator('#hub-invite').innerText()).split(': ')[1]);
      await host.getByRole('button',{name:'Join with code'}).click();
    } else {
      await guest.locator('#relay-room-link').click();
      await guest.locator('#hub-create').click();
      await host.getByRole('button',{name:/Join Relay guest/}).click({timeout:10000});
    }
    await guest.locator('#hub-start').click();
    await expect(host.locator('#connection')).toContainText('2/2 online');
    expect(new URL(host.url()).searchParams.get('lobby')).not.toBe(room);
    await expect.poll(() => states.get(host)?.round).not.toBe(firstRound);
    await expect.poll(() => states.get(host)?.mission?.stage).toBe(plans.get(host).at(-1).callout === 'black-start' ? 'prime' : 'trace');
    // A forced seed deliberately repeats across lobbies; the protocol round is always fresh.
    expect(states.get(host).round).not.toBe(firstRound);
    if (published) {
      await guest.locator('#live-leave').click();
    } else {
      // Closing the creator's browser without clicking Leave exercises the grace timeout.
      await guest.close();
      await expect(host.locator('#connection')).toHaveText('Reconnecting…');
    }
    await expect(host.locator('#hub-select')).toBeVisible({timeout:30000});
  } finally { await Promise.all(contexts.map(c => c.close())); }
});

test('one guest plays a local solo shift, refreshes, and leaves', async ({page,baseURL}) => {
  const published = process.env.RELAY_RELEASE_SMOKE === 'true';
  test.skip(!published && process.env.VITE_ENABLE_RELAY_ROOM !== 'true','Requires Relay Room');
  await page.goto(baseURL+'/relay-room/');
  const solo = page.getByRole('link',{name:'Play solo'});
  await expect(solo).toBeVisible();
  const sockets = [];
  page.on('websocket',socket => sockets.push(socket.url()));
  await solo.click();
  await expect(page.locator('#connection')).toHaveText('Solo operator');
  await expect(page.locator('#enter')).toBeEnabled();
  await page.locator('#enter').click();
  await page.keyboard.press('e');
  await expect(page.locator('#action')).toContainText('Drop flashlight');
  await page.reload();
  await page.locator('#enter').click();
  await expect(page.locator('#action')).toContainText('Drop flashlight');
  await expect(page.locator('#debug,#orders')).toHaveCount(0);
  expect(sockets).toHaveLength(0);
  await page.keyboard.press('Escape');
  await page.getByRole('button',{name:'Leave solo'}).click();
  await expect(solo).toBeVisible();
});
