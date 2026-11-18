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
 run(`psql -U postgres -d ${database} -v ON_ERROR_STOP=1 -q`,'begin;\n'+bootstrap+baseline+fixtures+readFileSync(`supabase/migrations/${migration}`,'utf8')+checks+'\ncommit;');
 console.log('PASS: isolated upgrade preserves legacy seats, rooms, active gameplay, catalog data, and private grants.');
} finally { run(`dropdb -U postgres ${database}`); }
