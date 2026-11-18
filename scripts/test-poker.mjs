import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
const url=process.env.VITE_SUPABASE_URL,key=process.env.VITE_SUPABASE_PUBLISHABLE_KEY;
assert.ok(['127.0.0.1','localhost'].includes(new URL(url).hostname),'Poker integration tests only run locally.');
const players=[];let room=null;
function sql(query){const r=spawnSync('sg',['docker','-c','docker exec -i supabase_db_game-hub psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At'],{input:query,encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
const card=s=>'cdhs'.indexOf(s[1])*13+'23456789TJQKA'.indexOf(s[0]);
const cards=s=>s.split(' ').map(card);
const arr=a=>`array[${a.join(',')}]::smallint[]`;
async function guest(i){const client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});const r=await client.auth.signInAnonymously({options:{data:{display_name:`Poker ${i}`}}});assert.ifError(r.error);const p={client,id:r.data.user.id,connection:crypto.randomUUID()};players.push(p);return p;}
async function action(p,kind,id=room,extra={}){const r=await p.client.rpc('room_action',{p_action:kind,p_lobby:id,p_connection:p.connection,p_game:'poker',...extra});assert.ifError(r.error);assert.ok(!r.data?.error,r.data?.error);return r.data;}
async function poker(p,kind,state,extra={}){const r=await p.client.rpc('poker_action',{p_lobby:room,p_action:kind,p_hand:state.poker.hand_id,p_revision:state.poker.revision,...extra});assert.ifError(r.error);assert.ok(!r.data?.error,r.data?.error);return r.data;}
async function denied(p,kind,state,extra={}){const r=await p.client.rpc('poker_action',{p_lobby:room,p_action:kind,p_hand:state.poker.hand_id,p_revision:state.poker.revision,...extra});assert.ok(r.error||r.data?.error,`${kind} must be denied`);return r;}
async function clear(){for(const p of players){try{const id=await action(p,'current',null);if(id)await action(p,'leave',id);}catch{}}room=null;}
async function start(n){await clear();sql(`update game_private.lobbies set created_at=now()-interval '2 minutes' where host_id='${players[0].id}' and status in ('closed','finished');`);room=await action(players[0],'create',null,{p_capacity:n});for(const p of players.slice(1,n))await action(p,'join');const begin=await players[0].client.rpc('poker_action',{p_lobby:room,p_action:'start'});assert.ifError(begin.error);return action(players[0],'snapshot');}
function actor(state){const id=state.poker.players.find(p=>p.seat===state.poker.turn_seat).user_id;return players.find(p=>p.id===id);}
function conservation(){assert.equal(sql(`select sum(stack+committed)=(select minted from game_private.poker_tables where lobby_id='${room}') from game_private.poker_players where lobby_id='${room}'`),'t');}
function fixture(stacks,{bets=stacks.map(()=>0),folded=[],acted=[],lastBet=100,board=cards('2c 3d 7h 8s 9c'),holes=['As Ah','Ks Kh','Qs Qh','Js Jh','Ts Th','5s 5h'],turn=1,current=0,min=20,dealer=1}={}){
 const t=sql(`select json_agg(json_build_object('id',user_id,'seat',seat) order by seat) from game_private.poker_players where lobby_id='${room}'`);const seated=JSON.parse(t);
 let query=`update game_private.poker_tables set street='river',board=${arr(board)},turn_seat=${turn},current_bet=${current},min_raise=${min},dealer=${dealer},deadline=now()+interval '5 minutes',showdown=false,pots='[]' where lobby_id='${room}';`;
 for(const [i,p] of seated.entries())query+=`update game_private.poker_players set stack=${stacks[i]},committed=${bets[i]},street_bet=${bets[i]},hole=${arr(cards(holes[i]))},in_hand=true,folded=${folded.includes(i+1)},departed=false,acted=${acted.includes(i+1)},last_bet=${lastBet},last_raise=${min},payout=0,rank_score=null where lobby_id='${room}' and user_id='${p.id}';`;
 sql(query);conservation();
}
try{
 for(let i=0;i<7;i++)await guest(i);
 const ranks=['As Ks Qs Js Ts','Ac Ad Ah As 2c','Ac Ad Ah Ks Kd','Ac Jc 9c 5c 3c','Ac 2d 3h 4s 5c','Ac Ad Ah Ks Qd','Ac Ad Ks Kd Qh','Ac Ad Ks Qd Jh','Ac Kd Jh 9s 7c'];
 const scores=ranks.map(hand=>BigInt(sql(`select game_private.poker_score5(${arr(cards(hand))})`)));
 for(let i=1;i<scores.length;i++)assert.ok(scores[i-1]>scores[i]);
 assert.ok(BigInt(sql(`select game_private.poker_score5(${arr(cards('2c 3d 4h 5s 6c'))})`))>scores[4]);
 assert.equal(sql(`select game_private.poker_score7(${arr(cards('Ac Ad Ah Kc Kd Kh 2c'))})`),sql(`select game_private.poker_score5(${arr(cards('Ac Ad Ah Kc Kd'))})`));
 assert.equal(sql(`select game_private.poker_score7(${arr(cards('As Ks Qs Js Ts 2d 3h'))})`),String(scores[0]));
 console.log('PASS: all hand categories, kickers, wheel straights, two-trip full houses, and seven-card selection.');
 let state=await start(3);
 const repeated=await players[0].client.rpc('poker_action',{p_lobby:room,p_action:'start'});assert.ifError(repeated.error);assert.equal(repeated.data.poker.hand_id,state.poker.hand_id);assert.equal(repeated.data.poker.revision,state.poker.revision);
 const nonhost=await players[1].client.rpc('poker_action',{p_lobby:room,p_action:'start'});assert.ok(nonhost.error);
 const badStart=await players[0].client.rpc('poker_action',{p_lobby:room,p_action:'start',p_revision:0});assert.ok(badStart.error);

 assert.equal(state.poker.board.length,0);assert.equal(state.poker.players.filter(p=>p.cards!==null).length,1);
 for(const p of players.slice(0,3)){const view=await action(p,'snapshot');assert.equal(view.poker.players.filter(x=>x.cards!==null).length,1);assert.equal(view.poker.players.find(x=>x.cards!==null).user_id,p.id);assert.ok(!('deck' in view.poker));}
 const outsider=await players[6].client.rpc('room_action',{p_action:'snapshot',p_lobby:room,p_game:'poker'});assert.ok(outsider.error);
 await denied(players[6],'fold',state);
 for(const name of ['poker_tables','poker_players','poker_hands'])assert.equal(sql(`select has_table_privilege('authenticated','game_private.${name}','select')`),'f');
 for(const signature of ['poker_view(uuid,uuid)','poker_score7(smallint[])','poker_new_hand(uuid)','poker_tick(uuid)'])assert.equal(sql(`select has_function_privilege('authenticated','game_private.${signature}','execute')`),'f');
 await denied(players.find(p=>p.id!==actor(state).id),'call',state);
 await denied(actor(state),'check',state);await denied(actor(state),'raise_to',state,{p_amount:21});await denied(actor(state),'raise_to',state,{p_amount:10000});
 const raceActor=actor(state);const race=await Promise.all([0,1].map(()=>raceActor.client.rpc('poker_action',{p_lobby:room,p_action:'call',p_hand:state.poker.hand_id,p_revision:state.poker.revision})));
 assert.equal(race.filter(r=>!r.error&&!r.data?.error).length,1);
 state=await action(players[0],'snapshot');conservation();
 for(let guard=0;state.poker.street!=='complete'&&guard<50;guard++){const p=actor(state);const view=await action(p,'snapshot');state=await poker(p,view.poker.actions.can_check?'check':'call',view);conservation();}
 assert.equal(state.poker.street,'complete');assert.equal(state.poker.board.length,5);assert.equal(state.poker.players.filter(p=>p.cards!==null).length,3);
 const old=state.poker.hand_id;state=await poker(players[0],'next',state);assert.notEqual(state.poker.hand_id,old);assert.equal(state.poker.hand_no,2);
 const stale=await players[0].client.rpc('poker_action',{p_lobby:room,p_action:'call',p_hand:old,p_revision:0});assert.ok(stale.error||stale.data?.error);conservation();
 console.log('PASS: private-card isolation, private grants, legal turns/bets, concurrent/stale actions, all streets, showdown, and successive hands.');

 state=await start(3);fixture([500,1000,1500],{turn:3});state=await action(players[0],'snapshot');state=await poker(actor(state),'all_in',state);state=await poker(actor(state),'call',state);state=await poker(actor(state),'call',state);
 assert.equal(state.poker.street,'complete');assert.deepEqual(state.poker.players.map(p=>p.stack),[1500,1000,500]);assert.deepEqual(state.poker.pots.map(p=>p.amount),[1500,1000,500]);assert.equal(state.poker.pots[2].kind,'return');conservation();
 state=await start(3);fixture([899,899,899],{bets:[101,101,101],folded:[3],acted:[1,2,3],board:cards('Ts Js Qs Ks As'),holes:['2c 3c','4d 5d','6h 7h'],current:101});sql(`select game_private.poker_advance('${room}',1)`);state=await action(players[0],'snapshot');assert.deepEqual(state.poker.players.map(p=>p.stack),[1050,1051,899]);conservation();
 state=await start(2);const dealer=state.poker.dealer;assert.equal(state.poker.small_blind,dealer);assert.equal(state.poker.turn_seat,dealer);state=await poker(actor(state),'fold',state);assert.equal(state.poker.board.length,0);assert.equal(state.poker.showdown,false);assert.equal(state.poker.players.filter(p=>p.cards!==null).length,1);conservation();
 const previousBB=state.poker.big_blind;state=await poker(players[0],'next',state);assert.notEqual(state.poker.big_blind,previousBB);
 state=await poker(actor(state),'all_in',state);state=await poker(actor(state),'call',state);assert.equal(state.poker.street,'complete');assert.equal(state.poker.board.length,5);conservation();
 console.log('PASS: unequal all-ins, main/side pots, unmatched returns, split/odd chips, fold privacy, heads-up blinds, and all-in runouts.');

 state=await start(4);fixture([900,130,200,2670],{bets:[100,0,0,0],acted:[1],turn:2,current:100,min:100});state=await action(players[0],'snapshot');state=await poker(actor(state),'all_in',state);state=await poker(actor(state),'call',state);state=await poker(actor(state),'call',state);assert.equal(state.poker.turn_seat,1);await denied(actor(state),'raise_to',state,{p_amount:230});state=await poker(actor(state),'call',state);conservation();
 state=await start(4);fixture([900,130,200,2670],{bets:[100,0,0,0],acted:[1],turn:2,current:100,min:100});state=await action(players[0],'snapshot');state=await poker(actor(state),'all_in',state);state=await poker(actor(state),'all_in',state);state=await poker(actor(state),'call',state);assert.equal(state.poker.turn_seat,1);state=await poker(actor(state),'raise_to',state,{p_amount:300});assert.equal(state.poker.current_bet,300);conservation();
 console.log('PASS: short all-ins do not reopen a prior actor; cumulative full raises reopen correctly.');

 state=await start(3);const timed=actor(state);sql(`update game_private.poker_tables set deadline=now()-interval '1 second' where lobby_id='${room}'`);
 const timeoutReply=await denied(timed,'call',state);assert.equal(timeoutReply.data.code,'40001');state=await action(players[1],'snapshot');assert.equal(state.poker.players.find(p=>p.user_id===timed.id).folded,true);conservation();
 await action(players[0],'leave');const remaining=await action(players[1],'snapshot');assert.notEqual(remaining.host_id,players[0].id);assert.notEqual(remaining.status,'closed');conservation();
 // Multi-tab leases keep a player admitted; expired leases remove the player without ending the whole table.
 state=await start(3);const secondConnection=crypto.randomUUID();await action(players[1],'heartbeat',room,{p_connection:secondConnection});
 sql(`update game_private.connections set expires_at=now()-interval '1 second' where lobby_id='${room}' and user_id='${players[1].id}' and connection_id='${players[1].connection}'`);
 state=await action(players[0],'snapshot');assert.ok(state.members.some(p=>p.user_id===players[1].id));
 sql(`update game_private.connections set expires_at=now()-interval '1 second' where lobby_id='${room}' and user_id='${players[0].id}'`);
 state=await action(players[1],'snapshot');assert.ok(!state.members.some(p=>p.user_id===players[0].id));assert.notEqual(state.host_id,players[0].id);conservation();
 console.log('PASS: trusted deadline cleanup commits on stale replies, host transfer, departure accounting, and multi-tab/expired leases.');
 state=await start(6);
 assert.equal(sql(`select cardinality(deck)=52 and (select count(distinct c) from unnest(deck)c)=52 from game_private.poker_tables where lobby_id='${room}'`),'t');
 assert.equal(sql(`select count(distinct c)=12 from game_private.poker_players p cross join lateral unnest(p.hole)c where p.lobby_id='${room}'`),'t');
 state=await poker(actor(state),'all_in',state);
 while(state.poker.street!=='complete')state=await poker(actor(state),'call',state);
 assert.equal(state.poker.board.length,5);conservation();
 // An all-in player who explicitly leaves remains eligible for the showdown.
 state=await start(3);fixture([500,1000,1500],{turn:3});state=await action(players[0],'snapshot');
 state=await poker(actor(state),'all_in',state);const leaving=actor(state);state=await poker(leaving,'call',state);await action(leaving,'leave');
 state=await action(players[1],'snapshot');state=await poker(actor(state),'call',state);conservation();
 assert.equal(state.poker.players.find(p=>p.user_id===leaving.id).payout,1500);
 // Clock expiry without a bet checks rather than folding.
 state=await start(3);fixture([1000,1000,1000],{turn:1});sql(`update game_private.poker_tables set deadline=now()-interval '1 second' where lobby_id='${room}'`);
 state=await action(players[1],'snapshot');assert.equal(state.poker.players[0].folded,false);assert.equal(state.poker.turn_seat,2);conservation();
 console.log('PASS: six-way all-ins, unique dealt cards/deck, departed all-in eligibility, and timeout checks.');

} finally {await clear();for(const p of players){await p.client.auth.signOut();await p.client.removeAllChannels();}}
