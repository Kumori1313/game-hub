import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
const url=process.env.VITE_SUPABASE_URL, key=process.env.VITE_SUPABASE_PUBLISHABLE_KEY;
assert.ok(['localhost','127.0.0.1'].includes(new URL(url).hostname),'Adversarial tests only run locally.');
const guests=[];
// Bound test requests so an unavailable local endpoint fails instead of hanging CI.
const originalFetch = globalThis.fetch;
globalThis.fetch = (input, options = {}) => originalFetch(input, { ...options, signal: options.signal
  ? AbortSignal.any([options.signal, AbortSignal.timeout(15000)]) : AbortSignal.timeout(15000) });
const validId=id=>assert.match(id,/^[a-f0-9-]{36}$/);
function sql(query) {
  const result=spawnSync('sg',['docker','-c','docker exec -i supabase_db_game-hub psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At'],{input:query,encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);return result.stdout.trim();
}
async function guest(name) {
  const client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data,error}=await client.auth.signInAnonymously({options:{data:{display_name:name}}});assert.ifError(error);
  const value={client,id:data.user.id,token:data.session.access_token,connection:crypto.randomUUID()};guests.push(value);return value;
}
async function action(g,kind,room=null) {
  const response=await g.client.rpc('lobby_action',{p_action:kind,p_lobby:room,p_connection:g.connection});assert.ifError(response.error);return response.data;
}
async function rejected(g,body) { const response=await g.client.rpc('lobby_action',body);assert.ok(response.error);assert.ok(!response.data); }
async function move(g,room,cell,revision) {
  const response=await g.client.rpc('play_move',{p_lobby:room,p_cell:cell,p_revision:revision});assert.ifError(response.error);return response.data;
}
async function deniedMove(g,room,cell,revision) {
  const response=await g.client.rpc('play_move',{p_lobby:room,p_cell:cell,p_revision:revision});assert.ok(response.error);assert.ok(!response.data);
}
async function raw(token,body) {
  return fetch(`${url}/rest/v1/rpc/lobby_action`,{method:'POST',headers:{apikey:key,Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(body)});
}
let host,other,outsider,room;
async function clearRoom() {
  if(room) for(const g of [host,other]) { try {await action(g,'leave',room);}catch{} }
  room=null;
}
async function newMatch() {
  await clearRoom();
  // Keep repeated game-rule fixtures outside the separate, already-tested creation window.
  validId(host.id);
  sql(`update game_private.lobbies set created_at=now()-interval '2 minutes' where host_id='${host.id}' and status in ('closed','finished');`);
  room=await action(host,'create');await action(other,'join',room);await action(host,'start',room);return room;
}
try {
  host=await guest('Security host');other=await guest('Security guest');outsider=await guest('Security outsider');
  room=await action(host,'create');await action(other,'join',room);
  for(const kind of [null,'','unknown','MOVE','prune_lobby']) await rejected(outsider,{p_action:kind,p_lobby:room});
  for(const kind of ['snapshot','heartbeat','leave','start']) await rejected(outsider,{p_action:kind,p_lobby:room,p_connection:outsider.connection});
  await rejected(outsider,{p_action:'start',p_lobby:room,p_user_id:host.id});
  const {error: metadataError}=await outsider.client.auth.updateUser({data:{role:'host',user_id:host.id,is_admin:true}});assert.ifError(metadataError);
  await rejected(outsider,{p_action:'start',p_lobby:room});
  await rejected(outsider,{p_action:'snapshot',p_lobby:room});
  for(const table of ['game_catalog','lobby_summaries']) {
    assert.ok((await outsider.client.from(table).insert(table==='game_catalog'?{id:'fake',name:'Fake',capacity:2}:{id:room})).error);
    assert.ok((await outsider.client.from(table).update(table==='game_catalog'?{name:'Fake'}:{player_count:0}).eq('id',table==='game_catalog'?'tic-tac-toe':room)).error);
    assert.ok((await outsider.client.from(table).delete().eq('id',table==='game_catalog'?'tic-tac-toe':room)).error);
  }
  const {data: summary}=await outsider.client.from('lobby_summaries').select('*').eq('id',room).single();
  assert.deepEqual(Object.keys(summary).sort(),['id','game_id','title','player_count','capacity','status','host_expires_at','created_at'].sort());
  const jwt=outsider.token.split('.');const claims=JSON.parse(Buffer.from(jwt[1],'base64url'));claims.sub=host.id;claims.role='service_role';
  jwt[1]=Buffer.from(JSON.stringify(claims)).toString('base64url');
  const forged=await raw(jwt.join('.'),{p_action:'snapshot',p_lobby:room});assert.ok([401,403].includes(forged.status));
  const hostExpiry=sql(`select max(expires_at) from game_private.connections where lobby_id='${room}' and user_id='${host.id}'`);
  await other.client.rpc('lobby_action',{p_action:'heartbeat',p_lobby:room,p_connection:host.connection});
  assert.equal(sql(`select max(expires_at) from game_private.connections where lobby_id='${room}' and user_id='${host.id}'`),hostExpiry);
  for(const name of ['lobbies','memberships','connections','matches','request_buckets']) {
    assert.equal(sql(`select has_table_privilege('authenticated','game_private.${name}','select') or has_table_privilege('authenticated','game_private.${name}','update')`),'f');
  }
  assert.equal(sql("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','game_private') and c.relkind='r' and not c.relrowsecurity"),'0');
  assert.equal(sql("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='game_private' and p.prosecdef and not exists(select 1 from unnest(p.proconfig) setting where setting like 'search_path=%')"),'0');
  for(const signature of ['valid_actor()','consume_budget(uuid)','sweep_lobbies()','close_lobby(uuid,text)','prune_lobby(uuid)']) {
    assert.equal(sql(`select has_function_privilege('authenticated','game_private.${signature}','execute')`),'f');
  }
  console.log('PASS: null/unknown actions, metadata impersonation, forged JWTs, identity targeting, public-write denial, and private grants.');

  await action(host,'start',room);
  sql(`insert into public.game_catalog values('security-other-game','Other rules',2); update game_private.lobbies set game_id='security-other-game' where id='${room}';`);
  try { await deniedMove(host,room,0,0); }
  finally { sql(`update game_private.lobbies set game_id='tic-tac-toe' where id='${room}'; delete from public.game_catalog where id='security-other-game';`); }
  for(const [cell,rev] of [[null,0],[-1,0],[9,0],[0,null],[0,-1],[0,9],[1.5,0]]) await deniedMove(host,room,cell,rev);
  await deniedMove(other,room,0,0);await deniedMove(outsider,room,0,0);
  const race=await Promise.all([0,2].map(cell=>host.client.rpc('play_move',{p_lobby:room,p_cell:cell,p_revision:0})));
  assert.equal(race.filter(r=>!r.error).length,1);
  let snapshot=await action(host,'snapshot',room);
  assert.equal(snapshot.match.revision,1);assert.equal(snapshot.match.board.filter(cell=>cell!==null).length,1);
  const occupied=snapshot.match.board.findIndex(cell=>cell!==null);
  await deniedMove(other,room,occupied,1);await deniedMove(host,room,4,1);await deniedMove(host,room,8,0);
  assert.equal((await action(host,'snapshot',room)).match.revision,1);
  console.log('PASS: typed/ranged inputs, nonmember/out-of-turn moves, occupied cells, duplicate/stale requests, and concurrent writes.');

  const wins=[[0,3,1,4,2],[3,0,4,1,5],[6,0,7,1,8],[0,1,3,2,6],[1,0,4,2,7],[2,0,5,1,8],[0,1,4,2,8],[2,0,4,1,6]];
  for(const sequence of wins) {
    await newMatch();
    for(let revision=0; revision<sequence.length; revision++) snapshot=await move(revision%2?other:host,room,sequence[revision],revision);
    assert.equal(snapshot.status,'finished');assert.equal(snapshot.match.winner,'X');assert.equal(snapshot.match.revision,5);
    assert.equal(snapshot.match.winning_line.length,3);
    const frozen=structuredClone(snapshot.match);
    await deniedMove(host,room,8,5);await rejected(host,{p_action:'start',p_lobby:room});
    assert.deepEqual((await action(other,'snapshot',room)).match,frozen);
  }
  await newMatch();
  for(const [revision,cell] of [0,3,1,4,8,5].entries()) snapshot=await move(revision%2?other:host,room,cell,revision);
  assert.equal(snapshot.match.winner,'O');assert.equal(snapshot.match.revision,6);
  for(const [sequence,winner] of [[[0,1,2,4,3,5,7,6,8],null],[[0,1,2,3,4,5,7,6,8],'X']]) {
    await newMatch();
    for(const [revision,cell] of sequence.entries()) snapshot=await move(revision%2?other:host,room,cell,revision);
    assert.equal(snapshot.status,'finished');assert.equal(snapshot.match.revision,9);assert.equal(snapshot.match.winner,winner);
  }
  validId(room);
  sql(`update game_private.connections set expires_at=now()-interval '1 second' where lobby_id='${room}'; select game_private.sweep_lobbies();`);
  snapshot=await action(host,'snapshot',room);assert.equal(snapshot.status,'finished');assert.equal(snapshot.match.winner,'X');
  await action(host,'leave',room);assert.equal((await action(other,'snapshot',room)).match.winner,'X');
  await action(other,'leave',room);room=null;
  console.log('PASS: eight win lines, O wins, draws, ninth-move win priority, terminal immutability, and preserved results on timeout/leave.');

  room=await action(host,'create');await action(other,'join',room);
  await Promise.all([host.client.rpc('lobby_action',{p_action:'start',p_lobby:room}),other.client.rpc('lobby_action',{p_action:'leave',p_lobby:room})]);
  snapshot=await action(host,'snapshot',room);assert.notEqual(snapshot.status,'playing');
  await clearRoom();
  room=await action(host,'create');
  sql(`update game_private.request_buckets set window_start=date_trunc('minute',now()),request_count=600 where user_id='${host.id}';`);
  await rejected(host,{p_action:'snapshot',p_lobby:room});
  await action(host,'leave',room);
  room=null;
  sql(`update game_private.request_buckets set window_start=now()-interval '2 minutes' where user_id='${host.id}';`);
  assert.equal(await action(host,'current'),null);
  console.log('PASS: concurrent start/leave consistency and server-side RPC budget/reset.');

  const ended=await guest('Revoked guest');
  const owned=await action(ended,'create');
  const savedToken=ended.token;
  await ended.client.auth.signOut();
  const replay=await raw(savedToken,{p_action:'heartbeat',p_lobby:owned,p_connection:ended.connection});
  assert.ok([401,403].includes(replay.status),'A signed-out session must not keep renewing a lease.');
  validId(owned);
  sql(`update game_private.connections set expires_at=now()-interval '1 second' where lobby_id='${owned}'; select game_private.sweep_lobbies();`);
  const banned=await guest('Banned guest');validId(banned.id);
  sql(`update auth.users set banned_until=now()+interval '1 hour' where id='${banned.id}';`);
  await rejected(banned,{p_action:'create',p_connection:banned.connection});
  sql(`update auth.users set banned_until=null where id='${banned.id}';`);
  const endedSession=JSON.parse(Buffer.from(banned.token.split('.')[1],'base64url')).session_id;validId(endedSession);
  sql(`update auth.sessions set not_after=now()-interval '1 second' where id='${endedSession}';`);
  await rejected(banned,{p_action:'create',p_connection:banned.connection});
  console.log('PASS: signed-out token replay, banned identities, and expired server sessions.');
} finally {
  await clearRoom();
  for(const g of guests) { try { const current=await action(g,'current'); if(current) await action(g,'leave',current); }catch{} await g.client.auth.signOut();await g.client.removeAllChannels(); }
}
