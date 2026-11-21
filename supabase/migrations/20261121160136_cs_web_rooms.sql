BEGIN;

INSERT INTO public.game_catalog(id,name,min_players,capacity,playable,contract_version,launch_path)
VALUES ('cs-web','Counter-Attack Web',2,2,true,2,'/Counter-Attack-Web/');

SET local check_function_bodies = off;

CREATE TABLE "game_private"."cs_web_signals" (
  "lobby_id" uuid  NOT NULL,
  "user_id"  uuid  NOT NULL,
  "message"  jsonb NOT NULL,
  CONSTRAINT "cs_web_signals_pkey" PRIMARY KEY (lobby_id, user_id)
);

ALTER TABLE "game_private"."cs_web_signals"
  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION game_private.cs_web_room_adapter (
  event    text,
  lobby    uuid,
  actor    uuid,
  playable boolean
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  room game_private.lobbies;
begin
  if event not in ('start','leave','rematch','cancel_rematch') then return null; end if;
  select * into strict room from game_private.lobbies where id=lobby;
  if event='start' then
    if not playable then raise exception 'Counter-Attack Web is not enabled.'; end if;
    if room.status='playing' then return to_jsonb(lobby); end if;
    if room.status<>'waiting' then raise exception 'The room has ended.'; end if;
    if (select count(*) from game_private.memberships m where m.lobby_id=lobby and exists
        (select 1 from game_private.connections c where c.lobby_id=lobby
         and c.user_id=m.user_id and c.expires_at>now()))<>2 then
      raise exception 'Two connected players are required.';
    end if;
    update game_private.lobbies set status='playing' where id=lobby;
    perform game_private.sync_summary(lobby);
    return to_jsonb(lobby);
  elsif event in ('rematch','cancel_rematch') then
    raise exception 'Create a new lobby for another match.';
  elsif room.status in ('waiting','playing') and (room.host_id=actor or room.status='playing') then
    perform game_private.close_lobby(lobby,'A player left the room.');
    delete from game_private.memberships where lobby_id=lobby;
    perform game_private.sync_summary(lobby);
    return 'true'::jsonb;
  end if;
  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION game_private.cs_web_signal (
  p_lobby   uuid,
  p_message jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  actor uuid:=game_private.valid_actor();
  host uuid;
  kind text;
begin
  if actor is null then raise exception 'Your session ended. Sign in again.' using errcode='PT401'; end if;
  perform game_private.consume_budget(actor);
  select l.host_id into host from game_private.lobbies l
    join public.game_catalog g on g.id=l.game_id
    where l.id=p_lobby and l.game_id='cs-web' and l.status='playing' and g.playable
    for share of l;
  if not found or not exists(
    select 1 from game_private.memberships m where m.lobby_id=p_lobby and m.user_id=actor
    and exists(select 1 from game_private.connections c where c.lobby_id=p_lobby
               and c.user_id=actor and c.expires_at>now())
  ) then
    raise exception 'An active room seat is required.' using errcode='42501';
  end if;
  if p_message is not null then
    kind:=p_message->>'kind';
    if jsonb_typeof(p_message)<>'object' or octet_length(p_message::text)>24000
      or coalesce(p_message->>'from','') !~ '^[0-9a-f-]{36}$'
      or (actor=host and kind is distinct from 'offer')
      or (actor<>host and coalesce(kind,'') not in ('ready','answer'))
      or (kind<>'ready' and (coalesce(p_message->>'to','') !~ '^[0-9a-f-]{36}$'
          or jsonb_typeof(p_message->'sdp') is distinct from 'string'
          or length(p_message->>'sdp')=0))
    then raise exception 'Invalid connection setup message.' using errcode='22023';
    end if;
    insert into game_private.cs_web_signals(lobby_id,user_id,message)
      values(p_lobby,actor,p_message)
      on conflict(lobby_id,user_id) do update set message=excluded.message;
  end if;
  return (select s.message from game_private.cs_web_signals s
    where s.lobby_id=p_lobby and s.user_id<>actor
    and exists(select 1 from game_private.connections c where c.lobby_id=p_lobby
               and c.user_id=s.user_id and c.expires_at>now()));
end;
$function$;

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
 when 'relay-room' then
  if p_event='supported' then return 'true'::jsonb; end if;
  return game_private.relay_room_adapter(p_event,p_lobby,p_actor,p_playable);
 when 'cs-web' then
  if p_event='supported' then return 'true'::jsonb; end if;
  return game_private.cs_web_room_adapter(p_event,p_lobby,p_actor,p_playable);
 when 'poker' then
  if p_event='supported' then return 'true'::jsonb; end if;
  return game_private.poker_room_adapter(p_event,p_lobby,p_actor,p_round,p_legacy,p_playable,p_snapshot);
 else
  return null;
 end case;
end;
$function$;

CREATE OR REPLACE FUNCTION public.cs_web_signal (
  p_lobby   uuid,
  p_message jsonb DEFAULT NULL::jsonb
)
  RETURNS jsonb
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
  select game_private.cs_web_signal(p_lobby,p_message);
$function$;

REVOKE ALL ON FUNCTION "public"."cs_web_signal"(uuid, jsonb) FROM PUBLIC, "anon";

ALTER TABLE "game_private"."cs_web_signals"
  ADD CONSTRAINT "cs_web_signals_lobby_id_user_id_fkey" FOREIGN KEY (lobby_id, user_id) REFERENCES game_private.memberships(lobby_id, user_id) ON DELETE CASCADE;

REVOKE ALL ON FUNCTION "game_private"."cs_web_room_adapter"(text, uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION "game_private"."cs_web_signal"(uuid, jsonb) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION "game_private"."cs_web_signal"(uuid, jsonb) TO "authenticated";

GRANT EXECUTE ON FUNCTION "public"."cs_web_signal"(uuid, jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."cs_web_signal"(uuid, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."cs_web_signal"(uuid, jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."cs_web_signal"(uuid, jsonb) TO "service_role";

REVOKE ALL ON game_private.cs_web_signals FROM PUBLIC, anon, authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
