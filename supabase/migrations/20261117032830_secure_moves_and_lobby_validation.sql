-- Reject NULL explicitly: SQL three-valued logic must not bypass dispatch or membership checks.
create or replace function game_private.lobby_api(p_action text, p_lobby uuid default null, p_connection uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  room game_private.lobbies;
  previous uuid;
  new_id uuid;
  member_name text;
  result jsonb;
begin
  if actor is null then raise exception 'Sign in as a guest first.' using errcode='42501'; end if;
  if p_action is null or p_action not in ('create','join','leave','heartbeat','snapshot','start','current') then
    raise exception 'Unknown lobby action.' using errcode='22023';
  end if;
  if p_action in ('create','join') then
    -- Serialize two tabs acting as the same guest, in addition to room locks.
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text,0));
    select lobby_id into previous from game_private.memberships where user_id=actor;
    if previous is not null then
      perform game_private.prune_lobby(previous);
      delete from game_private.memberships m using game_private.lobbies l
        where m.lobby_id=l.id and m.user_id=actor and l.status='closed';
      if exists (select 1 from game_private.memberships where user_id=actor and (p_action='create' or lobby_id<>p_lobby)) then
        raise exception 'Leave your current lobby first.' using errcode='P0001';
      end if;
    end if;
  end if;
  if p_action='current' then
    select lobby_id into p_lobby from game_private.memberships where user_id=actor;
    if p_lobby is null then return null; end if;
    perform game_private.prune_lobby(p_lobby);
    if (select status from game_private.lobbies where id=p_lobby)='closed' then return null; end if;
    return to_jsonb(p_lobby);
  end if;
  if p_action='create' then
    if p_connection is null then raise exception 'Connection ID required.'; end if;
    if (select count(*) from game_private.lobbies where host_id=actor and created_at>now()-interval '1 minute')>=10 then raise exception 'Too many new lobbies. Wait a minute and try again.'; end if;
    member_name := coalesce(game_private.guest_name(),'Guest');
    insert into game_private.lobbies(game_id,host_id) values('tic-tac-toe',actor) returning id into new_id;
    insert into game_private.memberships values(new_id,actor,member_name,'X');
    insert into game_private.connections values(new_id,actor,p_connection,now()+interval '90 seconds');
    perform game_private.sync_summary(new_id);
    return to_jsonb(new_id);
  end if;
  if p_lobby is null then raise exception 'Lobby ID required.'; end if;
  select * into room from game_private.lobbies where id=p_lobby for update;
  if not found then raise exception 'Lobby not found.' using errcode='P0002'; end if;
  if p_action is distinct from 'join' and not exists (select 1 from game_private.memberships where lobby_id=p_lobby and user_id=actor) then
    raise exception 'You are not a member of this lobby.' using errcode='42501';
  end if;
  -- An unexpired connection in another tab also keeps a guest present.
  perform game_private.prune_lobby(p_lobby);
  select * into room from game_private.lobbies where id=p_lobby;
  if p_action in ('heartbeat','snapshot') and not exists(select 1 from game_private.memberships where lobby_id=p_lobby and user_id=actor) then return null; end if;
  if p_action='join' then
    if p_connection is null then raise exception 'Connection ID required.'; end if;
    if room.status<>'waiting' then raise exception 'This lobby is no longer accepting players.'; end if;
    if not exists(select 1 from game_private.memberships where lobby_id=p_lobby and user_id=actor) then
      if (select count(*) from game_private.memberships where lobby_id=p_lobby)>=2 then raise exception 'This lobby is full.'; end if;
      insert into game_private.memberships values(p_lobby,actor,coalesce(game_private.guest_name(),'Guest'),'O');
    end if;
  elsif p_action='leave' then
    if room.status<>'closed' then
      if actor=room.host_id then perform game_private.close_lobby(p_lobby,'The host left.');
      elsif room.status='playing' then perform game_private.close_lobby(p_lobby,'A player left. The match was interrupted.');
      end if;
    end if;
    delete from game_private.memberships where lobby_id=p_lobby and user_id=actor;
    perform game_private.sync_summary(p_lobby);
    return null;
  elsif p_action='start' then
    if actor<>room.host_id then raise exception 'Only the host can start.' using errcode='42501'; end if;
    if room.status='playing' then return to_jsonb(p_lobby); end if;
    if room.status<>'waiting' then raise exception 'This lobby is closed.'; end if;
    if (select count(*) from game_private.memberships where lobby_id=p_lobby)<>2 then raise exception 'Two connected players are required.'; end if;
    if exists(select 1 from game_private.memberships m where m.lobby_id=p_lobby and not exists (
      select 1 from game_private.connections c where c.lobby_id=p_lobby and c.user_id=m.user_id and c.expires_at>now())) then
      raise exception 'Two connected players are required.';
    end if;
    insert into game_private.matches(lobby_id) values(p_lobby);
    update game_private.lobbies set status='playing' where id=p_lobby;
    perform game_private.sync_summary(p_lobby);
    return to_jsonb(p_lobby);
  end if;
  if p_action in ('join','heartbeat') and room.status<>'closed' then
    if not exists (select 1 from game_private.memberships where lobby_id=p_lobby and user_id=actor) then
      raise exception 'Your seat expired. Join the lobby again.' using errcode='42501';
    end if;
    if p_connection is null then raise exception 'Connection ID required.'; end if;
    -- Limit stale connection records per guest without evicting active tabs.
    if not exists(select 1 from game_private.connections where lobby_id=p_lobby and user_id=actor and connection_id=p_connection)
      and (select count(*) from game_private.connections where lobby_id=p_lobby and user_id=actor)>=20 then
      raise exception 'Too many open lobby tabs.';
    end if;
    insert into game_private.connections values(p_lobby,actor,p_connection,now()+interval '90 seconds')
      on conflict (lobby_id,user_id,connection_id) do update set expires_at=excluded.expires_at;
    update game_private.memberships set display_name=coalesce(game_private.guest_name(),'Guest') where lobby_id=p_lobby and user_id=actor;
    perform game_private.sync_summary(p_lobby);
  end if;
  select jsonb_build_object('id',l.id,'game_id',l.game_id,'host_id',l.host_id,'status',l.status,'reason',l.reason,
    'title',coalesce((select display_name from game_private.memberships where lobby_id=l.id and user_id=l.host_id),'Guest')||'''s lobby',
    'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'display_name',m.display_name,'mark',m.mark,
      'connected',exists(select 1 from game_private.connections c where c.lobby_id=l.id and c.user_id=m.user_id and c.expires_at>now())) order by m.mark)
      from game_private.memberships m where m.lobby_id=l.id),'[]'::jsonb),
    'match',(select jsonb_build_object('id',g.id,'status',g.status,'board',g.board,'current_turn',g.current_turn,'reason',g.reason)
      from game_private.matches g where g.lobby_id=l.id)) into result from game_private.lobbies l where l.id=p_lobby;
  return result;
end;
$$;
