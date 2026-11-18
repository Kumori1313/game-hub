import { test, expect } from '@playwright/test';
async function enter(page,baseURL,name){await page.goto(`${baseURL}/poker/`);await page.getByLabel('Display name',{exact:true}).fill(name);await page.getByRole('button',{name:'Continue',exact:true}).click();await expect(page.locator('#create-lobby')).toBeEnabled();}
async function start(pages,baseURL){const host=pages[0];await host.locator('#room-capacity').selectOption(String(pages.length));await host.locator('#create-lobby').click();await expect(host.locator('#lobby-room')).toBeVisible();const id=new URL(host.url()).searchParams.get('room');for(const guest of pages.slice(1)){await guest.locator('#refresh-lobbies').click();await guest.locator(`[data-lobby-id="${id}"]`).getByRole('button',{name:'Join',exact:true}).click();await expect(guest.locator('#lobby-room')).toBeVisible();}await expect(host.locator('#start-game')).toBeEnabled({timeout:15000});await host.locator('#start-game').click();for(const page of pages)await expect(page.locator('#game-table')).toBeVisible();return id;}
async function active(pages){await expect.poll(async()=>{const statuses=await Promise.all(pages.map(p=>p.locator('#poker-status').textContent()));return statuses.includes('Your turn.')||statuses.every(s=>s==='Ready for the next hand.'||s==='Waiting for the host to deal.');},{timeout:15000}).toBe(true);for(const page of pages)if(await page.locator('#poker-status').textContent()==='Your turn.')return page;}
async function act(page,button){const before=await page.locator('#game-table').getAttribute('data-revision');await page.locator(button).click();await expect(page.locator('#game-table')).not.toHaveAttribute('data-revision',before,{timeout:15000});}
async function cleanup(pages,contexts){for(const p of pages){try{p.removeAllListeners('dialog');p.on('dialog',d=>d.accept());if(await p.locator('#leave-lobby').isVisible())await p.locator('#leave-lobby').click({timeout:2000});else if(await p.locator('#back-lobbies').isVisible())await p.locator('#back-lobbies').click({timeout:2000});}catch{}}await Promise.all(contexts.map(c=>c.close()));}

test('two players complete Hold’em streets, see authorized cards, refresh, and deal another hand',async({browser,baseURL})=>{
 test.setTimeout(180000);const contexts=await Promise.all([0,1].map(()=>browser.newContext({viewport:{width:390,height:844}})));const pages=await Promise.all(contexts.map(c=>c.newPage()));const [host,guest]=pages;
 try{
  await enter(host,baseURL,`Cards-${Date.now().toString(36)}`);await enter(guest,baseURL,'Opponent');const id=await start(pages,baseURL);
  const hand=await host.locator('#game-table').getAttribute('data-hand');
  for(const page of pages){const own=await page.evaluate(()=>JSON.parse(localStorage.getItem('game-hub-auth')).user.id);await expect(page.locator('#poker-own-cards .playing-card')).toHaveCount(2);await expect(page.locator(`.poker-seat:not([data-user-id="${own}"]) .card-back`)).toHaveCount(2);await expect(page.locator(`.poker-seat:not([data-user-id="${own}"]) .playing-card:not(.card-back)`)).toHaveCount(0);await expect(page.locator('#community-cards .playing-card')).toHaveCount(0);await expect(page.locator('body')).toHaveClass(/match-playing/);}
  await guest.reload();await expect(guest.locator('#game-table')).toHaveAttribute('data-hand',hand);await expect(guest.locator('#poker-own-cards .playing-card')).toHaveCount(2);
  for(let guard=0;guard<30;guard++){
   if((await host.locator('#poker-title').textContent()).includes('Complete'))break;
   const player=await active(pages);if(!player)break;await expect(player.locator('#poker-check-call')).toBeEnabled();const before=await player.locator('#game-table').getAttribute('data-revision');await player.locator('#poker-check-call').focus();await player.keyboard.press('Enter');await expect(player.locator('#game-table')).not.toHaveAttribute('data-revision',before,{timeout:15000});
  }
  for(const page of pages){await expect(page.locator('#poker-title')).toContainText('Complete',{timeout:15000});await expect(page.locator('#community-cards .playing-card')).toHaveCount(5);await expect(page.locator('#poker-result')).toContainText('Showdown.');await expect(page.locator('body')).not.toHaveClass(/match-playing/);}
  await host.setViewportSize({width:1440,height:1000});await host.screenshot({path:'/tmp/poker-82-showdown.png',fullPage:true});
  await expect(host.locator('#poker-next')).toBeEnabled();await host.locator('#poker-next').click();
  for(const page of pages){await expect(page.locator('#poker-title')).toHaveText('Hand 2 · Preflop',{timeout:15000});await expect(page.locator('#game-table')).not.toHaveAttribute('data-hand',hand);expect(new URL(page.url()).searchParams.get('lobby')).toBe(id);}
  const folding=await active(pages);await act(folding,'#poker-fold');
  for(const page of pages){await expect(page.locator('#poker-title')).toContainText('Complete',{timeout:15000});await expect(page.locator('#community-cards .playing-card')).toHaveCount(0);}
  await guest.setViewportSize({width:320,height:740});await guest.locator('#theme-toggle').click();expect(await guest.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);await guest.screenshot({path:'/tmp/poker-82-mobile.png',fullPage:true});
 }finally{await cleanup(pages,contexts);}
});

test('three-player betting, offline recovery, and host departure preserve the table',async({browser,baseURL})=>{
 test.setTimeout(120000);const contexts=await Promise.all([0,1,2].map(()=>browser.newContext()));const pages=await Promise.all(contexts.map(c=>c.newPage()));
 try{
  for(const [i,p]of pages.entries())await enter(p,baseURL,`Table ${i}`);await start(pages,baseURL);
  let player=await active(pages);await expect(player.locator('#poker-amount')).toBeEnabled();await player.locator('#poker-amount').fill('60');await act(player,'#poker-raise');
  player=await active(pages);await expect(player.locator('#poker-check-call')).toContainText('Call');await act(player,'#poker-check-call');
  await contexts[2].setOffline(true);await expect(pages[2].locator('#selection')).toBeHidden();await contexts[2].setOffline(false);await expect(pages[2].locator('#game-table')).toBeVisible();
  pages[0].on('dialog',d=>d.accept());await pages[0].getByRole('button',{name:'Leave table',exact:true}).click();await expect(pages[0].locator('#lobby-discovery')).toBeVisible();
  for(const p of pages.slice(1)){await expect(p.locator('#game-table')).toBeVisible();await expect(p.locator('#poker-players')).toContainText('Left',{timeout:15000});await expect(p.locator('#room-title')).not.toHaveText('Lobby closed');}
  for(let guard=0;guard<30;guard++){if((await pages[1].locator('#poker-title').textContent()).includes('Complete'))break;const next=await active(pages.slice(1));if(!next)break;await act(next,'#poker-check-call');}
  for(const p of pages.slice(1))await expect(p.locator('#poker-title')).toContainText('Complete',{timeout:15000});
 }finally{await cleanup(pages,contexts);}
});
