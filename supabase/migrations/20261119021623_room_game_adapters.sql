-- Route game-specific room behavior through private, explicitly registered adapters.
BEGIN;

SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION game_private.dispatch_room_game (
  p_game     text,
  p_event    text,
  p_lobby    uuid    DEFAULT NULL::uuid,
  p_actor    uuid    DEFAULT NULL::uuid,
  p_round    integer DEFAULT NULL::integer,
  p_legacy   boolean DEFAULT false,
  p_playable boolean DEFAULT false,
  p_snapshot jsonb   DEFAULT NULL::jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
 case p_game
 when 'tic-tac-toe' then
  if p_event='supported' then return 'true'::jsonb; end if;
  return game_private.tic_tac_toe_room_adapter(p_event,p_lobby,p_actor,p_round,p_legacy,p_playable,p_snapshot);
 when 'poker' then
  if p_event='supported' then return 'true'::jsonb; end if;
  return game_private.poker_room_adapter(p_event,p_lobby,p_actor,p_round,p_legacy,p_playable,p_snapshot);
 else
  return null;
 end case;
end;
$function$;

CREATE OR REPLACE FUNCTION game_private.poker_room_adapter (
  p_event    text,
  p_lobby    uuid,
  p_actor    uuid,
  p_round    integer,
  p_legacy   boolean,
  p_playable boolean,
  p_snapshot jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
 room game_private.lobbies;
begin
 case p_event
 when 'reserved_seats' then
  return (
   select coalesce(jsonb_agg(b.seat order by b.seat),'[]'::jsonb)
   from game_private.room_bots b where b.lobby_id=p_lobby
  );
 when 'snapshot' then
  return jsonb_build_object('settings',game_private.poker_settings_view(p_lobby),'poker',game_private.poker_view(p_lobby,auth.uid()),'members',
  (p_snapshot->'members')||coalesce((select jsonb_agg(jsonb_build_object('user_id',user_id,'display_name',display_name,'seat',seat,'mark',null,'rematch',false,'connected',true,'is_bot',true) order by seat) from game_private.room_bots where lobby_id=p_lobby),'[]'::jsonb));
 when 'start' then
  raise exception 'Refresh this page to play poker.';
 when 'rematch','cancel_rematch' then
  if p_round is null then raise exception 'Round required.' using errcode='22023'; end if;
  select * into room from game_private.lobbies where id=p_lobby;
  if p_round<room.round then return game_private.room_snapshot(p_lobby); end if;
  raise exception 'This match cannot be restarted.';
 when 'leave' then
  if exists(select 1 from game_private.poker_tables where lobby_id=p_lobby) then
   perform game_private.poker_depart(p_lobby,p_actor);
   delete from game_private.memberships where lobby_id=p_lobby and user_id=p_actor;
   perform game_private.poker_rehost(p_lobby);
   perform game_private.sync_summary(p_lobby);
   return 'true'::jsonb;
  end if;
 when 'prune' then
  if exists(select 1 from game_private.poker_tables where lobby_id=p_lobby) then
   perform game_private.poker_tick(p_lobby);
   return 'true'::jsonb;
  end if;
 else
  return null;
 end case;
 return null;
end;
$function$;

CREATE OR REPLACE FUNCTION game_private.prune_lobby (
  p_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare room game_private.lobbies;
begin
 select * into room from game_private.lobbies where id=p_id for update;
 if not found or room.status in ('closed','finished') then return; end if;
 if game_private.dispatch_room_game(room.game_id,'prune',p_id)='true'::jsonb then
  perform game_private.sync_summary(p_id);
  return;
 end if;
 delete from game_private.connections where lobby_id=p_id and expires_at<=now();
 if not exists(select 1 from game_private.connections where lobby_id=p_id and user_id=room.host_id) then
  perform game_private.close_lobby(p_id,'The host disconnected.');
 elsif room.status='playing' and exists(select 1 from game_private.memberships m where m.lobby_id=p_id and not exists(select 1 from game_private.connections c where c.lobby_id=p_id and c.user_id=m.user_id)) then
  perform game_private.close_lobby(p_id,'A player disconnected. The match was interrupted.');
 elsif room.status='waiting' then
  delete from game_private.memberships m where m.lobby_id=p_id and m.user_id<>room.host_id
  and not exists(select 1 from game_private.connections c where c.lobby_id=p_id and c.user_id=m.user_id);
 end if;
 perform game_private.sync_summary(p_id);
end;
$function$;

CREATE OR REPLACE FUNCTION game_private.room_api (
  p_action     text,
  p_lobby      uuid    DEFAULT NULL::uuid,
  p_connection uuid    DEFAULT NULL::uuid,
  p_game       text    DEFAULT 'tic-tac-toe'::text,
  p_capacity   integer DEFAULT NULL::integer,
  p_visibility text    DEFAULT 'public'::text,
  p_code       text    DEFAULT NULL::text,
  p_round      integer DEFAULT NULL::integer,
  p_legacy     boolean DEFAULT false
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
 actor uuid:=game_private.valid_actor(); room game_private.lobbies; catalog public.game_catalog;
 previous uuid; new_id uuid; free_seat smallint; normalized_code text; reserved_seats jsonb;
begin
 if actor is null then raise exception 'Your session ended. Sign in again.' using errcode='PT401'; end if;
 if p_action is null or p_action not in ('create','join','join_code','current','snapshot','heartbeat','leave','start','rematch','cancel_rematch') then
  raise exception 'Unknown room action.' using errcode='22023'; end if;
 normalized_code:=upper(regexp_replace(left(coalesce(p_code,''),64),'[[:space:]-]','','g'));
 if p_action<>'leave' then perform game_private.consume_budget(actor); end if;
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
  insert into game_private.lobbies(game_id,host_id,capacity,visibility,join_code,contract_version)
  values(p_game,actor,p_capacity,p_visibility,case when p_visibility='private' then upper(encode(extensions.gen_random_bytes(8),'hex')) else null end,case when p_legacy then 1 else 2 end) returning id into new_id;
  insert into game_private.memberships(lobby_id,user_id,display_name,mark,seat) values(new_id,actor,coalesce(game_private.guest_name(),'Guest'),game_private.dispatch_room_game(p_game,'host_mark',new_id)#>>'{}',1);
  insert into game_private.connections values(new_id,actor,p_connection,now()+interval '90 seconds');
  perform game_private.sync_summary(new_id);
  return to_jsonb(new_id);
 end if;
 if p_action='join_code' then
  -- Return a normal error envelope so failed code attempts COMMIT their budget charge.
  if char_length(coalesce(p_code,''))>64 or normalized_code !~ '^[0-9A-F]{16}$' then return jsonb_build_object('error','Room not found or unavailable.','code','ROOM_UNAVAILABLE'); end if;
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

CREATE OR REPLACE FUNCTION game_private.room_snapshot (
  p_id uuid
)
  RETURNS jsonb
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
 select snapshot||coalesce(game_private.dispatch_room_game(
  snapshot->>'game_id','snapshot',p_id,auth.uid(),p_snapshot=>snapshot
 ),'{}'::jsonb)
 from (select game_private.room_snapshot_base(p_id) as snapshot) room
$function$;

CREATE OR REPLACE FUNCTION game_private.room_snapshot_base (
  p_id uuid
)
  RETURNS jsonb
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
 select jsonb_build_object('id',l.id,'game_id',l.game_id,'host_id',l.host_id,'status',l.status,'reason',l.reason,
 'capacity',l.capacity,'visibility',l.visibility,'join_code',l.join_code,'round',l.round,'contract_version',l.contract_version,
 'playable',g.playable,'min_players',g.min_players,
 'title',coalesce((select display_name from game_private.memberships where lobby_id=l.id and user_id=l.host_id),'Guest')||'''s lobby',
 'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'display_name',m.display_name,'mark',m.mark,'seat',m.seat,
 'rematch',exists(select 1 from game_private.rematch_votes v where v.lobby_id=l.id and v.user_id=m.user_id and v.round=l.round),
 'connected',exists(select 1 from game_private.connections c where c.lobby_id=l.id and c.user_id=m.user_id and c.expires_at>now())) order by m.seat)
 from game_private.memberships m where m.lobby_id=l.id),'[]'::jsonb),
 'match',null)
 from game_private.lobbies l join public.game_catalog g on g.id=l.game_id where l.id=p_id;
$function$;

CREATE OR REPLACE FUNCTION game_private.sync_summary (
  p_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
 -- Private rooms never have a public summary row, including during lifecycle changes.
 delete from public.lobby_summaries s using game_private.lobbies l where s.id=l.id and l.id=p_id and l.visibility='private';
 insert into public.lobby_summaries(id,game_id,title,player_count,capacity,status,host_expires_at,created_at)
 select l.id,l.game_id,coalesce(m.display_name,'Guest')||'''s lobby',
 ((select count(*) from game_private.memberships p where p.lobby_id=l.id)+coalesce(jsonb_array_length(game_private.dispatch_room_game(l.game_id,'reserved_seats',l.id)),0))::smallint,l.capacity,l.status,
 coalesce((select max(c.expires_at) from game_private.connections c where c.lobby_id=l.id and c.user_id=l.host_id),'-infinity'),l.created_at
 from game_private.lobbies l left join game_private.memberships m on m.lobby_id=l.id and m.user_id=l.host_id
 where l.id=p_id and l.visibility='public'
 on conflict(id) do update set title=excluded.title,player_count=excluded.player_count,capacity=excluded.capacity,status=excluded.status,host_expires_at=excluded.host_expires_at
 where (lobby_summaries.title,lobby_summaries.player_count,lobby_summaries.capacity,lobby_summaries.status,lobby_summaries.host_expires_at)
 is distinct from(excluded.title,excluded.player_count,excluded.capacity,excluded.status,excluded.host_expires_at);
end;
$function$;

CREATE OR REPLACE FUNCTION game_private.tic_tac_toe_room_adapter (
  p_event    text,
  p_lobby    uuid,
  p_actor    uuid,
  p_round    integer,
  p_legacy   boolean,
  p_playable boolean,
  p_snapshot jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
 room game_private.lobbies;
 free_seat smallint;
 chosen_x uuid;
begin
 if p_event='host_mark' then return to_jsonb('X'::text); end if;
 if p_event='guest_mark' then return to_jsonb('O'::text); end if;
 if p_event not in ('start','rematch','cancel_rematch','snapshot','prune') then return null; end if;
 select * into room from game_private.lobbies where id=p_lobby;
 if p_event='start' then
  if not p_playable then raise exception 'Poker gameplay is not available yet.'; end if;
  if room.status='playing' then return to_jsonb(p_lobby); end if;
  if room.status<>'waiting' then raise exception 'This lobby is closed.'; end if;
  if (select count(*) from game_private.memberships where lobby_id=p_lobby)<>2 then raise exception 'Two connected players are required.'; end if;
  if exists(select 1 from game_private.memberships m where m.lobby_id=p_lobby and not exists(select 1 from game_private.connections c where c.lobby_id=p_lobby and c.user_id=m.user_id and c.expires_at>now())) then raise exception 'Two connected players are required.'; end if;
  if p_legacy and room.contract_version=1 then chosen_x:=room.host_id;
  else
   free_seat:=(get_byte(extensions.gen_random_bytes(1),0)%2+1)::smallint;
   select user_id into chosen_x from game_private.memberships where lobby_id=p_lobby and seat=free_seat;
  end if;
  update game_private.memberships set mark=null where lobby_id=p_lobby;
  update game_private.memberships set mark=case when user_id=chosen_x then 'X' else 'O' end where lobby_id=p_lobby;
  insert into game_private.matches(lobby_id,round) values(p_lobby,room.round);
  update game_private.lobbies set status='playing' where id=p_lobby;
  perform game_private.sync_summary(p_lobby); return to_jsonb(p_lobby);
 elsif p_event in ('rematch','cancel_rematch') then
  if p_round is null then raise exception 'Round required.' using errcode='22023'; end if;
  if p_round<room.round then return game_private.room_snapshot(p_lobby); end if;
  if p_round<>room.round or room.status<>'finished' then raise exception 'This match cannot be restarted.'; end if;
  if p_event='cancel_rematch' then delete from game_private.rematch_votes where lobby_id=p_lobby and user_id=p_actor and round=room.round;
  else
   if (select count(*) from game_private.memberships where lobby_id=p_lobby)<>2 or exists(select 1 from game_private.memberships m where m.lobby_id=p_lobby and not exists(select 1 from game_private.connections c where c.lobby_id=p_lobby and c.user_id=m.user_id and c.expires_at>now())) then raise exception 'Two connected players are required.'; end if;
   insert into game_private.rematch_votes values(p_lobby,p_actor,room.round) on conflict do nothing;
   if (select count(*) from game_private.rematch_votes where lobby_id=p_lobby and round=room.round)=2 then
    select user_id into chosen_x from game_private.memberships where lobby_id=p_lobby and mark='O';
    update game_private.memberships set mark=null where lobby_id=p_lobby;
    update game_private.memberships set mark=case when user_id=chosen_x then 'X' else 'O' end where lobby_id=p_lobby;
    update game_private.lobbies set status='playing',round=round+1,closed_at=null,reason=null where id=p_lobby;
    insert into game_private.matches(lobby_id,round) values(p_lobby,room.round+1);
    perform game_private.sync_summary(p_lobby);
   end if;
  end if;
  return game_private.room_snapshot(p_lobby);
 elsif p_event='snapshot' then
  return jsonb_build_object('match',(select jsonb_build_object('id',a.id,'status',a.status,'board',a.board,'current_turn',a.current_turn,'reason',a.reason,
 'revision',a.revision,'winner',a.winner,'winning_line',a.winning_line,'round',a.round) from game_private.matches a where a.lobby_id=p_lobby and a.round=room.round));
 elsif p_event='prune' and room.status='playing'
   and (select count(*) from game_private.memberships where lobby_id=p_lobby)<>2 then
  delete from game_private.connections where lobby_id=p_lobby and expires_at<=now();
  perform game_private.close_lobby(p_lobby,'A player left. The match was interrupted.');
  return 'true'::jsonb;
 end if;
 return null;
end;
$function$;

REVOKE ALL ON FUNCTION "game_private"."dispatch_room_game"(text, text, uuid, uuid, integer, boolean, boolean, jsonb) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION "game_private"."poker_room_adapter"(text, uuid, uuid, integer, boolean, boolean, jsonb) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION "game_private"."tic_tac_toe_room_adapter"(text, uuid, uuid, integer, boolean, boolean, jsonb) FROM PUBLIC, anon, authenticated;

COMMIT;
