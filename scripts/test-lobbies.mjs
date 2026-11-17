import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
const url = process.env.VITE_SUPABASE_URL;
const key = process.env.VITE_SUPABASE_PUBLISHABLE_KEY;
assert.ok(['127.0.0.1','localhost'].includes(new URL(url).hostname), 'Lobby integration tests only run locally.');
const clients = [];
function sql(query) {
  const result = spawnSync('sg', ['docker', '-c', 'docker exec -i supabase_db_game-hub psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At'], { input: query, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
async function guest(name) {
  const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await client.auth.signInAnonymously({ options: { data: { display_name: name } } });
  assert.ifError(error);
  const result = { client, id: data.user.id, connection: crypto.randomUUID() };
  clients.push(result);
  return result;
}
async function call(guest, action, room = null, connection = guest.connection) {
  const response = await guest.client.rpc('lobby_action', { p_action: action, p_lobby: room, p_connection: connection });
  assert.ifError(response.error);
  return response.data;
}
async function denied(guest, action, room) {
  const { error } = await guest.client.rpc('lobby_action', { p_action: action, p_lobby: room, p_connection: guest.connection });
  assert.ok(error, `${action} should be denied`);
}
function expire(room, user, connection = null) {
  for (const value of [room,user,...(connection ? [connection] : [])]) assert.match(value, /^[a-f0-9-]{36}$/);
  sql(`update game_private.connections set expires_at=now()-interval '1 second' where lobby_id='${room}' and user_id='${user}'${connection ? ` and connection_id='${connection}'` : ''}; select game_private.sweep_lobbies();`);
}
try {
  const host = await guest('Host');
  const second = await guest('Guest');
  const third = await guest('Third');
  const outsider = await guest('Outsider');
  const publicClient = createClient(url,key,{auth:{persistSession:false}});
  assert.ok((await publicClient.rpc('lobby_action',{p_action:'create',p_connection:crypto.randomUUID()})).error);
  assert.ok((await publicClient.from('lobby_summaries').select('*')).error);
  let room = await call(host,'create');
  await denied(host,'start',room);
  await denied(outsider,'snapshot',room);
  const memberChannel = host.client.channel(`lobby:${room}`, { config: { private: true, presence: { enabled: true } } });
  const memberStatus = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Member Presence connection timed out.')), 10000);
    memberChannel.subscribe(status => {
      if (['SUBSCRIBED', 'CHANNEL_ERROR', 'TIMED_OUT'].includes(status)) { clearTimeout(timeout); resolve(status); }
    });
  });
  assert.equal(memberStatus, 'SUBSCRIBED');
  assert.equal(await memberChannel.track({user_id: host.id}), 'ok');
  await host.client.removeChannel(memberChannel);
  const strangerChannel = outsider.client.channel(`lobby:${room}`, { config: { private: true, presence: { enabled: true } } });
  const strangerStatus = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Presence authorization check timed out.')), 10000);
    strangerChannel.subscribe(status => {
      if (['SUBSCRIBED', 'CHANNEL_ERROR', 'TIMED_OUT'].includes(status)) { clearTimeout(timeout); resolve(status); }
    });
  });
  assert.equal(strangerStatus, 'CHANNEL_ERROR', 'Nonmembers must not subscribe to private room presence.');
  await outsider.client.removeChannel(strangerChannel);
  const race = await Promise.all([second,third].map(g=>g.client.rpc('lobby_action',{p_action:'join',p_lobby:room,p_connection:g.connection})));
  assert.equal(race.filter(r=>!r.error).length,1,'Only one competing guest may claim O.');
  const winner = race[0].error ? third : second;
  const loser = race[0].error ? second : third;
  assert.equal((await call(host,'snapshot',room)).members.length,2);
  await denied(winner,'start',room);
  const { data: summaries,error: summaryError } = await host.client.from('lobby_summaries').select('*').eq('id',room);
  assert.ifError(summaryError);
  assert.equal(summaries[0].player_count,2);
  assert.equal(summaries[0].capacity,2);
  assert.ok(!('host_id' in summaries[0]));
  assert.ok((await winner.client.from('lobby_summaries').update({player_count:0}).eq('id',room)).error);
  assert.ok((await winner.client.schema('game_private').from('memberships').select('*')).error);
  await Promise.all([call(host,'start',room),call(host,'start',room)]);
  let snapshot=await call(winner,'snapshot',room);
  assert.equal(snapshot.status,'playing');
  assert.equal(snapshot.match.board.length,9);
  assert.equal(snapshot.match.current_turn,'X');
  await denied(loser,'join',room);
  await denied(outsider,'snapshot',room);
  await call(host,'leave',room);
  snapshot=await call(winner,'snapshot',room);
  assert.equal(snapshot.status,'closed');
  assert.equal(snapshot.match.status,'aborted');
  await call(winner,'leave',room);
  console.log('PASS: atomic joins, host-only/idempotent start, restricted reads/writes, and departure abort.');

  room=await call(host,'create');
  await call(second,'join',room);
  await call(second,'leave',room);
  assert.equal((await call(host,'snapshot',room)).members.length,1);
  await call(third,'join',room);
  const otherConnection=crypto.randomUUID();
  await call(host,'heartbeat',room,otherConnection);
  expire(room,host.id,host.connection);
  assert.equal((await call(host,'snapshot',room)).status,'waiting','Another tab keeps the host online.');
  expire(room,third.id);
  assert.equal((await call(host,'snapshot',room)).members.length,1,'Expired waiting guest frees O.');
  await call(second,'join',room);
  await call(host,'start',room);
  expire(room,second.id);
  snapshot=await call(host,'snapshot',room);
  assert.equal(snapshot.status,'closed');
  assert.equal(snapshot.match.status,'aborted');
  await call(host,'leave',room);
  await call(second,'leave',room);
  console.log('PASS: guest leave, lease expiration, multiple connections, and active-match disconnect.');

  room=await call(host,'create');
  await call(second,'join',room);
  expire(room,host.id);
  assert.equal((await call(second,'snapshot',room)).status,'closed');
  await call(host,'leave',room); await call(second,'leave',room);
  const duplicateCreate = await Promise.all([0,1].map(()=>host.client.rpc('lobby_action',{p_action:'create',p_connection:host.connection})));
  assert.equal(duplicateCreate.filter(r=>!r.error).length,1,'A guest cannot host two simultaneous rooms.');
  room=duplicateCreate.find(r=>!r.error).data;
  assert.equal(await call(host,'current'),room);
  await call(host,'leave',room);
  assert.match(room, /^[a-f0-9-]{36}$/);
  sql(`update game_private.lobbies set closed_at=now()-interval '8 days' where id='${room}'; select game_private.sweep_lobbies();`);
  assert.equal(sql(`select count(*) from game_private.lobbies where id='${room}'`),'0');
  assert.equal(sql("select count(*) from cron.job where jobname='game-hub-lobby-cleanup' and active"),'1');
  for (let index=0; index<10; index++) { const limitedRoom=await call(outsider,'create'); await call(outsider,'leave',limitedRoom); }
  await denied(outsider,'create',null);
  console.log('PASS: host timeout, current lobby recovery, per-guest serialization, creation limit, and scheduled cleanup.');
} finally {
  for (const guest of clients) {
    try { const room=await call(guest,'current'); if(room) await call(guest,'leave',room); } catch {}
    await guest.client.auth.signOut();
    await guest.client.removeAllChannels();
  }
}
