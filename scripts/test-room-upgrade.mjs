// Structural upgrade replay uses minimal Auth/Realtime/cron stubs in an isolated local database.
// Real authentication, Realtime, and gameplay are covered by the other integration suites.
import { spawnSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
const database='phase8_upgrade_'+randomUUID().replaceAll('-','').slice(0,8);
const migration='20261118030904_shared_rooms_and_rematches.sql';
function run(command,input) {
 const result=spawnSync('sg',['docker','-c',`docker exec -i supabase_db_game-hub ${command}`],{input,encoding:'utf8'});
 if(result.status!==0) throw new Error(result.stderr.slice(-2500));
}
run(`createdb -U postgres ${database}`);
try {
 const bootstrap="create schema auth; create schema realtime; create schema extensions; create schema cron;\n create extension pgcrypto with schema extensions;\n create table auth.users(id uuid primary key,raw_user_meta_data jsonb,deleted_at timestamptz,banned_until timestamptz);\n create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),not_after timestamptz);\n create function auth.jwt() returns jsonb language sql stable as $$select nullif(current_setting('request.jwt.claims',true),'')::jsonb$$;\n create function auth.uid() returns uuid language sql stable as $$select (auth.jwt()->>'sub')::uuid$$;\n create table realtime.messages(extension text);\n create function realtime.topic() returns text language sql as $$select ''::text$$;\n create function cron.schedule(text,text,text) returns bigint language sql as $$select 1::bigint$$;\n create publication supabase_realtime;\n ";
 const baseline=readdirSync('supabase/migrations').filter(name=>name.endsWith('.sql') && name<migration).sort()
  .map(name=>readFileSync(`supabase/migrations/${name}`,'utf8').split('\n').filter(line=>!line.startsWith('create extension if not exists pg_cron') && !line.startsWith('select cron.schedule(')).join('\n')).join('\n');
 let fixtures='';
 const user=i=>`00000000-0000-0000-0000-${String(i).padStart(12,'0')}`;
 for(let i=1;i<=6;i++) fixtures+=`insert into auth.users values('${user(i)}','{"display_name":"Legacy ${i}"}',null,null); insert into auth.sessions values('${user(i)}','${user(i)}',null);\n`;
 for(const [index,status] of ['waiting','playing','finished'].entries()) {
  const i=index+1,room=`10000000-0000-0000-0000-${String(i).padStart(12,'0')}`;
  fixtures+=`insert into game_private.lobbies(id,game_id,host_id,status) values('${room}','tic-tac-toe','${user(2*i-1)}','${status}'); insert into game_private.memberships values('${room}','${user(2*i-1)}','Host','X'),('${room}','${user(2*i)}','Other','O'); insert into game_private.connections values('${room}','${user(2*i-1)}','${user(2*i-1)}',now()+interval '90 seconds'),('${room}','${user(2*i)}','${user(2*i)}',now()+interval '90 seconds');\n`;
  if(status!=='waiting') fixtures+=`insert into game_private.matches(lobby_id,status) values('${room}','${status}');\n`;
 }
 const checks="\n do $$begin\n if (select count(*) from game_private.memberships where seat in (1,2))<>6 then raise exception 'Legacy seats were not preserved'; end if;\n if (select count(*) from public.game_catalog where id='poker' and capacity=6 and not playable)<>1 then raise exception 'Poker catalog entry missing'; end if;\n if has_table_privilege('authenticated','game_private.rematch_votes','select') then raise exception 'Private votes readable'; end if;\n if has_function_privilege('anon','public.room_action(text,uuid,uuid,text,integer,text,text,integer)','execute') then raise exception 'Unauthenticated RPC grant'; end if;\n end$$;\n select set_config('request.jwt.claims','{\"sub\":\"00000000-0000-0000-0000-000000000003\",\"session_id\":\"00000000-0000-0000-0000-000000000003\"}',true);\n set local role authenticated;\n select public.play_move('10000000-0000-0000-0000-000000000002',0,0);\n reset role;\n do $$begin\n if (select revision from game_private.matches where lobby_id='10000000-0000-0000-0000-000000000002')<>1 then raise exception 'Legacy match could not continue'; end if;\n end$$;\n ";
 run(`psql -U postgres -d ${database} -v ON_ERROR_STOP=1 -q`,'begin;\n'+bootstrap+baseline+fixtures+readFileSync(`supabase/migrations/${migration}`,'utf8')+readFileSync('supabase/migrations/20261118222942_holdem_engine.sql','utf8').replace(/^BEGIN;$/gm,'').replace(/^COMMIT;$/gm,'')+checks+'\ncommit;'+readFileSync('supabase/migrations/20261118223537_enable_holdem.sql','utf8')+"do $$begin if not (select playable from public.game_catalog where id='poker') then raise exception 'Poker activation missing';end if;end$$;");
 const pokerRoom='20000000-0000-0000-0000-000000000001';
 let pokerFixture='';
 for(let i=7;i<=8;i++)pokerFixture+=`insert into auth.users values('${user(i)}','{"display_name":"Legacy poker"}',null,null); insert into auth.sessions values('${user(i)}','${user(i)}',null);`;
 pokerFixture+=`insert into game_private.lobbies(id,game_id,host_id,status,capacity) values('${pokerRoom}','poker','${user(7)}','waiting',2);`;
 for(let i=7;i<=8;i++)pokerFixture+=`insert into game_private.memberships(lobby_id,user_id,display_name,seat) values('${pokerRoom}','${user(i)}','Legacy poker',${i-6});insert into game_private.connections values('${pokerRoom}','${user(i)}','${user(i)}',now()+interval '5 minutes');`;
 pokerFixture+=`select game_private.poker_start('${pokerRoom}');`;
 const botMigration=readdirSync('supabase/migrations').find(name=>name.endsWith('_poker_bots.sql'));
 run(`psql -U postgres -d ${database} -v ON_ERROR_STOP=1 -q`,pokerFixture+readFileSync(`supabase/migrations/${botMigration}`,'utf8')+`do $$declare actor uuid;begin
 if (select count(*) from game_private.poker_players where lobby_id='${pokerRoom}' and not is_bot and human_user_id=user_id)<>2 then raise exception 'Human foreign keys not preserved';end if;
 select p.user_id into actor from game_private.poker_players p join game_private.poker_tables t using(lobby_id) where p.lobby_id='${pokerRoom}' and p.seat=t.turn_seat;
 perform game_private.poker_apply('${pokerRoom}',actor,'fold');
 perform game_private.poker_assert('${pokerRoom}');
 if (select street from game_private.poker_tables where lobby_id='${pokerRoom}')<>'complete' then raise exception 'Active poker hand did not survive upgrade';end if;
 if has_function_privilege('authenticated','game_private.poker_apply(uuid,uuid,text,bigint)','execute') then raise exception 'Private action helper exposed';end if;
 end$$;`);
 const settingsMigration=readdirSync('supabase/migrations').find(name=>name.endsWith('_poker_table_settings.sql'));
 const restore=`update game_private.poker_players set stack=1000,committed=0,street_bet=0 where lobby_id='${pokerRoom}';update game_private.lobbies set status='playing',closed_at=null where id='${pokerRoom}';select game_private.poker_new_hand('${pokerRoom}');`;
 const checks83=`begin;
 do $$begin if (select count(*) from game_private.poker_settings where lobby_id='${pokerRoom}' and starting_chips=1000 and big_blind=20 and turn_seconds=30 and rebuy_limit=0)<>1 then raise exception 'Old room defaults not backfilled';end if;end$$;
 select set_config('test.hand',(select hand_id::text from game_private.poker_tables where lobby_id='${pokerRoom}'),true);
 select set_config('request.jwt.claims',(select jsonb_build_object('sub',p.user_id,'session_id',p.user_id)::text from game_private.poker_players p join game_private.poker_tables t using(lobby_id) where p.lobby_id='${pokerRoom}' and p.seat=t.turn_seat),true);
 set local role authenticated;
 select public.poker_action('${pokerRoom}','fold',current_setting('test.hand')::uuid,0);
 reset role;
 do $$begin if (select street from game_private.poker_tables where lobby_id='${pokerRoom}')<>'complete' then raise exception 'Legacy action did not survive settings upgrade';end if;
 if has_table_privilege('authenticated','game_private.poker_settings','update') then raise exception 'Rules are editable by guests';end if;end$$;
 select game_private.poker_assert('${pokerRoom}');commit;`;
 run(`psql -U postgres -d ${database} -v ON_ERROR_STOP=1 -q`,restore+readFileSync(`supabase/migrations/${settingsMigration}`,'utf8')+checks83);
 console.log('PASS: isolated upgrade preserves legacy seats, rooms, active gameplay, catalog data, and private grants through the Hold’em, bot, and settings upgrades.');
} finally { run(`dropdb -U postgres ${database}`); }
