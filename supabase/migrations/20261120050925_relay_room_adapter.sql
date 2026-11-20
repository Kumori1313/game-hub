begin;

insert into public.game_catalog(id,name,min_players,capacity,playable,contract_version,launch_path)
values ('relay-room','Relay Room',2,2,false,2,'/relay-room/');

create function game_private.relay_room_adapter(event text, lobby uuid, actor uuid, playable boolean)
returns jsonb language plpgsql set search_path = '' as $$
declare
  room game_private.lobbies;
begin
  if event = 'snapshot' then
    return jsonb_build_object('relay', (select jsonb_build_object('actor',m.user_id,'seat',m.seat)
      from game_private.memberships m where m.lobby_id=lobby and m.user_id=actor));
  elsif event = 'start' then
    select * into strict room from game_private.lobbies where id=lobby;
    if not playable then raise exception 'Relay Room is not enabled.'; end if;
    if room.status = 'playing' then return to_jsonb(lobby); end if;
    if room.status <> 'waiting' then raise exception 'The room has ended.'; end if;
    if (select count(*) from game_private.memberships m where m.lobby_id=lobby and exists
      (select 1 from game_private.connections c where c.lobby_id=lobby and c.user_id=m.user_id and c.expires_at>now())) <> 2
      then raise exception 'Two connected players are required.'; end if;
    update game_private.lobbies set status='playing' where id=lobby;
    perform game_private.sync_summary(lobby);
    return to_jsonb(lobby);
  elsif event in ('rematch','cancel_rematch') then
    raise exception 'Leave and create a new room for another run.';
  elsif event='leave' then
    select * into strict room from game_private.lobbies where id=lobby;
    if room.status in ('waiting','playing') and (room.host_id=actor or room.status='playing') then
      perform game_private.close_lobby(lobby,'An operator left the room.');
      delete from game_private.memberships where lobby_id=lobby;
      perform game_private.sync_summary(lobby);
      return 'true'::jsonb;
    end if;
  end if;
  return null;
end;
$$;
revoke all on function game_private.relay_room_adapter(text,uuid,uuid,boolean) from public, anon, authenticated;

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
 when 'poker' then
  if p_event='supported' then return 'true'::jsonb; end if;
  return game_private.poker_room_adapter(p_event,p_lobby,p_actor,p_round,p_legacy,p_playable,p_snapshot);
 else
  return null;
 end case;
end;
$function$;

commit;
