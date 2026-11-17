-- Private membership/match writes require a live Auth session, not just a valid JWT.
create function game_private.valid_actor() returns uuid language sql stable security definer set search_path = '' as $$
  select u.id from auth.users u join auth.sessions s on s.user_id=u.id
  where u.id=auth.uid() and s.id=nullif(auth.jwt()->>'session_id','')::uuid
    and u.deleted_at is null and (u.banned_until is null or u.banned_until<=now())
    and (s.not_after is null or s.not_after>now()) limit 1;
$$;
revoke all on function game_private.valid_actor() from public, anon, authenticated;

create table game_private.request_buckets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  window_start timestamptz not null,
  request_count integer not null check (request_count>0)
);
alter table game_private.request_buckets enable row level security;
revoke all on game_private.request_buckets from public, anon, authenticated;
create function game_private.consume_budget(p_actor uuid) returns void language plpgsql set search_path = '' as $$
declare current_window timestamptz; previous_window timestamptz; previous_count integer; requests integer;
begin
  insert into game_private.request_buckets values(p_actor,'-infinity',1) on conflict (user_id) do nothing;
  select window_start,request_count into previous_window,previous_count from game_private.request_buckets where user_id=p_actor for update;
  -- Read wall-clock time after acquiring the row lock, so queued requests cannot rewind the window.
  current_window:=date_trunc('minute',clock_timestamp());
  requests:=case when previous_window=current_window then previous_count+1 else 1 end;
  if requests>600 then raise exception 'Too many requests. Wait a minute and try again.' using errcode='PT429'; end if;
  update game_private.request_buckets set window_start=current_window,request_count=requests where user_id=p_actor;
end;
$$;
revoke all on function game_private.consume_budget(uuid) from public, anon, authenticated;

alter table game_private.lobbies drop constraint lobbies_status_check;
alter table game_private.lobbies add constraint lobbies_status_check check (status in ('waiting','playing','closed','finished'));
alter table public.lobby_summaries drop constraint lobby_summaries_status_check;
alter table public.lobby_summaries add constraint lobby_summaries_status_check check (status in ('waiting','playing','closed','finished'));
alter table game_private.matches drop constraint matches_status_check;
alter table game_private.matches add constraint matches_status_check check (status in ('playing','aborted','finished'));
alter table game_private.matches add column revision smallint not null default 0 check (revision between 0 and 9);
alter table game_private.matches add column winner text check (winner in ('X','O'));
alter table game_private.matches add column winning_line smallint[];
alter table game_private.matches add constraint board_values check (board <@ '[null,"X","O"]'::jsonb);
alter table game_private.matches add constraint winning_line_shape check (winning_line is null or cardinality(winning_line)=3);
create index lobbies_terminal_idx on game_private.lobbies (closed_at) where status in ('closed','finished');
drop index game_private.lobbies_closed_idx;

create or replace function game_private.close_lobby(p_id uuid, p_reason text) returns void language sql set search_path = '' as $$
  update game_private.lobbies set status='closed',reason=p_reason,closed_at=now() where id=p_id and status in ('waiting','playing');
  update game_private.matches set status='aborted',reason=p_reason where lobby_id=p_id and status='playing';
$$;

create or replace function game_private.prune_lobby(p_id uuid) returns void language plpgsql set search_path = '' as $$
declare room game_private.lobbies;
begin
  select * into room from game_private.lobbies where id=p_id for update;
  if not found or room.status in ('closed','finished') then return; end if;
  delete from game_private.connections where lobby_id=p_id and expires_at <= now();
  if room.status='playing' and (select count(*) from game_private.memberships where lobby_id=p_id)<>2 then
    perform game_private.close_lobby(p_id,'A player left. The match was interrupted.');
  elsif not exists (select 1 from game_private.connections where lobby_id=p_id and user_id=room.host_id) then
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

