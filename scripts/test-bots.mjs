import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
const url=process.env.VITE_SUPABASE_URL,key=process.env.VITE_SUPABASE_PUBLISHABLE_KEY;
assert.ok(['127.0.0.1','localhost'].includes(new URL(url).hostname),'Bot fixtures run locally only.');
const originalFetch=globalThis.fetch;
globalThis.fetch=(input,options={})=>originalFetch(input,{...options,signal:options.signal?AbortSignal.any([options.signal,AbortSignal.timeout(15000)]):AbortSignal.timeout(15000)});
const guests=[];let room;
function sql(query){const r=spawnSync('sg',['docker','-c','docker exec -i supabase_db_game-hub psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At'],{input:query,encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
async function guest(){const client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});const r=await client.auth.signInAnonymously({options:{data:{display_name:'Bot test'}}});assert.ifError(r.error);const g={client,id:r.data.user.id,connection:crypto.randomUUID()};guests.push(g);return g;}
async function raw(g,fn,args){return g.client.rpc(fn,args);}
async function rpc(g,fn,args){const r=await raw(g,fn,args);assert.ifError(r.error);assert.ok(!r.data?.error,r.data?.error);return r.data;}
async function action(g,kind,id=room,extra={}){return rpc(g,'room_action',{p_game:'poker',p_action:kind,p_lobby:id,p_connection:g.connection,...extra});}
async function bot(g,kind,seat=null){return rpc(g,'poker_bot',{p_lobby:room,p_action:kind,p_seat:seat});}
async function denied(g,fn,args){const r=await raw(g,fn,args);assert.ok(r.error||r.data?.error,'Expected denied operation');}
function conserved(){assert.equal(sql(`select sum(stack+committed)=(select minted from game_private.poker_tables where lobby_id='${room}') from game_private.poker_players where lobby_id='${room}'`),'t');}
async function finish(host){
 for(let i=0;i<180;i++){
  let state=await action(host,'snapshot');conserved();if(state.poker.street==='complete')return state;
  const turn=state.poker.players.find(p=>p.seat===state.poker.turn_seat);
  if(turn.is_bot){sql(`update game_private.poker_tables set deadline=now()-interval '1 second' where lobby_id='${room}'`);}
  else{
   const g=guests.find(g=>g.id===turn.user_id);assert.ok(g);
   await rpc(g,'poker_action',{p_lobby:room,p_action:state.poker.actions.can_check&&g===host?'check':'call',p_hand:state.poker.hand_id,p_revision:state.poker.revision});
  }
 }
 assert.fail('Hand exceeded the action bound');
}
try{
 const host=await guest(),other=await guest(),outsider=await guest();
 room=await action(host,'create',null,{p_capacity:4});await action(other,'join');
 await denied(other,'poker_bot',{p_lobby:room,p_action:'add'});await denied(outsider,'poker_bot',{p_lobby:room,p_action:'add'});
 await denied(host,'poker_bot',{p_lobby:room,p_action:'remove',p_seat:1});await denied(host,'poker_bot',{p_lobby:room,p_action:'add',p_seat:3});
 let state=await bot(host,'add');assert.equal(state.members.filter(p=>p.is_bot).length,1);
 await bot(host,'add');await denied(host,'poker_bot',{p_lobby:room,p_action:'add'});
 assert.equal(sql(`select player_count from public.lobby_summaries where id='${room}'`),'4');
 await denied(outsider,'room_action',{p_game:'poker',p_action:'join',p_lobby:room,p_connection:outsider.connection});
 await bot(host,'remove',3);await action(outsider,'join');state=await action(host,'snapshot');assert.equal(state.members.find(p=>p.user_id===outsider.id).seat,3);
 await action(outsider,'leave');await bot(host,'add');
 const before=sql('select count(*) from auth.users');
 await rpc(host,'poker_action',{p_lobby:room,p_action:'start'});state=await action(host,'snapshot');
 assert.equal(state.poker.players.filter(p=>p.is_bot).length,2);assert.equal(sql('select count(*) from auth.users'),before);
 assert.equal(sql(`select count(*) from game_private.poker_players where lobby_id='${room}' and is_bot and human_user_id is not null`),'0');
 assert.equal(state.poker.players.filter(p=>p.cards!==null).length,1);
 assert.equal(state.poker.players.filter(p=>p.is_bot).every(p=>p.cards===null),true);
 await denied(host,'poker_bot',{p_lobby:room,p_action:'remove',p_seat:3});
 state=await finish(host);assert.equal(state.poker.street,'complete');conserved();
 if(state.status==='playing'){state=await rpc(host,'poker_action',{p_lobby:room,p_action:'next',p_hand:state.poker.hand_id,p_revision:state.poker.revision});assert.equal(state.poker.hand_no,2);}
 await action(host,'leave');state=await action(other,'snapshot');assert.equal(state.host_id,other.id);
 await action(other,'leave');assert.equal(sql(`select status from game_private.lobbies where id='${room}'`),'closed');
 console.log('PASS: host-only bot management, mixed seats, capacity, human seat reuse, privacy, no bot Auth accounts, legal hands, chip conservation, next hands, and human-only ownership.');
 // A bot addition and human join compete for exactly one remaining seat.
 room=await action(host,'create',null,{p_capacity:2});
 const race=await Promise.all([raw(host,'poker_bot',{p_lobby:room,p_action:'add'}),raw(other,'room_action',{p_game:'poker',p_action:'join',p_lobby:room,p_connection:other.connection})]);
 assert.equal(race.filter(r=>!r.error&&!r.data?.error).length,1);state=await action(host,'snapshot');assert.equal(state.members.length,2);assert.equal(new Set(state.members.map(p=>p.seat)).size,2);
 if(state.members.some(p=>p.user_id===other.id)){await action(other,'leave');await bot(host,'add');}
 await rpc(host,'poker_action',{p_lobby:room,p_action:'start'});state=await action(host,'snapshot');
 // Acting as a bot from a browser is impossible: actor always comes from the caller's session.
 if(state.poker.players.find(p=>p.seat===state.poker.turn_seat).is_bot)await denied(host,'poker_action',{p_lobby:room,p_action:'call',p_hand:state.poker.hand_id,p_revision:state.poker.revision});
 state=await finish(host);conserved();await action(host,'leave');
 // Exercise the largest supported table without waiting on wall-clock bot delays.
 room=await action(host,'create',null,{p_capacity:6});for(let i=0;i<5;i++)await bot(host,'add');
 await rpc(host,'poker_action',{p_lobby:room,p_action:'start'});state=await action(host,'snapshot');assert.equal(state.poker.players.filter(p=>p.is_bot).length,5);assert.equal(state.poker.players.length,6);
 state=await finish(host);conserved();
 assert.equal(sql(`select has_table_privilege('authenticated','game_private.room_bots','select')`),'f');
 for(const sig of ['poker_apply(uuid,uuid,text,bigint)','poker_bot_turn(uuid)','poker_visible_score(smallint[])','poker_bot_choice(smallint[],smallint[],bigint,bigint,bigint,bigint,bigint,bigint,boolean)'])assert.equal(sql(`select has_function_privilege('authenticated','game_private.${sig}','execute')`),'f');
 assert.equal(sql("select has_function_privilege('anon','public.poker_bot(uuid,text,integer)','execute')"),'f');
 console.log('PASS: simultaneous human/bot final-seat allocation, solo play, five-bot full hands, restricted helpers, and no human impersonation of bots.');
 await action(host,'leave');room=await action(host,'create',null,{p_capacity:2,p_visibility:'private'});await bot(host,'add');
 assert.equal(sql(`select count(*) from public.lobby_summaries where id='${room}'`),'0');
 await rpc(host,'poker_action',{p_lobby:room,p_action:'start'});
 sql(`update game_private.connections set expires_at=now()-interval '1 second' where lobby_id='${room}';select game_private.prune_lobby('${room}');`);
 assert.equal(sql(`select status from game_private.lobbies where id='${room}'`),'closed');const revision=sql(`select revision from game_private.poker_tables where lobby_id='${room}'`);
 sql(`select game_private.poker_tick('${room}');select game_private.poker_tick('${room}');`);assert.equal(sql(`select revision from game_private.poker_tables where lobby_id='${room}'`),revision);conserved();
 console.log('PASS: code-only bot tables stay private, expire with their last human, and stop bot actions after closure.');

}finally{
 for(const g of guests){try{const id=await action(g,'current',null);if(id)await action(g,'leave',id);}catch{}await g.client.auth.signOut();}
}
