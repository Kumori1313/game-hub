import { test, expect } from '@playwright/test';

async function enter(page, baseURL, path, name) {
 await page.goto(`${baseURL}/${path}/`);
 await expect(page.locator('#guest-form')).toBeVisible();
 await page.getByLabel('Display name',{exact:true}).fill(name);
 await page.getByRole('button',{name:'Continue',exact:true}).click();
 await expect(page.getByRole('button',{name:'Create lobby',exact:true})).toBeEnabled();
}
const cell=(page,n)=>page.locator(`[data-cell="${n}"]`);
async function finishWin(x,o) {
 for(const [revision,n] of [0,3,1,4,2].entries()) {
  const player=revision%2?o:x;
  await expect(cell(player,n)).toBeEnabled();await cell(player,n).click();
  for(const page of [x,o]) await expect(page.locator('#match-board')).toHaveAttribute('data-revision',String(revision+1),{timeout:10000});
 }
}
async function close(pages,contexts) {
 for(const page of pages) {try{page.removeAllListeners('dialog');page.on('dialog',d=>d.accept());if(await page.locator('#leave-lobby').isVisible()) await page.locator('#leave-lobby').click({timeout:2000});else if(await page.locator('#back-lobbies').isVisible()) await page.locator('#back-lobbies').click({timeout:2000});}catch{}}
 await Promise.all(contexts.map(c=>c.close()));
}

test('private tic-tac-toe requires a code and rematches preserve the room while swapping marks',async({browser,baseURL})=>{
 test.setTimeout(120000);
 const contexts=await Promise.all([0,1,2].map(()=>browser.newContext({viewport:{width:390,height:844}})));
 const [host,guest,outsider]=await Promise.all(contexts.map(c=>c.newPage()));let held;
 try{
  await enter(host,baseURL,'tic-tac-toe',`Private-${Date.now().toString(36)}`);
  await host.locator('#room-visibility').selectOption('private');
  await host.getByRole('button',{name:'Create lobby',exact:true}).click();
  await expect(host.locator('#room-code')).toBeVisible();
  const id=new URL(host.url()).searchParams.get('room');const code=(await host.locator('#room-code').textContent()).replace('Room code: ','');
  await enter(guest,baseURL,'tic-tac-toe','Invited');
  await expect(guest.locator(`[data-lobby-id="${id}"]`)).toHaveCount(0);
  await enter(outsider,baseURL,'tic-tac-toe','Outside');
  await outsider.goto(`${baseURL}/tic-tac-toe/?room=${id}`);
  await expect(outsider.locator('#lobby-error')).toContainText('can’t enter');
  await expect(outsider.locator('#lobby-room')).toBeHidden();
  await outsider.locator('#room-code-input').fill('0000000000000000');
  await outsider.getByRole('button',{name:'Join with code',exact:true}).click();
  await expect(outsider.locator('#lobby-error')).toHaveText('Room not found or unavailable.');
  await guest.locator('#room-code-input').fill(code.toLowerCase());
  await guest.getByRole('button',{name:'Join with code',exact:true}).click();
  await expect(guest.locator('#lobby-room')).toBeVisible();
  expect(guest.url()).not.toContain(code.replaceAll('-',''));
  await expect(host.getByRole('button',{name:'Start game',exact:true})).toBeEnabled({timeout:15000});
  await host.getByRole('button',{name:'Start game',exact:true}).click();
  await expect(host.locator('#match-board')).toBeVisible();
  await expect(guest.locator('#match-board')).toBeVisible();
  const [x,o]=(await host.locator('#room-message').textContent())==='Your turn (X).'? [host,guest]:[guest,host];
  await finishWin(x,o);
  await expect(x.locator('#room-message')).toHaveText('You won (X).');
  await x.getByRole('button',{name:'Rematch',exact:true}).click();
  await expect(x.locator('#rematch-status')).toContainText('Waiting for opponent');
  await expect(o.locator('#room-title')).toHaveText('Match finished');
  await x.getByRole('button',{name:'Cancel rematch',exact:true}).click();
  await expect(x.getByRole('button',{name:'Rematch',exact:true})).toBeVisible();
  // Hold one old-round snapshot across the next round's start.
  const hold=async route=>{if(!held&&route.request().postDataJSON()?.p_action==='snapshot') held={route,response:await route.fetch()};else await route.continue();};
  await host.route('**/rpc/room_action',hold);
  await expect.poll(()=>Boolean(held),{timeout:10000}).toBe(true);
  await x.getByRole('button',{name:'Rematch',exact:true}).click();
  await o.getByRole('button',{name:'Rematch',exact:true}).click();
  // Obtain fresh state through recovery while the old snapshot stays held;
  // do not depend on where the 15-second heartbeat falls in this test.
  await host.evaluate(()=>dispatchEvent(new Event('online')));
  await expect(o.locator('#room-message')).toHaveText('Your turn (X).',{timeout:10000});
  await expect(x.locator('#room-message')).toHaveText('Waiting for X.',{timeout:10000});
  await held.route.fulfill({response:held.response});held=null;await host.unroute('**/rpc/room_action',hold);
  for(const page of [host,guest]) {
   await expect(page.locator('#match-board')).toHaveAttribute('data-revision','0');
   await expect(page.locator('.winning-cell')).toHaveCount(0);
   expect(new URL(page.url()).searchParams.get('lobby')).toBe(id);
   await expect(page.locator('#room-members li')).toHaveCount(2);
  }
  await o.reload();await expect(o.locator('#room-message')).toHaveText('Your turn (X).');
  await finishWin(o,x);
  await host.screenshot({path:'/tmp/game-hub-rematch.png',fullPage:true});
 }finally{if(held) await held.route.fulfill({response:held.response}).catch(()=>{});await close([host,guest,outsider],contexts);}
});

