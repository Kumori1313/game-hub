import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
const url=process.env.VITE_SUPABASE_URL,key=process.env.VITE_SUPABASE_PUBLISHABLE_KEY;
assert.ok(['127.0.0.1','localhost'].includes(new URL(url).hostname),'Room integration tests only run locally.');
const guests=[];
const originalFetch=globalThis.fetch;
globalThis.fetch=(input,options={})=>originalFetch(input,{...options,signal:options.signal?AbortSignal.any([options.signal,AbortSignal.timeout(15000)]):AbortSignal.timeout(15000)});
function sql(query) {
 const r=spawnSync('sg',['docker','-c','docker exec -i supabase_db_game-hub psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At'],{input:query,encoding:'utf8'});
 assert.equal(r.status,0,r.stderr);return r.stdout.trim();
}
async function guest(name) {
 const client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data,error}=await client.auth.signInAnonymously({options:{data:{display_name:name}}});assert.ifError(error);
 const g={client,id:data.user.id,connection:crypto.randomUUID(),game:'poker'};guests.push(g);return g;
}
function request(g,kind,id=null,options={}) { return g.client.rpc('room_action',{p_action:kind,p_lobby:id,p_connection:g.connection,p_game:g.game,...options}); }
async function call(g,kind,id=null,options={}) {const r=await request(g,kind,id,options);assert.ifError(r.error);assert.ok(!r.data?.error,r.data?.error);return r.data;}
async function denied(g,kind,id=null,options={}) {const r=await request(g,kind,id,options);assert.ok(r.error||r.data?.error,`${kind} should be denied`);return r;}
async function leaveAll() {for(const g of guests) {try{const id=await call(g,'current');if(id) await call(g,'leave',id);}catch{}}}
try {
 const host=await guest('Room host'), members=await Promise.all(Array.from({length:6},(_,i)=>guest(`Guest ${i}`))), outsider=await guest('Code guest');
 for(const capacity of [0,1,7,2.5]) await denied(host,'create',null,{p_capacity:capacity});
 await denied(host,'create',null,{p_visibility:null});await denied(host,'create',null,{p_visibility:'unlisted'});
 let id=await call(host,'create',null,{p_capacity:6});
 const race=await Promise.all(members.map(g=>request(g,'join',id)));
 assert.equal(race.filter(r=>!r.error).length,5);
 let state=await call(host,'snapshot',id);
 assert.equal(state.capacity,6);assert.equal(state.members.length,6);
 assert.deepEqual(state.members.map(m=>m.seat),[1,2,3,4,5,6]);assert.ok(state.members.every(m=>m.mark===null));
 assert.equal(state.playable,true);assert.equal(sql(`select count(*) from game_private.matches where lobby_id='${id}'`),'0');
 const admitted=members.find((g,i)=>!race[i].error);
 await call(admitted,'leave',id);await call(outsider,'join',id);
 assert.equal((await call(host,'snapshot',id)).members.length,6);
 await denied(outsider,'start',id);
 await denied(host,'start',id);const begin=await host.client.rpc('poker_action',{p_lobby:id,p_action:'start'});assert.ifError(begin.error);assert.equal((await call(host,'snapshot',id)).poker.hand_no,1);
 await leaveAll();
 // A host-selected lower capacity is authoritative even though poker supports six.
 id=await call(host,'create',null,{p_capacity:3});
 const smaller=await Promise.all(members.slice(0,3).map(g=>request(g,'join',id)));
 assert.equal(smaller.filter(r=>!r.error).length,2);assert.equal((await call(host,'snapshot',id)).members.length,3);
 await leaveAll();
 console.log('PASS: 2–6 seat capacity validation, six-way joins, bounded smaller rooms, seat reuse, and host-only poker start.');

 id=await call(host,'create',null,{p_capacity:3,p_visibility:'private'});
 state=await call(host,'snapshot',id);const code=state.join_code;assert.match(code,/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}$/);
 const publicRows=await outsider.client.from('lobby_summaries').select('*').eq('id',id);assert.ifError(publicRows.error);assert.deepEqual(publicRows.data,[]);
 await denied(outsider,'snapshot',id);await denied(outsider,'join',id);await denied(outsider,'join',id,{p_code:code});
 const before=Number(sql(`select request_count from game_private.request_buckets where user_id='${outsider.id}'`));
 for(const bad of ['not-a-code','0000000000000000',code+'too-long']) await denied(outsider,'join_code',null,{p_code:bad});
 const after=Number(sql(`select request_count from game_private.request_buckets where user_id='${outsider.id}'`));assert.equal(after-before,3);
 await call(outsider,'join_code',null,{p_code:' '+code.slice(0,2).toLowerCase()+'-'+code.slice(2).toLowerCase()+' '});
 await call(outsider,'join_code',null,{p_code:code}); // repeat admission is idempotent
 assert.equal((await call(outsider,'snapshot',id)).join_code,code);
 const wrongGame={...members[0],game:'tic-tac-toe'};
 await denied(wrongGame,'join_code',null,{p_code:code});await denied(wrongGame,'snapshot',id);
 assert.deepEqual((await outsider.client.from('lobby_summaries').select('*').eq('id',id)).data,[]);
 assert.equal(sql("select has_table_privilege('authenticated','game_private.rematch_votes','select')"),'f');
 assert.equal(sql("select has_function_privilege('authenticated','game_private.room_snapshot(uuid)','execute')"),'f');
 await leaveAll();
 const {data:longRoom,error:longError}=await host.client.rpc('create_poker_room',{
  p_capacity:2,p_visibility:'private',p_connection:host.connection,p_long_code:true,p_settings:{starting_chips:1500},
 });
 assert.ifError(longError);
 const longTable=await call(host,'snapshot',longRoom);
 assert.match(longTable.join_code,/^[0-9A-F]{16}$/);
 assert.equal(longTable.settings.starting_chips,1500);
 const formatted=longTable.join_code.toLowerCase().match(/.{4}/g).join('-');
 sql(`update game_private.request_buckets set code_window_start=date_trunc('minute',clock_timestamp()),code_attempts=9 where user_id='${outsider.id}'`);
 assert.equal((await denied(outsider,'join_code',null,{p_code:'invalid-code'})).data?.code,'ROOM_UNAVAILABLE');
 assert.equal((await denied(outsider,'join_code',null,{p_code:formatted})).data?.code,'RATE_LIMITED');
 sql(`update game_private.request_buckets set code_window_start='-infinity' where user_id='${outsider.id}'`);
 assert.equal((await call(outsider,'join_code',null,{p_code:formatted})).id,longRoom);
 await leaveAll();
 console.log('PASS: short and long codes, case-insensitive entry, private-room isolation, cross-game rejection, and persistent code-attempt limits.');

 host.game='tic-tac-toe';const other=members[0];other.game='tic-tac-toe';
 await denied(host,'create',null,{p_capacity:3});
 id=await call(host,'create');await call(other,'join',id);await call(host,'start',id);
 state=await call(host,'snapshot',id);
 assert.equal(state.members.filter(m=>m.mark==='X').length,1);assert.equal(state.members.filter(m=>m.mark==='O').length,1);
 await denied(other,'start',id);await denied(host,'rematch',id,{p_round:1});
 const x=state.members.find(m=>m.mark==='X').user_id===host.id?host:other;
 const o=x===host?other:host;
 for(const [revision,cell] of [0,3,1,4,2].entries()) {
  const actor=revision%2?o:x;const r=await actor.client.rpc('submit_move',{p_lobby:id,p_cell:cell,p_revision:revision,p_match:state.match.id});assert.ifError(r.error);state=r.data;
 }
 assert.equal(state.status,'finished');const first=structuredClone(state.match);
 const firstX=x.id;
 await call(host,'rematch',id,{p_round:1});assert.equal((await call(other,'snapshot',id)).status,'finished');
 await call(host,'cancel_rematch',id,{p_round:1});assert.ok(!(await call(host,'snapshot',id)).members.some(m=>m.rematch));
 await denied(outsider,'rematch',id,{p_round:1});
 const votes=await Promise.all([host,other,host,other].map(g=>request(g,'rematch',id,{p_round:1})));assert.ok(votes.every(r=>!r.error));
 state=await call(host,'snapshot',id);assert.equal(state.round,2);assert.equal(state.match.revision,0);assert.notEqual(state.match.id,first.id);
 assert.equal(state.status,'playing');assert.notEqual(state.members.find(m=>m.mark==='X').user_id,firstX);
 assert.ok(state.members.every(m=>!m.rematch));assert.equal(sql(`select count(*) from game_private.matches where lobby_id='${id}'`),'2');
 assert.equal(sql(`select board::text from game_private.matches where id='${first.id}'`),JSON.stringify(first.board).replaceAll(',',', '));
 const stale=await host.client.rpc('submit_move',{p_lobby:id,p_cell:8,p_revision:0,p_match:first.id});assert.ok(stale.error);
 const legacy=await host.client.rpc('play_move',{p_lobby:id,p_cell:8,p_revision:0});assert.ok(legacy.error);
 assert.equal((await call(host,'snapshot',id)).match.revision,0);
 await call(host,'rematch',id,{p_round:1});assert.equal((await call(host,'snapshot',id)).round,2);
 // A departed player cannot renew consent or alter the remaining terminal result.
 const secondX=state.members.find(m=>m.mark==='X').user_id===host.id?host:other;const secondO=secondX===host?other:host;
 for(const [revision,cell] of [0,3,1,4,2].entries()) {const r=await (revision%2?secondO:secondX).client.rpc('submit_move',{p_lobby:id,p_cell:cell,p_revision:revision,p_match:state.match.id});assert.ifError(r.error);state=r.data;}
 await call(other,'leave',id);await denied(host,'rematch',id,{p_round:2});assert.equal((await call(host,'snapshot',id)).match.winner,'X');
 await call(host,'leave',id);
 console.log('PASS: randomized first marks, two-party consent/cancellation, atomic duplicate votes, swapped marks, immutable history, stale-match rejection, and leave behavior.');
} finally {await leaveAll();for(const g of guests){await g.client.auth.signOut();await g.client.removeAllChannels();}}
