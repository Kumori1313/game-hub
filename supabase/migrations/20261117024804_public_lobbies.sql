-- New public objects require explicit client grants, including on an existing project.
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated;
-- Public summaries are the only discovery data. Membership and matches stay private.
create schema if not exists game_private;
revoke all on schema game_private from public, anon, authenticated;
grant usage on schema game_private to authenticated;
alter default privileges in schema game_private revoke execute on functions from public;

create table public.game_catalog (
  id text primary key,
  name text not null,
  capacity smallint not null check (capacity = 2)
);
insert into public.game_catalog values ('tic-tac-toe', 'Tic-Tac-Toe', 2);
alter table public.game_catalog enable row level security;
revoke all on public.game_catalog from public, anon, authenticated;
grant select on public.game_catalog to authenticated;
grant all on public.game_catalog to service_role;
create policy "Guests read game catalog" on public.game_catalog for select to authenticated using (true);

create table game_private.lobbies (
  id uuid primary key default gen_random_uuid(),
  game_id text not null references public.game_catalog(id),
  host_id uuid not null references auth.users(id),
  status text not null default 'waiting' check (status in ('waiting', 'playing', 'closed')),
  reason text,
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create table game_private.memberships (
  lobby_id uuid not null references game_private.lobbies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 24),
  mark text not null check (mark in ('X', 'O')),
  primary key (lobby_id, user_id),
  unique (user_id),
  unique (lobby_id, mark)
);
create table game_private.connections (
  lobby_id uuid not null,
  user_id uuid not null,
  connection_id uuid not null,
  expires_at timestamptz not null,
  primary key (lobby_id, user_id, connection_id),
  foreign key (lobby_id, user_id) references game_private.memberships(lobby_id, user_id) on delete cascade
);
create index connections_expiry_idx on game_private.connections (expires_at);
create index lobbies_host_idx on game_private.lobbies (host_id, created_at desc);
create index lobbies_closed_idx on game_private.lobbies (closed_at) where status='closed';
create table game_private.matches (
  id uuid primary key default gen_random_uuid(),
  lobby_id uuid not null unique references game_private.lobbies(id) on delete cascade,
  status text not null default 'playing' check (status in ('playing', 'aborted')),
  board jsonb not null default '[null,null,null,null,null,null,null,null,null]'::jsonb,
  current_turn text not null default 'X' check (current_turn in ('X','O')),
  reason text,
  created_at timestamptz not null default now(),
  check (jsonb_typeof(board) = 'array' and jsonb_array_length(board) = 9)
);
create table public.lobby_summaries (
  id uuid primary key references game_private.lobbies(id) on delete cascade,
  game_id text not null references public.game_catalog(id),
  title text not null,
  player_count smallint not null check (player_count between 0 and 2),
  capacity smallint not null default 2 check (capacity = 2),
  status text not null check (status in ('waiting', 'playing', 'closed')),
  host_expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index lobby_discovery_idx on public.lobby_summaries (game_id, status, created_at desc);
alter table public.lobby_summaries enable row level security;
revoke all on public.lobby_summaries from public, anon, authenticated;
grant select on public.lobby_summaries to authenticated;
grant all on public.lobby_summaries to service_role;
create policy "Guests discover active lobbies" on public.lobby_summaries for select to authenticated
  using (status in ('waiting','playing') and host_expires_at > (select now()));

alter table game_private.lobbies enable row level security;
alter table game_private.memberships enable row level security;
alter table game_private.connections enable row level security;
alter table game_private.matches enable row level security;
revoke all on all tables in schema game_private from public, anon, authenticated;

-- Internal routines have no client execution grants. All privileged state changes
-- are behind the guarded dispatcher below, outside the exposed API schema.
create function game_private.guest_name() returns text language sql stable set search_path = '' as $$
  select case when char_length(btrim(raw_user_meta_data->>'display_name')) between 1 and 24
    and (raw_user_meta_data->>'display_name') !~ '[[:cntrl:]]'
    then btrim(raw_user_meta_data->>'display_name') else 'Guest' end
  from auth.users where id = auth.uid();
$$;
create function game_private.sync_summary(p_id uuid) returns void language sql set search_path = '' as $$
  insert into public.lobby_summaries (id,game_id,title,player_count,status,host_expires_at,created_at)
  select l.id,l.game_id,coalesce(m.display_name,'Guest') || '''s lobby',
    (select count(*) from game_private.memberships p where p.lobby_id=l.id)::smallint,
    l.status, coalesce((select max(c.expires_at) from game_private.connections c where c.lobby_id=l.id and c.user_id=l.host_id), '-infinity'),l.created_at
  from game_private.lobbies l left join game_private.memberships m on m.lobby_id=l.id and m.user_id=l.host_id
  where l.id=p_id
  on conflict (id) do update set title=excluded.title,player_count=excluded.player_count,
    status=excluded.status,host_expires_at=excluded.host_expires_at
  where (lobby_summaries.title,lobby_summaries.player_count,lobby_summaries.status,lobby_summaries.host_expires_at)
    is distinct from (excluded.title,excluded.player_count,excluded.status,excluded.host_expires_at);
$$;
create function game_private.close_lobby(p_id uuid, p_reason text) returns void language sql set search_path = '' as $$
  update game_private.lobbies set status='closed',reason=p_reason,closed_at=now() where id=p_id and status<>'closed';
  update game_private.matches set status='aborted',reason=p_reason where lobby_id=p_id and status='playing';
$$;
create function game_private.prune_lobby(p_id uuid) returns void language plpgsql set search_path = '' as $$
declare room game_private.lobbies;
begin
  select * into room from game_private.lobbies where id=p_id for update;
  if not found or room.status='closed' then return; end if;
  delete from game_private.connections where lobby_id=p_id and expires_at <= now();
  if not exists (select 1 from game_private.connections where lobby_id=p_id and user_id=room.host_id) then
    perform game_private.close_lobby(p_id,'The host disconnected.');
  elsif exists (select 1 from game_private.memberships m where m.lobby_id=p_id and m.user_id<>room.host_id
    and not exists (select 1 from game_private.connections c where c.lobby_id=p_id and c.user_id=m.user_id)) then
    if room.status='playing' then
      perform game_private.close_lobby(p_id,'A player disconnected. The match was interrupted.');
    else
      delete from game_private.memberships m where m.lobby_id=p_id and m.user_id<>room.host_id
        and not exists (select 1 from game_private.connections c where c.lobby_id=p_id and c.user_id=m.user_id);
    end if;
  end if;
  perform game_private.sync_summary(p_id);
end;
$$;

create function game_private.lobby_api(p_action text, p_lobby uuid default null, p_connection uuid default null)
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
  if p_action not in ('create','join','leave','heartbeat','snapshot','start','current') then
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
  if p_action<>'join' and not exists (select 1 from game_private.memberships where lobby_id=p_lobby and user_id=actor) then
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
-- A single invoker wrapper exposes only the guarded operation, never tables.
create function public.lobby_action(p_action text, p_lobby uuid default null, p_connection uuid default null)
returns jsonb language sql security invoker set search_path = '' as $$
  select game_private.lobby_api(p_action,p_lobby,p_connection);
$$;
revoke all on all functions in schema game_private from public, anon, authenticated;
grant execute on function game_private.lobby_api(text,uuid,uuid) to authenticated;
revoke all on function public.lobby_action(text,uuid,uuid) from public, anon, authenticated;
grant execute on function public.lobby_action(text,uuid,uuid) to authenticated, service_role;

create function game_private.can_join_topic(p_topic text) returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists(select 1 from game_private.memberships m join game_private.lobbies l on l.id=m.lobby_id
    where m.user_id=auth.uid() and l.status in ('waiting','playing') and p_topic='lobby:'||m.lobby_id::text);
$$;
revoke all on function game_private.can_join_topic(text) from public, anon, authenticated;
grant execute on function game_private.can_join_topic(text) to authenticated;
create policy "Members receive lobby presence" on realtime.messages for select to authenticated
  using (extension='presence' and game_private.can_join_topic((select realtime.topic())));
create policy "Members publish lobby presence" on realtime.messages for insert to authenticated
  with check (extension='presence' and game_private.can_join_topic((select realtime.topic())));

alter publication supabase_realtime add table public.lobby_summaries;

-- Trusted cleanup continues when no browser remains. It never trusts Presence payloads.
create function game_private.sweep_lobbies() returns void language plpgsql security definer set search_path = '' as $$
declare item record;
begin
  for item in select id from game_private.lobbies where status<>'closed' order by id for update skip locked loop
    perform game_private.prune_lobby(item.id);
  end loop;
  delete from game_private.lobbies where status='closed' and closed_at < now()-interval '7 days';
end;
$$;
revoke all on function game_private.sweep_lobbies() from public, anon, authenticated;
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('game-hub-lobby-cleanup','* * * * *','select game_private.sweep_lobbies()');