test('poker lobby shares hub identity and enforces a six-seat table without starting gameplay',async({browser,baseURL})=>{
 test.setTimeout(120000);
 const contexts=await Promise.all(Array.from({length:7},()=>browser.newContext({viewport:{width:390,height:844}})));
 const pages=await Promise.all(contexts.map(c=>c.newPage()));const [host,...guests]=pages;
 try{
  await host.goto(`${baseURL}/game-hub/`);await host.getByLabel('Display name',{exact:true}).fill(`Table-${Date.now().toString(36)}`);
  await host.getByRole('button',{name:'Continue',exact:true}).click();
  await expect(host.locator('#selection')).toBeVisible();
  const actor=await host.evaluate(()=>JSON.parse(localStorage.getItem('game-hub-auth')).user.id);
  await host.getByRole('link',{name:'Open poker lobby',exact:true}).click();
  await expect(host.getByRole('button',{name:'Create lobby',exact:true})).toBeEnabled();
  expect(await host.evaluate(()=>JSON.parse(localStorage.getItem('game-hub-auth')).user.id)).toBe(actor);
  await host.locator('#room-capacity').selectOption('6');
  await host.getByRole('button',{name:'Create lobby',exact:true}).click();await expect(host.locator('#lobby-room')).toBeVisible();
  const id=new URL(host.url()).searchParams.get('room');
  for(const [index,page] of guests.entries()) await enter(page,baseURL,'poker',`Seat ${index+2}`);
  // A discovery refresh between pointer-down and pointer-up must not discard Join.
  const firstJoin=guests[0].locator(`[data-lobby-id="${id}"]`).getByRole('button',{name:'Join',exact:true});
  await firstJoin.scrollIntoViewIfNeeded();const box=await firstJoin.boundingBox();
  await guests[0].mouse.move(box.x+box.width/2,box.y+box.height/2);await guests[0].mouse.down();
  await guests[1].locator(`[data-lobby-id="${id}"]`).getByRole('button',{name:'Join',exact:true}).click();
  await expect(guests[1].locator('#lobby-room')).toBeVisible();
  await expect(guests[0].locator(`[data-lobby-id="${id}"]`)).toContainText('2/6',{timeout:15000});
  await guests[0].mouse.up();await expect(guests[0].locator('#lobby-room')).toBeVisible();
  for(const page of guests.slice(2,5)) {await page.locator(`[data-lobby-id="${id}"]`).getByRole('button',{name:'Join',exact:true}).click();await expect(page.locator('#lobby-room')).toBeVisible();}
  await expect(host.locator('#room-members li')).toHaveCount(6,{timeout:15000});
  await guests[5].getByRole('button',{name:'Refresh',exact:true}).click();
  await expect(guests[5].locator(`[data-lobby-id="${id}"]`)).toContainText('6/6');
  await expect(guests[5].locator(`[data-lobby-id="${id}"]`).getByRole('button',{name:'Full',exact:true})).toBeDisabled();
  await expect(host.getByRole('button',{name:'Start game',exact:true})).toBeEnabled();
  await expect(host.locator('#room-message')).toHaveText('1,000 play chips · 10/20 blinds · 30-second turns · No rebuys · Rules locked');
  await host.setViewportSize({width:320,height:740});
  expect(await host.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  await host.screenshot({path:'/tmp/game-hub-poker-lobby.png',fullPage:true});
  await host.reload();await expect(host.locator('#room-members li')).toHaveCount(6);
 }finally{await close(pages,contexts);}
});
