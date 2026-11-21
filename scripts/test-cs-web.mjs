import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';

const url = process.env.VITE_SUPABASE_URL;
const key = process.env.VITE_SUPABASE_PUBLISHABLE_KEY;
assert.ok(['127.0.0.1', 'localhost'].includes(new URL(url).hostname), 'Run against local Supabase only.');
const clients = [];
let id;
async function guest(name) {
  const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  clients.push(client);
  const { error } = await client.auth.signInAnonymously({ options: { data: { display_name: name } } });
  assert.ifError(error);
  return { client, connection: randomUUID() };
}
const room = (g, action, extra = {}) => g.client.rpc('room_action', {
  p_game: 'cs-web', p_action: action, p_lobby: id, p_connection: g.connection, ...extra,
});
const signal = (g, message = null) => g.client.rpc('cs_web_signal', { p_lobby: id, p_message: message });
let host;
let guests;
try {
  [host, ...guests] = await Promise.all([guest('CS host'), guest('CS peer'), guest('CS outsider')]);
  const [peer, outsider] = guests;
  const created = await room(host, 'create', { p_visibility: 'private' });
  assert.ifError(created.error);
  id = created.data;
  const state = await room(host, 'snapshot');
  assert.ifError(state.error);
  assert.equal((await signal(host)).error?.code, '42501');
  assert.equal((await room(outsider, 'join')).error?.code, '42501');
  assert.ifError((await room(peer, 'join_code', { p_code: state.data.join_code })).error);
  assert.equal((await room(peer, 'start')).error?.code, '42501');
  assert.ifError((await room(host, 'start')).error);

  const peerId = randomUUID();
  const hostId = randomUUID();
  assert.equal((await signal(outsider)).error?.code, '42501');
  assert.equal((await signal(peer, { kind: 'offer', from: peerId, to: hostId, sdp: 'fixture' })).error?.code, '22023');
  const ready = { kind: 'ready', from: peerId };
  const offer = { kind: 'offer', from: hostId, to: peerId, sdp: 'fixture offer' };
  const answer = { kind: 'answer', from: peerId, to: hostId, sdp: 'fixture answer' };
  assert.ifError((await signal(peer, ready)).error);
  assert.deepEqual((await signal(host, offer)).data, ready);
  assert.deepEqual((await signal(peer, answer)).data, offer);
  assert.deepEqual((await signal(host)).data, answer);
  assert.ifError((await room(host, 'leave')).error);
  assert.equal((await signal(peer)).error?.code, '42501');
  console.log('PASS: code-only admission, host-only start, role-bound signal exchange, and signaling revoked on leave.');
} finally {
  if (id && host) await room(host, 'leave');
  await Promise.all(clients.map(client => client.auth.signOut()));
}
