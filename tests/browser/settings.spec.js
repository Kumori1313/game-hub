import {test,expect} from '@playwright/test';
async function enter(page,baseURL,name){await page.goto(`${baseURL}/poker/`);await page.getByLabel('Display name',{exact:true}).fill(name);await page.getByRole('button',{name:'Continue',exact:true}).click();await expect(page.locator('#create-lobby')).toBeEnabled();}
async function active(pages){await expect.poll(async()=>{const values=await Promise.all(pages.map(p=>p.locator('#poker-status').textContent()));return values.includes('Your turn.')||values.every(s=>!s.startsWith('Waiting for ')||s.includes('rebuy'));},{timeout:15000}).toBe(true);for(const page of pages)if(await page.locator('#poker-status').textContent()==='Your turn.')return page;}
async function cleanup(pages,contexts){for(const p of pages){try{p.removeAllListeners('dialog');p.on('dialog',d=>d.accept());if(await p.locator('#leave-lobby').isVisible())await p.locator('#leave-lobby').click({timeout:2000});else if(await p.locator('#back-lobbies').isVisible())await p.locator('#back-lobbies').click({timeout:2000});}catch{}}await Promise.all(contexts.map(c=>c.close()));}
test('custom rules persist, are shared before play, and permit a voluntary between-hand rebuy',async({browser,baseURL})=>{
 test.setTimeout(180000);const contexts=await Promise.all([0,1].map(()=>browser.newContext({viewport:{width:390,height:844}})));const pages=await Promise.all(contexts.map(c=>c.newPage()));const [host,guest]=pages;
 try{
  await enter(host,baseURL,`Rules-${Date.now().toString(36)}`);await host.locator('#poker-settings summary').click();await expect(host.locator('#starting-chips')).toHaveValue('1000');await expect(host.locator('#table-blinds')).toHaveValue('20');await expect(host.locator('#turn-seconds')).toHaveValue('30');await expect(host.locator('#rebuy-limit')).toHaveValue('0');
  await host.locator('#room-capacity').selectOption('2');await host.locator('#starting-chips').fill('2000');await host.locator('#table-blinds').selectOption('50');await host.locator('#turn-seconds').selectOption('45');await host.locator('#rebuy-limit').selectOption('1');
  await host.reload();await expect(host.locator('#create-lobby')).toBeEnabled();await expect(host.locator('#starting-chips')).toHaveValue('2000');await expect(host.locator('#room-capacity')).toHaveValue('2');await host.locator('#room-visibility').selectOption('private');
  const longCode = host.getByRole('checkbox', { name: 'Use a 16-character code' });
  await expect(longCode).not.toBeChecked();
  await longCode.check();
  await host.locator('#create-lobby').click();await expect(host.locator('#room-message')).toContainText('2,000 play chips · 25/50 blinds · 45-second turns · 1 rebuy/player · Rules locked');
  const code=(await host.locator('#room-code').textContent()).replace('Room code: ','');
  expect(code).toMatch(/^[0-9A-F]{4}(?:-[0-9A-F]{4}){3}$/);
  await enter(guest,baseURL,'Rules guest');await guest.locator('#room-code-input').fill(code);await guest.locator('#join-code').click();await expect(guest.locator('#room-message')).toContainText('2,000 play chips · 25/50 blinds · 45-second turns');await guest.reload();await expect(guest.locator('#room-message')).toContainText('Rules locked');
  await expect(host.locator('#start-game')).toBeEnabled();await host.locator('#start-game').click();for(const p of pages){await expect(p.locator('#game-table')).toBeVisible();await expect(p.locator('#poker-rules')).toContainText('25/50 blinds · 45s');await expect(p.locator('#poker-pot')).toHaveText('Pot: 75');await expect(p.locator('#poker-rebuy')).toBeHidden();}
  let rebuyer;
  for(let hand=0;hand<6&&!rebuyer;hand++){
   for(let move=0;move<3;move++){if((await host.locator('#poker-title').textContent()).includes('Complete'))break;const p=await active(pages);if(!p)break;const revision=await p.locator('#game-table').getAttribute('data-revision');await expect(p.locator('#poker-all-in')).toBeEnabled();await p.locator('#poker-all-in').click();await expect(p.locator('#game-table')).not.toHaveAttribute('data-revision',revision);}
   for(const p of pages)await expect(p.locator('#poker-title')).toContainText('Complete',{timeout:15000});
   for(const p of pages)if(await p.locator('#poker-rebuy').isVisible())rebuyer=p;
   if(!rebuyer){await expect(host.locator('#poker-next')).toBeEnabled();await host.locator('#poker-next').click();await expect(host.locator('#poker-title')).toContainText('Preflop');}
  }
  expect(rebuyer).toBeTruthy();await expect(host.locator('#poker-next')).toBeDisabled();await expect(rebuyer.locator('#poker-rebuy')).toHaveText('Rebuy 2,000');await rebuyer.locator('#poker-rebuy').focus();await rebuyer.keyboard.press('Enter');await expect(rebuyer.locator('#poker-rebuy')).toBeHidden();await expect(rebuyer.locator('#poker-players')).toContainText('Rebuys 1/1');await expect(host.locator('#poker-next')).toBeEnabled();await host.locator('#poker-next').click();for(const p of pages)await expect(p.locator('#poker-rules')).toContainText('25/50 blinds · 45s');
 }finally{await cleanup(pages,contexts);}
});
test('settings validate on a narrow screen and custom bot tables work without preference storage',async({browser,baseURL})=>{
 test.setTimeout(90000);const context=await browser.newContext({viewport:{width:320,height:800}});const page=await context.newPage();
 await page.addInitScript(()=>{const original=Storage.prototype.setItem;Storage.prototype.setItem=function(key,value){if(key==='game-hub-poker-settings')throw new DOMException('Blocked','SecurityError');return original.call(this,key,value);};});
 try{
  await enter(page,baseURL,`Small-${Date.now().toString(36)}`);await page.locator('#poker-settings summary').click();await page.locator('#starting-chips').fill('100');await page.locator('#create-lobby').click();await expect(page.locator('#lobby-discovery')).toBeVisible();expect(await page.locator('#starting-chips').evaluate(node=>node.validity.valid)).toBe(false);
  await page.locator('#starting-chips').fill('500');await page.locator('#table-blinds').selectOption('10');await page.locator('#turn-seconds').selectOption('15');await page.locator('#room-capacity').selectOption('2');expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);await page.screenshot({path:'/tmp/poker-settings-mobile.png',fullPage:true});await page.locator('#create-lobby').click();await expect(page.locator('#room-message')).toContainText('500 play chips · 5/10 blinds · 15-second turns · No rebuys');await page.locator('#add-bot').click();await expect(page.locator('#start-game')).toBeEnabled();await page.locator('#start-game').click();await expect(page.locator('#poker-rules')).toContainText('5/10 blinds · 15s');await page.reload();await expect(page.locator('#poker-rules')).toContainText('5/10 blinds · 15s');await expect(page.locator('#poker-rebuy')).toBeHidden();
 }finally{await cleanup([page],[context]);}
});
