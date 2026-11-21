BEGIN;

SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION game_private.cs_web_relay_allowed (
  topic      text,
  publishing boolean
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select exists (
    select 1 from game_private.memberships m
    join game_private.lobbies l on l.id=m.lobby_id
    join public.game_catalog g on g.id=l.game_id
    where m.user_id=(select game_private.valid_actor())
      and l.game_id='cs-web' and l.status='playing' and g.playable
      and exists(select 1 from game_private.connections c where c.lobby_id=l.id
                 and c.user_id=m.user_id and c.expires_at>now())
      and (topic='cs-web:'||l.id||':'||l.round||':host' and (not publishing or l.host_id=m.user_id)
        or topic='cs-web:'||l.id||':'||l.round||':peer' and (not publishing or l.host_id<>m.user_id))
  );
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
      or (actor=host and coalesce(kind,'') not in ('offer','relay'))
      or (actor<>host and coalesce(kind,'') not in ('ready','answer','relay-ready'))
      or (kind<>'ready' and (coalesce(p_message->>'to','') !~ '^[0-9a-f-]{36}$'
          or (kind in ('offer','answer') and (jsonb_typeof(p_message->'sdp') is distinct from 'string'
          or length(p_message->>'sdp')=0))))
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

REVOKE ALL ON FUNCTION "game_private"."cs_web_relay_allowed"(text, boolean) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION "game_private"."cs_web_relay_allowed"(text, boolean) TO "authenticated";

create policy "Read active Counter-Attack Web relay lanes" on realtime.messages
for select to authenticated using (
  extension='broadcast' and (select game_private.cs_web_relay_allowed(realtime.topic(),false))
);
create policy "Publish own Counter-Attack Web relay lane" on realtime.messages
for insert to authenticated with check (
  extension='broadcast' and (select game_private.cs_web_relay_allowed(realtime.topic(),true))
);

COMMIT;
