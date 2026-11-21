begin;

alter table game_private.lobbies drop constraint private_room_code;
alter table game_private.lobbies add constraint private_room_code check (
  (visibility='private' and join_code is not null and
    join_code ~ '^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}$|^[0-9A-F]{16}$')
  or (visibility='public' and join_code is null)
);

alter table game_private.request_buckets
  add column code_window_start timestamptz not null default '-infinity',
  add column code_attempts integer not null default 0 check (code_attempts between 0 and 10);

create function game_private.generate_room_code(p_long_code boolean)
returns text language plpgsql set search_path = '' as $$
declare
  alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  entropy bytea;
  invite text;
begin
  if p_long_code then
    return upper(encode(extensions.gen_random_bytes(8),'hex'));
  end if;
  entropy:=extensions.gen_random_bytes(4);
  select string_agg(substr(alphabet,(get_byte(entropy,i) & 31)+1,1),'' order by i)
    into invite from generate_series(0,3) i;
  return invite;
end;
$$;
revoke all on function game_private.generate_room_code(boolean) from public, anon, authenticated;

-- Replace the RPC signatures together. Named calls that omit the new
-- argument still resolve to a single function with the same defaults.
drop function public.room_action(text,uuid,uuid,text,integer,text,text,integer);
drop function public.create_poker_room(integer,text,jsonb,uuid);
drop function game_private.create_poker_room_api(integer,text,jsonb,uuid);
drop function game_private.room_api(text,uuid,uuid,text,integer,text,text,integer,boolean);

