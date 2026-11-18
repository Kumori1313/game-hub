SET local check_function_bodies = off;

ALTER TABLE "game_private"."matches"
  DROP CONSTRAINT "matches_lobby_id_key";

ALTER TABLE "public"."game_catalog"
  DROP CONSTRAINT "game_catalog_capacity_check";

ALTER TABLE "public"."lobby_summaries"
  DROP CONSTRAINT "lobby_summaries_capacity_check";

ALTER TABLE "public"."lobby_summaries"
  DROP CONSTRAINT "lobby_summaries_player_count_check";

CREATE TABLE "game_private"."rematch_votes" (
  "lobby_id" uuid    NOT NULL,
  "user_id"  uuid    NOT NULL,
  "round"    integer NOT NULL,
  CONSTRAINT "rematch_votes_pkey" PRIMARY KEY (lobby_id, user_id, round)
);

ALTER TABLE "game_private"."rematch_votes"
  ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE game_private.rematch_votes FROM PUBLIC, anon, authenticated;

ALTER TABLE "game_private"."lobbies"
  ADD COLUMN "capacity" smallint NOT NULL DEFAULT 2;

ALTER TABLE "game_private"."lobbies"
  ADD COLUMN "visibility" text NOT NULL DEFAULT 'public'::text;

ALTER TABLE "game_private"."lobbies"
  ADD COLUMN "join_code" text;

ALTER TABLE "game_private"."lobbies"
  ADD COLUMN "round" integer NOT NULL DEFAULT 1;

ALTER TABLE "game_private"."lobbies"
  ADD COLUMN "contract_version" smallint NOT NULL DEFAULT 1;

ALTER TABLE "game_private"."matches"
  ADD COLUMN "round" integer NOT NULL DEFAULT 1;

ALTER TABLE "game_private"."memberships"
  ADD COLUMN "seat" smallint;

-- Preserve both seats in existing rooms before enforcing NOT NULL/uniqueness.
UPDATE game_private.memberships SET seat=CASE mark WHEN 'X' THEN 1 WHEN 'O' THEN 2 END;
ALTER TABLE game_private.memberships ALTER COLUMN seat SET NOT NULL;

ALTER TABLE "public"."game_catalog"
  ADD COLUMN "min_players" smallint NOT NULL DEFAULT 2;

ALTER TABLE "public"."game_catalog"
  ADD COLUMN "playable" boolean NOT NULL DEFAULT true;

ALTER TABLE "public"."game_catalog"
  ADD COLUMN "contract_version" smallint NOT NULL DEFAULT 2;

ALTER TABLE "public"."game_catalog"
  ADD COLUMN "launch_path" text;

ALTER TABLE "game_private"."memberships"
  ALTER COLUMN "mark" DROP NOT NULL;

