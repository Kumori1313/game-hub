import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {createClient} from '@supabase/supabase-js';
const url=process.env.VITE_SUPABASE_URL,key=process.env.VITE_SUPABASE_PUBLISHABLE_KEY;
assert.ok(['127.0.0.1','localhost'].includes(new URL(url).hostname),'Settings fixtures run locally only.');
const originalFetch=globalThis.fetch;globalThis.fetch=(input,options={})=>originalFetch(input,{...options,signal:options.signal?AbortSignal.any([options.signal,AbortSignal.timeout(15000)]):AbortSignal.timeout(15000)});
let room;const guests=[];
function sql(query){const r=spawnSync('sg',['docker','-c','docker exec -i supabase_db_game-hub psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At'],{input:query,encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
async function guest(){const client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});const r=await client.auth.signInAnonymously({options:{data:{display_name:'Settings test'}}});assert.ifError(r.error);const g={client,id:r.data.user.id,connection:crypto.randomUUID()};guests.push(g);return g;}
async function rpc(g,fn,args){const r=await g.client.rpc(fn,args);assert.ifError(r.error);assert.ok(!r.data?.error,r.data?.error);return r.data;}
async function denied(g,fn,args){const r=await g.client.rpc(fn,args);assert.ok(r.error||r.data?.error,'Expected denied request');return r;}
async function action(g,kind,id=room,extra={}){return rpc(g,'room_action',{p_game:'poker',p_action:kind,p_lobby:id,p_connection:g.connection,...extra});}
async function poker(g,kind,state,extra={}){return rpc(g,'poker_table_action',{p_lobby:room,p_action:kind,p_hand:state?.poker.hand_id,p_revision:state?.poker.revision,...extra});}
async function create(g,settings={},extra={}){room=await rpc(g,'create_poker_room',{p_capacity:2,p_visibility:'public',p_settings:settings,p_connection:g.connection,...extra});return action(g,'snapshot');}
function conserved(){assert.equal(sql(`select sum(stack+committed)=(select minted from game_private.poker_tables where lobby_id='${room}') from game_private.poker_players where lobby_id='${room}'`),'t');sql(`select game_private.poker_assert('${room}')`);}
function forceWin(bot=false){sql(`update game_private.poker_players set stack=stack+committed,street_bet=0,committed=0,hole=case when seat=1 then array[12,25]::smallint[] else array[11,24]::smallint[] end,folded=false,in_hand=true,acted=false,last_bet=0,last_raise=500 where lobby_id='${room}';update game_private.poker_tables set street='river',board=array[0,14,31,45,7]::smallint[],turn_seat=${bot?2:1},current_bet=0,min_raise=(select big_blind from game_private.poker_settings where lobby_id='${room}'),deadline=now()+interval '5 minutes' where lobby_id='${room}';`);}
async function clear(){for(const g of guests){const id=await action(g,'current',null);if(id)await action(g,'leave',id);}}
try{
 const host=await guest(),other=await guest(),outsider=await guest();
 for(const settings of [null,[],{unknown:1},{starting_chips:'1000'},{starting_chips:true},{starting_chips:100.5},{starting_chips:-100},{starting_chips:10001},{starting_chips:100,big_blind:20},{big_blind:40},{turn_seconds:91},{rebuy_limit:2},{rebuy_limit:10000000}])await denied(host,'create_poker_room',{p_connection:host.connection,p_settings:settings});
 for(const capacity of [1,7])await denied(host,'create_poker_room',{p_connection:host.connection,p_capacity:capacity});
 assert.equal(sql(`select count(*) from game_private.lobbies where host_id='${host.id}'`),'0');
 let state=await create(host);assert.deepEqual(state.settings,{starting_chips:1000,small_blind:10,big_blind:20,turn_seconds:30,rebuy_limit:0,locked:true});await clear();
 const settings={starting_chips:10000,big_blind:500,turn_seconds:90,rebuy_limit:3};state=await create(host,settings,{p_visibility:'private'});const agreed=state.settings;
 assert.equal(sql(`select count(*) from public.lobby_summaries where id='${room}'`),'0');await action(other,'join_code',null,{p_code:state.join_code});
 const guestView=await action(other,'snapshot');assert.deepEqual(guestView.settings,agreed);
 await denied(host,'poker_action',{p_lobby:room,p_action:'start'});state=await poker(host,'start');assert.deepEqual(state.settings,agreed);assert.deepEqual(state.poker.blinds,[250,500]);assert.equal(state.poker.players.reduce((sum,p)=>sum+p.stack+p.committed,0),20000);
 let remaining=Date.parse(state.poker.deadline)-Date.parse(state.poker.server_time);assert.ok(remaining>=89000&&remaining<=92000);
 for(let i=0;i<2;i++){const actor=guests.find(g=>g.id===state.poker.players.find(p=>p.seat===state.poker.turn_seat).user_id);state=await poker(actor,'call',state);}
 assert.equal(state.poker.street,'flop');assert.equal(state.poker.min_raise_to,500);remaining=Date.parse(state.poker.deadline)-Date.parse(state.poker.server_time);assert.ok(remaining>=89000&&remaining<=92000);
 await denied(other,'poker_table_action',{p_lobby:room,p_action:'rebuy',p_hand:state.poker.hand_id,p_revision:state.poker.revision});
 for(let cycle=0;cycle<4;cycle++){
  forceWin();state=await action(host,'snapshot');state=await poker(host,'all_in',state);state=await poker(other,'call',state);assert.equal(state.poker.street,'complete');assert.equal(state.poker.players.find(p=>p.user_id===other.id).stack,0);conserved();
  if(cycle===3){assert.equal(state.status,'finished');await denied(other,'poker_table_action',{p_lobby:room,p_action:'rebuy',p_hand:state.poker.hand_id,p_revision:state.poker.revision});break;}
  const request={p_lobby:room,p_action:'rebuy',p_hand:state.poker.hand_id,p_revision:state.poker.revision};const race=await Promise.all([0,1].map(()=>other.client.rpc('poker_table_action',request)));assert.equal(race.filter(r=>!r.error&&!r.data?.error).length,1);
  state=await action(other,'snapshot');assert.equal(state.poker.players.find(p=>p.user_id===other.id).rebuy_count,cycle+1);assert.equal(state.poker.players.find(p=>p.user_id===other.id).stack,10000);conserved();
  await denied(outsider,'poker_table_action',{...request,p_revision:state.poker.revision});await denied(host,'poker_table_action',{...request,p_revision:state.poker.revision});state=await poker(host,'next',state);assert.deepEqual(state.settings,agreed);
 }
 assert.equal(sql(`select count(*) from game_private.poker_rebuys where lobby_id='${room}'`),'3');assert.equal(sql(`select minted from game_private.poker_tables where lobby_id='${room}'`),'50000');
 console.log('PASS: strict settings/capacity validation, defaults, shared locked rules, private rooms, custom blinds/clocks, bets above 6,000, concurrent human rebuys, ledger conservation, and bounded elimination.');
 await clear();state=await create(host,{starting_chips:500,big_blind:10,turn_seconds:15,rebuy_limit:1});await rpc(host,'poker_bot',{p_lobby:room,p_action:'add'});state=await poker(host,'start');
 for(let cycle=0;cycle<2;cycle++){
  forceWin(true);const bot=state.poker.players.find(p=>p.is_bot);sql(`select game_private.poker_apply('${room}','${bot.user_id}','all_in')`);state=await action(host,'snapshot');state=await poker(host,'call',state);conserved();const after=state.poker.players.find(p=>p.is_bot);assert.equal(after.rebuy_count,1);
  if(cycle===0){assert.equal(after.stack,500);assert.equal(state.status,'playing');state=await poker(host,'next',state);}else{assert.equal(after.stack,0);assert.equal(state.status,'finished');}
 }
 for(const table of ['poker_settings','poker_rebuys']){assert.equal(sql(`select has_table_privilege('authenticated','game_private.${table}','select')`),'f');assert.equal(sql(`select has_table_privilege('authenticated','game_private.${table}','update')`),'f');}
 assert.equal(sql("select has_function_privilege('authenticated','game_private.poker_rebuy(uuid,uuid)','execute')"),'f');
 console.log('PASS: bot rebuys obey the same limit and ledger; settings and rebuy helpers remain private.');
}finally{await clear();for(const g of guests)await g.client.auth.signOut();}
