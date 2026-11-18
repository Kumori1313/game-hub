import { test,expect } from '@playwright/test';
async function enter(page,baseURL,name){await page.goto(`${baseURL}/poker/`);await page.getByLabel('Display name',{exact:true}).fill(name);await page.getByRole('button',{name:'Continue',exact:true}).click();await expect(page.locator('#create-lobby')).toBeEnabled();}
async function add(page){const before=await page.locator('#room-members li').count();await expect(page.locator('#add-bot')).toBeEnabled();await page.locator('#add-bot').click();await expect(page.locator('#room-members li')).toHaveCount(before+1);}
async function foldHumanTurns(pages){
 for(let i=0;i<120;i++){
  if((await pages[0].locator('#poker-title').textContent()).includes('Complete'))return;
  for(const page of pages){if(await page.locator('#poker-fold').isEnabled()){await page.locator('#poker-fold').click();break;}}
  await expect.poll(async()=>pages[0].locator('#poker-title').textContent(),{timeout:1000,intervals:[200]}).toBeTruthy();
  await pages[0].waitForTimeout(500);
 }
 await expect(pages[0].locator('#poker-title')).toContainText('Complete',{timeout:20000});
}
async function cleanup(pages,contexts){for(const p of pages){try{p.removeAllListeners('dialog');p.on('dialog',d=>d.accept());if(await p.locator('#leave-lobby').isVisible())await p.locator('#leave-lobby').click({timeout:2000});else if(await p.locator('#back-lobbies').isVisible())await p.locator('#back-lobbies').click({timeout:2000});}catch{}}await Promise.all(contexts.map(c=>c.close()));}
test('one human can add and remove a bot, play, refresh, and deal again',async({browser,baseURL})=>{
 test.setTimeout(120000);const context=await browser.newContext({viewport:{width:320,height:800}});const page=await context.newPage();
 try{
  await enter(page,baseURL,`Solo-${Date.now().toString(36)}`);await page.locator('#room-capacity').selectOption('2');await page.locator('#create-lobby').click();await expect(page.locator('#room-members li')).toHaveCount(1);
  await add(page);await expect(page.locator('#add-bot')).toBeDisabled();await page.getByRole('button',{name:'Remove Bot 2',exact:true}).click();await expect(page.locator('#room-members li')).toHaveCount(1);await add(page);
  await expect(page.locator('#start-game')).toBeEnabled();await page.locator('#start-game').click();await expect(page.locator('#game-table')).toBeVisible();await expect(page.locator('#bot-controls')).toBeHidden();await expect(page.locator('#poker-players')).toContainText('Bot');
  await expect(page.locator('#poker-own-cards .playing-card')).toHaveCount(2);await expect(page.locator('.poker-seat .card-back')).toHaveCount(2);
  const hand=await page.locator('#game-table').getAttribute('data-hand');await page.reload();await expect(page.locator('#game-table')).toHaveAttribute('data-hand',hand);await expect(page.locator('#poker-own-cards .playing-card')).toHaveCount(2);
  await foldHumanTurns([page]);await expect(page.locator('#poker-title')).toContainText('Complete');await expect(page.locator('#poker-next')).toBeEnabled();await page.locator('#poker-next').click();await expect(page.locator('#poker-title')).toHaveText('Hand 2 · Preflop');expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);await page.screenshot({path:'/tmp/poker-bots-mobile.png',fullPage:true});
 }finally{await cleanup([page],[context]);}
});
test('two humans and two bots share seats and retain a human host after departure',async({browser,baseURL})=>{
 test.setTimeout(120000);const contexts=await Promise.all([0,1].map(()=>browser.newContext()));const pages=await Promise.all(contexts.map(c=>c.newPage()));const [host,guest]=pages;
 try{
  await enter(host,baseURL,`Mixed-${Date.now().toString(36)}`);await enter(guest,baseURL,'Human guest');await host.locator('#room-capacity').selectOption('4');await host.locator('#create-lobby').click();await expect(host.locator('#room-members li')).toHaveCount(1);await add(host);await add(host);
  const id=new URL(host.url()).searchParams.get('room');await guest.locator('#refresh-lobbies').click();await expect(guest.locator(`[data-lobby-id="${id}"]`)).toContainText('3/4');await guest.locator(`[data-lobby-id="${id}"]`).getByRole('button',{name:'Join',exact:true}).click();await expect(guest.locator('#room-members li')).toHaveCount(4);await expect(guest.locator('#bot-controls')).toBeHidden();await expect(host.locator('#room-members li')).toHaveCount(4);await expect(host.locator('#add-bot')).toBeDisabled();await expect(host.locator('#start-game')).toBeEnabled();await host.locator('#start-game').click();
  for(const p of pages){await expect(p.locator('#game-table')).toBeVisible();await expect(p.locator('#poker-players li')).toHaveCount(4);await expect(p.locator('#poker-own-cards .playing-card')).toHaveCount(2);await expect(p.locator('.poker-seat .card-back')).toHaveCount(6);}
  host.on('dialog',d=>d.accept());await host.locator('#leave-lobby').click();await expect(host.locator('#lobby-discovery')).toBeVisible();await expect(guest.locator('#poker-players')).toContainText('Left');await expect(guest.locator('#poker-players')).toContainText('Host');await foldHumanTurns([guest]);await expect(guest.locator('#poker-title')).toContainText('Complete');
 }finally{await cleanup(pages,contexts);}
});