create or replace function game_private.sweep_lobbies() returns void language plpgsql security definer set search_path = '' as $$
declare item record;
begin
  for item in select id from game_private.lobbies where status in ('waiting','playing') order by id for update skip locked loop
    perform game_private.prune_lobby(item.id);
  end loop;
  delete from game_private.lobbies where status in ('closed','finished') and closed_at < now()-interval '7 days';
  delete from game_private.request_buckets where window_start < now()-interval '2 hours';
end;
$$;

create or replace function game_private.can_join_topic(p_topic text) returns boolean language sql stable security definer set search_path = '' as $$
  select game_private.valid_actor() is not null and exists(select 1 from game_private.memberships m join game_private.lobbies l on l.id=m.lobby_id
    where m.user_id=game_private.valid_actor() and l.status in ('waiting','playing') and p_topic='lobby:'||m.lobby_id::text);
$$;

create or replace function game_private.lobby_api(p_action text, p_lobby uuid default null, p_connection uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := game_private.valid_actor();
  room game_private.lobbies;
  previous uuid;
  new_id uuid;
  member_name text;
  result jsonb;
begin
  if actor is null then raise exception 'Your session ended. Sign in again.' using errcode='PT401'; end if;
  if p_action is null or p_action not in ('create','join','leave','heartbeat','snapshot','start','current') then
    raise exception 'Unknown lobby action.' using errcode='22023';
  end if;
  if p_action<>'leave' then perform game_private.consume_budget(actor); end if;
  if p_action in ('create','join') then
    -- Serialize two tabs acting as the same guest, in addition to room locks.
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text,0));
    select lobby_id into previous from game_private.memberships where user_id=actor;
    if previous is not null then
      perform game_private.prune_lobby(previous);
      delete from game_private.memberships m using game_private.lobbies l
        where m.lobby_id=l.id and m.user_id=actor and l.status in ('closed','finished');
      if exists (select 1 from game_private.memberships where user_id=actor and (p_action='create' or lobby_id<>p_lobby)) then
        raise exception 'Leave your current lobby first.' using errcode='P0001';
      end if;
    end if;
  end if;
  if p_action='current' then
    select lobby_id into p_lobby from game_private.memberships where user_id=actor;
    if p_lobby is null then return null; end if;
    perform game_private.prune_lobby(p_lobby);
    if (select status from game_private.lobbies where id=p_lobby) in ('closed','finished') then return null; end if;
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
    if room.status in ('waiting','playing') then
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
  if p_action in ('join','heartbeat') and room.status in ('waiting','playing') then
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
    'match',(select jsonb_build_object('id',g.id,'status',g.status,'board',g.board,'current_turn',g.current_turn,'reason',g.reason,'revision',g.revision,'winner',g.winner,'winning_line',g.winning_line)
      from game_private.matches g where g.lobby_id=l.id)) into result from game_private.lobbies l where l.id=p_lobby;
  return result;
end;
$$;
-- No actor, mark, board, winner, or timestamp is accepted from the client.
create function game_private.play_move(p_lobby uuid,p_cell integer,p_revision integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
  select * into game from game_private.matches where lobby_id=p_lobby for update;
  if not found or room.status<>'playing' or game.status<>'playing' then raise exception 'This match is not accepting moves.'; end if;
  if not exists(select 1 from game_private.memberships m where m.lobby_id=p_lobby and m.user_id=actor) then
    raise exception 'Your seat expired.' using errcode='42501';
  end if;
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
  return game_private.lobby_api('snapshot',p_lobby,null);
end;
$$;
revoke all on function game_private.play_move(uuid,integer,integer) from public, anon, authenticated;
grant execute on function game_private.play_move(uuid,integer,integer) to authenticated;
create function public.play_move(p_lobby uuid,p_cell integer,p_revision integer)
returns jsonb language sql security invoker set search_path = '' as $$
  select game_private.play_move(p_lobby,p_cell,p_revision);
$$;
revoke all on function public.play_move(uuid,integer,integer) from public, anon, authenticated;
grant execute on function public.play_move(uuid,integer,integer) to authenticated;
