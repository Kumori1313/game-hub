begin;

-- Realtime checks these policies on private-channel admission. The topic is
-- derived from guarded memberships; each operator writes only its own lane.
create function game_private.relay_broadcast_allowed(topic text, publishing boolean)
returns boolean language sql stable security definer set search_path='' as $$
  select exists (
    select 1 from game_private.memberships m
    join game_private.lobbies l on l.id=m.lobby_id
    join public.game_catalog g on g.id=l.game_id
    where m.user_id=(select game_private.valid_actor())
      and l.game_id='relay-room' and l.status='playing' and g.playable
      and exists(select 1 from game_private.connections c where c.user_id=m.user_id
        and c.lobby_id=l.id and c.expires_at>now())
      and (
        (topic='relay:'||l.id||':'||l.round||':host' and (not publishing or l.host_id=m.user_id))
        or (topic='relay:'||l.id||':'||l.round||':guest' and (not publishing or l.host_id<>m.user_id))
      )
  );
$$;
revoke all on function game_private.relay_broadcast_allowed(text,boolean) from public,anon,authenticated;
grant execute on function game_private.relay_broadcast_allowed(text,boolean) to authenticated;

create policy "Read active Relay Room broadcasts" on realtime.messages
for select to authenticated using (
  extension='broadcast' and (select game_private.relay_broadcast_allowed(realtime.topic(),false))
);
create policy "Publish own Relay Room lane" on realtime.messages
for insert to authenticated with check (
  extension='broadcast' and (select game_private.relay_broadcast_allowed(realtime.topic(),true))
);
commit;
