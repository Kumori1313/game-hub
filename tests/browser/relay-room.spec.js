import { test, expect } from '@playwright/test';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

// The game's own planner turns its multi-storey floor plan into axis-aligned walking legs.
const game = resolve(process.env.RELAY_SITE_DIR ?? '../Horror-Friendslop');
const load = file => import(pathToFileURL(game+'/src/'+file).href);

test('two hub guests play Relay Room, leave, and start a new room', async ({browser,baseURL}) => {
  const published = process.env.RELAY_RELEASE_SMOKE === 'true';
  if (published && baseURL !== 'https://kumori1313.github.io') throw Error('Use the trusted Pages origin for the release smoke test.');
  test.skip(!published && process.env.VITE_ENABLE_RELAY_ROOM !== 'true','Requires the configured local Relay Room game');
  // Two-storey facilities take several minutes to cross with keyboard walking.
  test.setTimeout(420000);
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
    expect(plan.version).toBe(3);
    expect(plans.get(guest)[0]).toEqual(plan);
    // Face north from Intake and walk up to the first bulkhead using real inputs.
    await host.keyboard.down('w');
    try { await expect(host.locator('#action')).toContainText('Open bulkhead',{timeout:10000}); }
    finally { await host.keyboard.up('w'); }
    await host.keyboard.press('r');
    const entranceDoor = plan.passages.find(p => p.bulkhead && (p.a === 'intake' || p.b === 'intake')).id;
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
    // Walk the generated corridors and stairs with normal controls and operate the paired floor pads.
    await host.locator('#enter').click();
    await guest.locator('#enter').tap();
    const [{route},{anchor}] = await Promise.all([load('route.ts'),load('layout.ts')]);
    const bays = new Map(plan.rooms.map(r => [r.id,r]));
    const intake = plan.rooms.find(r => r.kind === 'intake');
    const relay = bays.get(plan.objectiveId), exit = bays.get(plan.exitId);
    // Hold the key for a little less than the distance needs, wait for the
    // host's snapshot, then settle with short taps. Snapshots lag the keys, so
    // walking until the reported position passes the target would overshoot.
    // A guest samples its keys every 100 ms, so a tap lasts at least 150 ms;
    // routes keep 0.85 m of clearance, which absorbs the 0.4 m tolerance.
    const self = page => states.get(page).players.find(p => p.id === (page === host ? 1 : 2));
    async function walk(page,axis,to) {
      const coordinate = () => self(page)[axis];
      for (let pulse=0; pulse<40; pulse++) {
        if (states.get(page).mission?.down.some(d => d.id === self(page).id)) throw Error('Operator down while walking');
        const remaining = to-coordinate();
        if (Math.abs(remaining) < 0.4) return;
        const key = axis === 'x' ? (remaining > 0 ? 'd' : 'a') : (remaining > 0 ? 's' : 'w');
        await page.keyboard.down(key);
        try { await page.waitForTimeout(Math.max(150,Math.min(3000,Math.abs(remaining)/3.3*1000-120))); }
        finally { await page.keyboard.up(key); }
        await page.waitForTimeout(220);
        if (/Open bulkhead|Bulkhead within reach/.test(await page.locator('#action').textContent())) await page.keyboard.press('r');
      }
      throw Error('Walking '+axis+' to '+to+' stalled at '+coordinate());
    }
    async function travel(page,to) {
      const p = self(page);
      const legs = route(plan,{x:p.x,y:p.feetY ?? 0,z:p.z},to.kind ? anchor(to) : to);
      if (!legs) throw Error('No walking route to '+(to.id ?? JSON.stringify(to)));
      for (const leg of legs) {
        await walk(page,'x',leg.x);
        await walk(page,'z',leg.z);
      }
    }
    const receiver = plan.callout === 'black-start' ? plan.rooms.find(r => r.kind === 'switchboard') : intake;
    await travel(guest,receiver);
    if (plan.callout === 'black-start') {
      await expect(guest.locator('#operate')).toHaveText('Charge switchboard');
      await guest.locator('#operate').tap();
    }
    await travel(host,relay);
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
    await travel(guest,relay);
    await expect(guest.locator('#action')).toContainText('Revive partner');
    await guest.locator('#operate').tap();
    await expect(host.locator('#warning')).not.toContainText('You are down');
    // Travel together and extract as soon as both arrive. The walk to the exit
    // is long enough for another strike: the standing operator walks back,
    // revives their partner, and both carry on.
    for (let attempt=0; ; attempt++) {
      const trips = await Promise.allSettled([travel(host,exit),travel(guest,exit)]);
      if (trips.every(t => t.status === 'fulfilled')) break;
      const down = states.get(host).mission.down.map(d => d.id);
      if (attempt >= 3 || down.length !== 1) throw trips.find(t => t.status === 'rejected').reason;
      const [rescuer,fallen] = down[0] === 1 ? [guest,host] : [host,guest];
      const at = self(fallen);
      await travel(rescuer,{x:at.x,y:at.feetY ?? 0,z:at.z});
      await expect(rescuer.locator('#action')).toContainText('Revive partner');
      if (rescuer === guest) await guest.locator('#operate').tap();
      else await host.keyboard.press('q');
      await expect.poll(() => states.get(host).mission.down.length).toBe(0);
    }
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