CREATE OR REPLACE FUNCTION game_private.room_api (
  p_action     text,
  p_lobby      uuid    DEFAULT NULL::uuid,
  p_connection uuid    DEFAULT NULL::uuid,
  p_game       text    DEFAULT 'tic-tac-toe'::text,
  p_capacity   integer DEFAULT NULL::integer,
  p_visibility text    DEFAULT 'public'::text,
  p_code       text    DEFAULT NULL::text,
  p_round      integer DEFAULT NULL::integer,
  p_legacy     boolean DEFAULT false,
  p_long_code  boolean DEFAULT false
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
 actor uuid:=game_private.valid_actor(); room game_private.lobbies; catalog public.game_catalog;
 previous uuid; new_id uuid; free_seat smallint; normalized_code text; reserved_seats jsonb;
 candidate_code text; code_window timestamptz;
begin
 if actor is null then raise exception 'Your session ended. Sign in again.' using errcode='PT401'; end if;
 if p_action is null or p_action not in ('create','join','join_code','current','snapshot','heartbeat','leave','start','rematch','cancel_rematch') then
  raise exception 'Unknown room action.' using errcode='22023'; end if;
 normalized_code:=upper(regexp_replace(left(coalesce(p_code,''),64),'[[:space:]-]','','g'));
 if p_action<>'leave' then perform game_private.consume_budget(actor); end if;
 if p_action='join_code' then
  -- The general request budget locks this user's row before we count guesses.
  code_window:=date_trunc('minute',clock_timestamp());
  update game_private.request_buckets
    set code_attempts=case when code_window_start=code_window then code_attempts+1 else 1 end,
        code_window_start=code_window
    where user_id=actor and (code_window_start<>code_window or code_attempts<10);
  if not found then
   return jsonb_build_object('error','Too many code attempts. Wait a minute and try again.','code','RATE_LIMITED');
  end if;
 end if;
 select * into catalog from public.game_catalog where id=p_game and game_private.dispatch_room_game(p_game,'supported')='true'::jsonb;
 if not found then raise exception 'Unknown game.' using errcode='22023'; end if;
 if p_action in ('create','join','join_code') then
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text,0));
  select lobby_id into previous from game_private.memberships where user_id=actor;
  if previous is not null then
   perform game_private.prune_lobby(previous);
   -- Completed membership is released only after a new room has been validated below.
   if exists(select 1 from game_private.lobbies where id=previous and status in ('waiting','playing')) and (p_action='create' or (p_action='join' and previous is distinct from p_lobby) or (p_action='join_code' and not exists(select 1 from game_private.lobbies where id=previous and join_code=normalized_code and game_id=p_game))) then
    raise exception 'Leave your current lobby first.';
   end if;
  end if;
 end if;
 if p_action='current' then
  select l.* into room from game_private.memberships m join game_private.lobbies l on l.id=m.lobby_id where m.user_id=actor and l.game_id=p_game;
  if not found then return null; end if;
  perform game_private.prune_lobby(room.id);
  if (select status from game_private.lobbies where id=room.id)='closed' then return null; end if;
  return to_jsonb(room.id);
 end if;
 if p_action='create' then
  if p_connection is null then raise exception 'Connection ID required.'; end if;
  if p_visibility is null or p_visibility not in ('public','private') then raise exception 'Invalid room visibility.' using errcode='22023'; end if;
  p_capacity:=coalesce(p_capacity,catalog.capacity);
  if p_capacity<catalog.min_players or p_capacity>catalog.capacity then raise exception 'Invalid room capacity.' using errcode='22023'; end if;
  if (select count(*) from game_private.lobbies where host_id=actor and created_at>now()-interval '1 minute')>=10 then raise exception 'Too many new lobbies. Wait a minute and try again.'; end if;
  if previous is not null then delete from game_private.memberships where user_id=actor; perform game_private.sync_summary(previous); end if;
  for attempt in 1..16 loop
   candidate_code:=case when p_visibility='private' then game_private.generate_room_code(p_long_code is true) end;
   insert into game_private.lobbies(game_id,host_id,capacity,visibility,join_code,contract_version)
   values(p_game,actor,p_capacity,p_visibility,candidate_code,case when p_legacy then 1 else 2 end)
   on conflict on constraint lobbies_join_code_key do nothing
   returning id into new_id;
   exit when found;
  end loop;
  if new_id is null then raise exception 'Could not allocate a room code. Try again.'; end if;
  insert into game_private.memberships(lobby_id,user_id,display_name,mark,seat) values(new_id,actor,coalesce(game_private.guest_name(),'Guest'),game_private.dispatch_room_game(p_game,'host_mark',new_id)#>>'{}',1);
  insert into game_private.connections values(new_id,actor,p_connection,now()+interval '90 seconds');
  perform game_private.sync_summary(new_id);
  return to_jsonb(new_id);
 end if;
 if p_action='join_code' then
  -- Return a normal error envelope so failed code attempts COMMIT their budget charge.
  if char_length(coalesce(p_code,''))>64 or normalized_code !~ '^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}$|^[0-9A-F]{16}$' then return jsonb_build_object('error','Room not found or unavailable.','code','ROOM_UNAVAILABLE'); end if;
  select id into p_lobby from game_private.lobbies where join_code=normalized_code and game_id=p_game and visibility='private';
  if p_lobby is null then return jsonb_build_object('error','Room not found or unavailable.','code','ROOM_UNAVAILABLE'); end if;
 end if;
 if p_lobby is null then raise exception 'Lobby ID required.' using errcode='22023'; end if;
 select * into room from game_private.lobbies where id=p_lobby for update;
 if not found or room.game_id<>p_game then
  if p_action='join_code' then return jsonb_build_object('error','Room not found or unavailable.','code','ROOM_UNAVAILABLE'); end if;
  raise exception 'Lobby not found.' using errcode='P0002';
 end if;
 if p_action not in ('join','join_code') and not exists(select 1 from game_private.memberships where lobby_id=p_lobby and user_id=actor) then
  raise exception 'You are not a member of this lobby.' using errcode='42501'; end if;
 perform game_private.prune_lobby(p_lobby);
 select * into room from game_private.lobbies where id=p_lobby;
 if p_action in ('snapshot','heartbeat') and not exists(select 1 from game_private.memberships where lobby_id=p_lobby and user_id=actor) then return null; end if;
 if p_action in ('join','join_code') then
  if p_connection is null then raise exception 'Connection ID required.'; end if;
  if not exists(select 1 from game_private.memberships where lobby_id=p_lobby and user_id=actor) then
   if room.visibility='private' and (p_action<>'join_code' or normalized_code is distinct from room.join_code) then
    raise exception 'A room code is required.' using errcode='42501'; end if;
   reserved_seats:=coalesce(game_private.dispatch_room_game(p_game,'reserved_seats',p_lobby),'[]'::jsonb);
   if room.status<>'waiting' or ((select count(*) from game_private.memberships where lobby_id=p_lobby)+jsonb_array_length(reserved_seats))>=room.capacity then
    if p_action='join_code' then return jsonb_build_object('error','Room not found or unavailable.','code','ROOM_UNAVAILABLE'); end if;
    if room.status<>'waiting' then raise exception 'This lobby is no longer accepting players.'; end if;
    raise exception 'This lobby is full.';
   end if;
   select n::smallint into free_seat from generate_series(1,room.capacity) n where not exists(select 1 from game_private.memberships m where m.lobby_id=p_lobby and m.seat=n) and not reserved_seats @> to_jsonb(array[n]) order by n limit 1;
   if previous is not null and previous<>p_lobby then delete from game_private.memberships where user_id=actor; perform game_private.sync_summary(previous); end if;
   insert into game_private.memberships(lobby_id,user_id,display_name,mark,seat) values(p_lobby,actor,coalesce(game_private.guest_name(),'Guest'),game_private.dispatch_room_game(p_game,'guest_mark',p_lobby)#>>'{}',free_seat);
  end if;
 elsif p_action='leave' then
  if game_private.dispatch_room_game(p_game,'leave',p_lobby,actor)='true'::jsonb then return null; end if;
  if room.status in ('waiting','playing') then
   if room.host_id=actor then perform game_private.close_lobby(p_lobby,'The host left.');
   elsif room.status='playing' then perform game_private.close_lobby(p_lobby,'A player left. The match was interrupted.'); end if;
  end if;
  delete from game_private.memberships where lobby_id=p_lobby and user_id=actor;
  perform game_private.sync_summary(p_lobby); return null;
 elsif p_action='start' then
  if room.host_id<>actor then raise exception 'Only the host can start.' using errcode='42501'; end if;
  return game_private.dispatch_room_game(p_game,'start',p_lobby,actor,p_round,p_legacy,catalog.playable);
 elsif p_action in ('rematch','cancel_rematch') then
  return game_private.dispatch_room_game(p_game,p_action,p_lobby,actor,p_round);
 end if;
 if p_action in ('join','join_code','heartbeat') and room.status in ('waiting','playing','finished') then
  if not exists(select 1 from game_private.memberships where lobby_id=p_lobby and user_id=actor) then raise exception 'Your seat expired. Join the lobby again.' using errcode='42501'; end if;
  if p_connection is null then raise exception 'Connection ID required.'; end if;
  if not exists(select 1 from game_private.connections where lobby_id=p_lobby and user_id=actor and connection_id=p_connection)
   and (select count(*) from game_private.connections where lobby_id=p_lobby and user_id=actor)>=20 then raise exception 'Too many open lobby tabs.'; end if;
  insert into game_private.connections values(p_lobby,actor,p_connection,now()+interval '90 seconds') on conflict(lobby_id,user_id,connection_id) do update set expires_at=excluded.expires_at;
  update game_private.memberships set display_name=coalesce(game_private.guest_name(),'Guest') where lobby_id=p_lobby and user_id=actor;
  perform game_private.sync_summary(p_lobby);
 end if;
 return game_private.room_snapshot(p_lobby);
end;
$function$;

CREATE OR REPLACE FUNCTION game_private.create_poker_room_api (
  p_capacity   integer DEFAULT 6,
  p_visibility text    DEFAULT 'public'::text,
  p_settings   jsonb   DEFAULT '{}'::jsonb,
  p_connection uuid    DEFAULT NULL::uuid,
  p_long_code  boolean DEFAULT false
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare id uuid;k text;chips integer;blind integer;seconds integer;rebuys integer;
begin
 if game_private.valid_actor() is null then raise exception 'Your session ended. Sign in again.' using errcode='PT401';end if;
 if p_settings is null or jsonb_typeof(p_settings)<>'object' then raise exception 'Settings must be an object.' using errcode='22023';end if;
 for k in select jsonb_object_keys(p_settings) loop
  if k not in ('starting_chips','big_blind','turn_seconds','rebuy_limit') or jsonb_typeof(p_settings->k)<>'number' or length(p_settings->>k)>6 or (p_settings->>k)!~'^[0-9]+$' then raise exception 'Invalid table setting: %.',k using errcode='22023';end if;
 end loop;
 chips:=coalesce((p_settings->>'starting_chips')::integer,1000);blind:=coalesce((p_settings->>'big_blind')::integer,20);seconds:=coalesce((p_settings->>'turn_seconds')::integer,30);rebuys:=coalesce((p_settings->>'rebuy_limit')::integer,0);
 if chips<100 or chips>10000 or chips%100<>0 or blind not in (10,20,50,100,200,500) or chips<blind*20 or seconds not in (15,30,45,60,90) or rebuys not in (0,1,3) then raise exception 'Choose 100–10,000 chips in hundreds, at least 20 big blinds, and supported blinds, timer, and rebuy limit.' using errcode='22023';end if;
 id:=(game_private.room_api('create',null,p_connection,'poker',p_capacity,p_visibility,p_long_code=>p_long_code)#>>'{}')::uuid;
 update game_private.poker_settings set starting_chips=chips,big_blind=blind,turn_seconds=seconds,rebuy_limit=rebuys where lobby_id=id;
 return id;
end;$function$;

CREATE OR REPLACE FUNCTION public.room_action (
  p_action     text,
  p_lobby      uuid    DEFAULT NULL::uuid,
  p_connection uuid    DEFAULT NULL::uuid,
  p_game       text    DEFAULT 'tic-tac-toe'::text,
  p_capacity   integer DEFAULT NULL::integer,
  p_visibility text    DEFAULT 'public'::text,
  p_code       text    DEFAULT NULL::text,
  p_round      integer DEFAULT NULL::integer,
  p_long_code  boolean DEFAULT false
)
  RETURNS jsonb
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
 select game_private.room_api(p_action,p_lobby,p_connection,p_game,p_capacity,p_visibility,p_code,p_round,false,p_long_code);
$function$;

CREATE OR REPLACE FUNCTION public.create_poker_room (
  p_capacity   integer DEFAULT 6,
  p_visibility text    DEFAULT 'public'::text,
  p_settings   jsonb   DEFAULT '{}'::jsonb,
  p_connection uuid    DEFAULT NULL::uuid,
  p_long_code  boolean DEFAULT false
)
  RETURNS uuid
  LANGUAGE sql
  SET search_path TO ''
  AS $function$select game_private.create_poker_room_api(p_capacity,p_visibility,p_settings,p_connection,p_long_code);$function$;

revoke all on function game_private.room_api(text,uuid,uuid,text,integer,text,text,integer,boolean,boolean)
  from public, anon, authenticated;
grant execute on function game_private.room_api(text,uuid,uuid,text,integer,text,text,integer,boolean,boolean)
  to authenticated;
revoke all on function game_private.create_poker_room_api(integer,text,jsonb,uuid,boolean)
  from public, anon, authenticated;
grant execute on function game_private.create_poker_room_api(integer,text,jsonb,uuid,boolean)
  to authenticated;
revoke all on function public.room_action(text,uuid,uuid,text,integer,text,text,integer,boolean) from public, anon;
grant execute on function public.room_action(text,uuid,uuid,text,integer,text,text,integer,boolean) to authenticated, service_role;
revoke all on function public.create_poker_room(integer,text,jsonb,uuid,boolean) from public, anon;
grant execute on function public.create_poker_room(integer,text,jsonb,uuid,boolean) to authenticated, service_role;

notify pgrst,'reload schema';
commit;