CREATE OR REPLACE FUNCTION game_private.can_join_topic (
  p_topic text
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
 select game_private.valid_actor() is not null and exists(select 1 from game_private.memberships m join game_private.lobbies l on l.id=m.lobby_id
 where m.user_id=game_private.valid_actor() and l.status in ('waiting','playing','finished') and p_topic='lobby:'||m.lobby_id::text);
$function$;

CREATE OR REPLACE FUNCTION game_private.lobby_api (
  p_action     text,
  p_lobby      uuid DEFAULT NULL::uuid,
  p_connection uuid DEFAULT NULL::uuid
)
  RETURNS jsonb
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
 select game_private.room_api(p_action,p_lobby,p_connection,'tic-tac-toe',2,'public',null,null,true);
$function$;

CREATE OR REPLACE FUNCTION game_private.play_move (
  p_lobby    uuid,
  p_cell     integer,
  p_revision integer
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare match_id uuid;
begin
 if game_private.valid_actor() is null then raise exception 'Your session ended. Sign in again.' using errcode='PT401'; end if;
 select m.id into match_id from game_private.matches m join game_private.lobbies l on l.id=m.lobby_id
 where l.id=p_lobby and l.round=1 and m.round=1;
 if match_id is null then raise exception 'Refresh to use the current match.' using errcode='40001'; end if;
 return game_private.submit_move(p_lobby,p_cell,p_revision,match_id);
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
 delete from game_private.connections where lobby_id=p_id and expires_at<=now();
 if room.status='playing' and room.game_id='tic-tac-toe' and (select count(*) from game_private.memberships where lobby_id=p_id)<>2 then
  perform game_private.close_lobby(p_id,'A player left. The match was interrupted.');
 elsif not exists(select 1 from game_private.connections where lobby_id=p_id and user_id=room.host_id) then
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
 previous uuid; new_id uuid; free_seat smallint; chosen_x uuid; normalized_code text; member_count integer;
begin
 if actor is null then raise exception 'Your session ended. Sign in again.' using errcode='PT401'; end if;
 if p_action is null or p_action not in ('create','join','join_code','current','snapshot','heartbeat','leave','start','rematch','cancel_rematch') then
  raise exception 'Unknown room action.' using errcode='22023'; end if;
 normalized_code:=upper(regexp_replace(left(coalesce(p_code,''),64),'[[:space:]-]','','g'));
 if p_action<>'leave' then perform game_private.consume_budget(actor); end if;
 select * into catalog from public.game_catalog where id=p_game and id in ('tic-tac-toe','poker');
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
  insert into game_private.memberships(lobby_id,user_id,display_name,mark,seat) values(new_id,actor,coalesce(game_private.guest_name(),'Guest'),case when p_game='tic-tac-toe' then 'X' else null end,1);
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
   if room.status<>'waiting' or (select count(*) from game_private.memberships where lobby_id=p_lobby)>=room.capacity then
    if p_action='join_code' then return jsonb_build_object('error','Room not found or unavailable.','code','ROOM_UNAVAILABLE'); end if;
    if room.status<>'waiting' then raise exception 'This lobby is no longer accepting players.'; end if;
    raise exception 'This lobby is full.';
   end if;
   select n::smallint into free_seat from generate_series(1,room.capacity) n where not exists(select 1 from game_private.memberships m where m.lobby_id=p_lobby and m.seat=n) order by n limit 1;
   if previous is not null and previous<>p_lobby then delete from game_private.memberships where user_id=actor; perform game_private.sync_summary(previous); end if;
   insert into game_private.memberships(lobby_id,user_id,display_name,mark,seat) values(p_lobby,actor,coalesce(game_private.guest_name(),'Guest'),case when p_game='tic-tac-toe' then 'O' else null end,free_seat);
  end if;
 elsif p_action='leave' then
  if room.status in ('waiting','playing') then
   if room.host_id=actor then perform game_private.close_lobby(p_lobby,'The host left.');
   elsif room.status='playing' then perform game_private.close_lobby(p_lobby,'A player left. The match was interrupted.'); end if;
  end if;
  delete from game_private.memberships where lobby_id=p_lobby and user_id=actor;
  perform game_private.sync_summary(p_lobby); return null;
 elsif p_action='start' then
  if room.host_id<>actor then raise exception 'Only the host can start.' using errcode='42501'; end if;
  if not catalog.playable or p_game<>'tic-tac-toe' then raise exception 'Poker gameplay is not available yet.'; end if;
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
 elsif p_action in ('rematch','cancel_rematch') then
  if p_round is null then raise exception 'Round required.' using errcode='22023'; end if;
  if p_round<room.round then return game_private.room_snapshot(p_lobby); end if;
  if p_round<>room.round or room.status<>'finished' or p_game<>'tic-tac-toe' then raise exception 'This match cannot be restarted.'; end if;
  if p_action='cancel_rematch' then delete from game_private.rematch_votes where lobby_id=p_lobby and user_id=actor and round=room.round;
  else
   if (select count(*) from game_private.memberships where lobby_id=p_lobby)<>2 or exists(select 1 from game_private.memberships m where m.lobby_id=p_lobby and not exists(select 1 from game_private.connections c where c.lobby_id=p_lobby and c.user_id=m.user_id and c.expires_at>now())) then raise exception 'Two connected players are required.'; end if;
   insert into game_private.rematch_votes values(p_lobby,actor,room.round) on conflict do nothing;
   if (select count(*) from game_private.rematch_votes where lobby_id=p_lobby and round=room.round)=2 then
    select user_id into chosen_x from game_private.memberships where lobby_id=p_lobby and mark='O';
    update game_private.memberships set mark=null where lobby_id=p_lobby;
    update game_private.memberships set mark=case when user_id=chosen_x then 'X' else 'O' end where lobby_id=p_lobby;
    update game_private.lobbies set status='playing',round=round+1,closed_at=null,reason=null where id=p_lobby;
    insert into game_private.matches(lobby_id,round) values(p_lobby,room.round+1);
    perform game_private.sync_summary(p_lobby);
   end if;
  end if;
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
 select jsonb_build_object('id',l.id,'game_id',l.game_id,'host_id',l.host_id,'status',l.status,'reason',l.reason,
 'capacity',l.capacity,'visibility',l.visibility,'join_code',l.join_code,'round',l.round,'contract_version',l.contract_version,
 'playable',g.playable,'min_players',g.min_players,
 'title',coalesce((select display_name from game_private.memberships where lobby_id=l.id and user_id=l.host_id),'Guest')||'''s lobby',
 'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'display_name',m.display_name,'mark',m.mark,'seat',m.seat,
 'rematch',exists(select 1 from game_private.rematch_votes v where v.lobby_id=l.id and v.user_id=m.user_id and v.round=l.round),
 'connected',exists(select 1 from game_private.connections c where c.lobby_id=l.id and c.user_id=m.user_id and c.expires_at>now())) order by m.seat)
 from game_private.memberships m where m.lobby_id=l.id),'[]'::jsonb),
 'match',(select jsonb_build_object('id',a.id,'status',a.status,'board',a.board,'current_turn',a.current_turn,'reason',a.reason,
 'revision',a.revision,'winner',a.winner,'winning_line',a.winning_line,'round',a.round) from game_private.matches a where a.lobby_id=l.id and a.round=l.round))
 from game_private.lobbies l join public.game_catalog g on g.id=l.game_id where l.id=p_id;
$function$;

CREATE OR REPLACE FUNCTION game_private.submit_move (
  p_lobby    uuid,
  p_cell     integer,
  p_revision integer,
  p_match    uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  actor uuid := game_private.valid_actor();
  room game_private.lobbies;
  game game_private.matches;
  mark text;
  next_board jsonb;
  line smallint[];
  win smallint[] := null;
  finished boolean := false;
begin
  if actor is null then raise exception 'Your session ended. Sign in again.' using errcode='PT401'; end if;
  if p_lobby is null or p_cell is null or p_cell<0 or p_cell>8 or p_revision is null or p_revision<0 or p_revision>8 then
    raise exception 'Invalid move.' using errcode='22023';
  end if;
  perform game_private.consume_budget(actor);
  select * into room from game_private.lobbies where id=p_lobby for update;
  if not found then raise exception 'Lobby not found.' using errcode='P0002'; end if;
  if room.game_id<>'tic-tac-toe' then raise exception 'This game does not use this move API.' using errcode='22023'; end if;
  select m.mark into mark from game_private.memberships m where m.lobby_id=p_lobby and m.user_id=actor;
  if not found then raise exception 'You are not a member of this lobby.' using errcode='42501'; end if;
  perform game_private.prune_lobby(p_lobby);
  select * into room from game_private.lobbies where id=p_lobby;
  select * into game from game_private.matches where lobby_id=p_lobby and round=room.round for update;
  if not found or room.status<>'playing' or game.status<>'playing' then raise exception 'This match is not accepting moves.'; end if;
  if not exists(select 1 from game_private.memberships m where m.lobby_id=p_lobby and m.user_id=actor) then
    raise exception 'Your seat expired.' using errcode='42501';
  end if;
  if p_match is null or game.id<>p_match then raise exception 'This move belongs to an earlier match.' using errcode='40001'; end if;
  if game.revision<>p_revision then raise exception 'The board changed. Refresh and try again.' using errcode='40001'; end if;
  if game.current_turn<>mark then raise exception 'It is not your turn.' using errcode='42501'; end if;
  if game.board->p_cell <> 'null'::jsonb then raise exception 'That cell is occupied.'; end if;
  next_board := jsonb_set(game.board,array[p_cell::text],to_jsonb(mark));
  foreach line slice 1 in array array[[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]]::smallint[][] loop
    if next_board->>line[1]=mark and next_board->>line[2]=mark and next_board->>line[3]=mark then win:=line; exit; end if;
  end loop;
  finished := win is not null or game.revision+1=9;
  update game_private.matches set board=next_board,revision=game.revision+1,
    current_turn=case when finished then mark when mark='X' then 'O' else 'X' end,
    status=case when finished then 'finished' else 'playing' end,
    winner=case when win is not null then mark else null end,winning_line=win
  where id=game.id;
  if finished then
    update game_private.lobbies set status='finished',closed_at=now() where id=p_lobby;
    perform game_private.sync_summary(p_lobby);
  end if;
  return game_private.room_api('snapshot',p_lobby,null,'tic-tac-toe');
end;
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
 (select count(*) from game_private.memberships p where p.lobby_id=l.id)::smallint,l.capacity,l.status,
 coalesce((select max(c.expires_at) from game_private.connections c where c.lobby_id=l.id and c.user_id=l.host_id),'-infinity'),l.created_at
 from game_private.lobbies l left join game_private.memberships m on m.lobby_id=l.id and m.user_id=l.host_id
 where l.id=p_id and l.visibility='public'
 on conflict(id) do update set title=excluded.title,player_count=excluded.player_count,capacity=excluded.capacity,status=excluded.status,host_expires_at=excluded.host_expires_at
 where (lobby_summaries.title,lobby_summaries.player_count,lobby_summaries.capacity,lobby_summaries.status,lobby_summaries.host_expires_at)
 is distinct from(excluded.title,excluded.player_count,excluded.capacity,excluded.status,excluded.host_expires_at);
end;
$function$;

CREATE OR REPLACE FUNCTION public.room_action (
  p_action     text,
  p_lobby      uuid    DEFAULT NULL::uuid,
  p_connection uuid    DEFAULT NULL::uuid,
  p_game       text    DEFAULT 'tic-tac-toe'::text,
  p_capacity   integer DEFAULT NULL::integer,
  p_visibility text    DEFAULT 'public'::text,
  p_code       text    DEFAULT NULL::text,
  p_round      integer DEFAULT NULL::integer
)
  RETURNS jsonb
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
 select game_private.room_api(p_action,p_lobby,p_connection,p_game,p_capacity,p_visibility,p_code,p_round,false);
$function$;

REVOKE ALL ON FUNCTION "public"."room_action"(text, uuid, uuid, text, integer, text, text, integer) FROM PUBLIC, "anon";

CREATE OR REPLACE FUNCTION public.submit_move (
  p_lobby    uuid,
  p_cell     integer,
  p_revision integer,
  p_match    uuid
)
  RETURNS jsonb
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
 select game_private.submit_move(p_lobby,p_cell,p_revision,p_match);
$function$;

REVOKE ALL ON FUNCTION "public"."submit_move"(uuid, integer, integer, uuid) FROM PUBLIC, "anon";

ALTER TABLE "game_private"."lobbies"
  ADD CONSTRAINT "lobbies_capacity_check" CHECK (((capacity >= 2) AND (capacity <= 6)));

ALTER TABLE "game_private"."lobbies"
  ADD CONSTRAINT "lobbies_contract_version_check" CHECK ((contract_version = ANY (ARRAY[1, 2])));

ALTER TABLE "game_private"."lobbies"
  ADD CONSTRAINT "lobbies_join_code_key" UNIQUE (join_code);

ALTER TABLE "game_private"."lobbies"
  ADD CONSTRAINT "lobbies_round_check" CHECK ((round > 0));

ALTER TABLE "game_private"."lobbies"
  ADD CONSTRAINT "lobbies_visibility_check" CHECK ((visibility = ANY (ARRAY['public'::text, 'private'::text])));

ALTER TABLE "game_private"."lobbies"
  ADD CONSTRAINT "private_room_code" CHECK ((((visibility = 'private'::text) AND (join_code IS
    NOT NULL) AND (join_code ~ '^[0-9A-F]{16}$'::text)) OR ((visibility = 'public'::text) AND (join_code IS NULL))));

ALTER TABLE "game_private"."matches"
  ADD CONSTRAINT "matches_round_check" CHECK ((round > 0));

ALTER TABLE "game_private"."matches"
  ADD CONSTRAINT "unique_room_round" UNIQUE (lobby_id, round);

ALTER TABLE "game_private"."memberships"
  ADD CONSTRAINT "seat_range" CHECK (((seat >= 1) AND (seat <= 6)));

ALTER TABLE "game_private"."memberships"
  ADD CONSTRAINT "unique_room_seat" UNIQUE (lobby_id, seat);

ALTER TABLE "game_private"."rematch_votes"
  ADD CONSTRAINT "rematch_votes_lobby_id_round_fkey" FOREIGN KEY (lobby_id, round) REFERENCES game_private.matches(lobby_id, round) ON DELETE CASCADE;

ALTER TABLE "game_private"."rematch_votes"
  ADD CONSTRAINT "rematch_votes_lobby_id_user_id_fkey" FOREIGN KEY (lobby_id, user_id) REFERENCES game_private.memberships(lobby_id, user_id) ON DELETE CASCADE;

ALTER TABLE "public"."game_catalog"
  ADD CONSTRAINT "game_catalog_capacity_check" CHECK (((capacity >= 2) AND (capacity <= 6)));

ALTER TABLE "public"."game_catalog"
  ADD CONSTRAINT "game_catalog_contract_version_check" CHECK ((contract_version = 2));

ALTER TABLE "public"."game_catalog"
  ADD CONSTRAINT "game_catalog_min_players_check" CHECK (((min_players >= 2) AND (min_players <= 6)));

ALTER TABLE "public"."lobby_summaries"
  ADD CONSTRAINT "lobby_summaries_capacity_check" CHECK (((capacity >= 2) AND (capacity <= 6)));

ALTER TABLE "public"."lobby_summaries"
  ADD CONSTRAINT "lobby_summaries_player_count_check" CHECK (((player_count >= 0) AND (player_count <= capacity)));

CREATE INDEX rematch_round_idx ON game_private.rematch_votes USING btree (lobby_id, round);

REVOKE ALL ON FUNCTION "game_private"."lobby_api"(text, uuid, uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION "game_private"."lobby_api"(text, uuid, uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "game_private"."room_api"(text, uuid, uuid, text, integer, text, text, integer, boolean) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION "game_private"."room_api"(text, uuid, uuid, text, integer, text, text, integer, boolean) TO "authenticated";

REVOKE ALL ON FUNCTION "game_private"."room_snapshot"(uuid) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION "game_private"."submit_move"(uuid, integer, integer, uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION "game_private"."submit_move"(uuid, integer, integer, uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "game_private"."sync_summary"(uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION "public"."room_action"(text, uuid, uuid, text, integer, text, text, integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."room_action"(text, uuid, uuid, text, integer, text, text, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."room_action"(text, uuid, uuid, text, integer, text, text, integer) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."room_action"(text, uuid, uuid, text, integer, text, text, integer) TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."submit_move"(uuid, integer, integer, uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."submit_move"(uuid, integer, integer, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."submit_move"(uuid, integer, integer, uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."submit_move"(uuid, integer, integer, uuid) TO "service_role";


-- Catalog rows and backfills are data changes and are not generated by schema diff.
UPDATE public.game_catalog SET launch_path='/tic-tac-toe/' WHERE id='tic-tac-toe';
INSERT INTO public.game_catalog(id,name,capacity,min_players,playable,contract_version,launch_path)
VALUES('poker','Poker',6,2,false,2,'/poker/');
NOTIFY pgrst,'reload schema';
