-- Immutable per-room rules and bounded, audited play-chip rebuys.
BEGIN;
SET local check_function_bodies = off;

ALTER TABLE "game_private"."poker_tables"
  DROP CONSTRAINT "poker_tables_min_raise_check";

ALTER TABLE "game_private"."poker_tables"
  DROP CONSTRAINT "poker_tables_minted_check";

CREATE TABLE "game_private"."poker_rebuys" (
  "lobby_id"   uuid                     NOT NULL,
  "user_id"    uuid                     NOT NULL,
  "rebuy_no"   integer                  NOT NULL,
  "hand_id"    uuid                     NOT NULL,
  "amount"     integer                  NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "poker_rebuys_amount_check" CHECK (((amount >= 100) AND (amount <= 10000))),
  CONSTRAINT "poker_rebuys_pkey" PRIMARY KEY (lobby_id, user_id, rebuy_no),
  CONSTRAINT "poker_rebuys_rebuy_no_check" CHECK (((rebuy_no >= 1) AND (rebuy_no <= 3)))
);

ALTER TABLE "game_private"."poker_rebuys"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "game_private"."poker_settings" (
  "lobby_id"       uuid    NOT NULL,
  "starting_chips" integer NOT NULL DEFAULT 1000,
  "big_blind"      integer NOT NULL DEFAULT 20,
  "turn_seconds"   integer NOT NULL DEFAULT 30,
  "rebuy_limit"    integer NOT NULL DEFAULT 0,
  CONSTRAINT "poker_settings_big_blind_check" CHECK ((big_blind = ANY (ARRAY[10, 20, 50, 100, 200, 500]))),
  CONSTRAINT "poker_settings_check" CHECK ((starting_chips >= (big_blind * 20))),
  CONSTRAINT "poker_settings_pkey" PRIMARY KEY (lobby_id),
  CONSTRAINT "poker_settings_rebuy_limit_check" CHECK ((rebuy_limit = ANY (ARRAY[0, 1, 3]))),
  CONSTRAINT "poker_settings_starting_chips_check" CHECK ((((starting_chips >= 100) AND (starting_chips <= 10000)) AND ((starting_chips % 100) = 0))),
  CONSTRAINT "poker_settings_turn_seconds_check" CHECK ((turn_seconds = ANY (ARRAY[15, 30, 45, 60, 90])))
);

ALTER TABLE "game_private"."poker_settings"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "game_private"."poker_players"
  ADD COLUMN "rebuy_count" integer NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION game_private.create_poker_room_api (
  p_capacity   integer DEFAULT 6,
  p_visibility text    DEFAULT 'public'::text,
  p_settings   jsonb   DEFAULT '{}'::jsonb,
  p_connection uuid    DEFAULT NULL::uuid
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
 id:=(game_private.room_api('create',null,p_connection,'poker',p_capacity,p_visibility)#>>'{}')::uuid;
 update game_private.poker_settings set starting_chips=chips,big_blind=blind,turn_seconds=seconds,rebuy_limit=rebuys where lobby_id=id;
 return id;
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_advance (
  p_id    uuid,
  p_after integer
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare t game_private.poker_tables;live integer;funded integer;next_seat smallint;other_bet bigint;guard integer;draw_count integer;next_street text;cfg game_private.poker_settings;
begin
 select * into cfg from game_private.poker_settings where lobby_id=p_id;
 for guard in 1..6 loop
  select * into t from game_private.poker_tables where lobby_id=p_id for update;
  if t.street='complete' then return;end if;
  select count(*),count(*) filter(where stack>0 and not departed) into live,funded from game_private.poker_players where lobby_id=p_id and in_hand and not folded;
  if live<=1 then perform game_private.poker_settle(p_id,false);return;end if;
  next_seat:=null;
  if funded=1 then
   select seat into next_seat from game_private.poker_players where lobby_id=p_id and in_hand and not folded and not departed and stack>0;
   select coalesce(max(street_bet),0) into other_bet from game_private.poker_players where lobby_id=p_id and in_hand and not folded and seat<>next_seat;
   if (select street_bet from game_private.poker_players where lobby_id=p_id and seat=next_seat)>=other_bet then next_seat:=null;
   else update game_private.poker_tables set current_bet=other_bet where lobby_id=p_id;end if;
  elsif funded>1 then
   select seat into next_seat from game_private.poker_players where lobby_id=p_id and in_hand and not folded and not departed and stack>0 and (not acted or street_bet<t.current_bet)
    order by (seat-p_after+5)%6 limit 1;
  end if;
  if next_seat is not null then
   update game_private.poker_tables set turn_seat=next_seat,deadline=clock_timestamp()+case when (select is_bot from game_private.poker_players where lobby_id=p_id and seat=next_seat) then interval '2 seconds' else make_interval(secs=>cfg.turn_seconds) end where lobby_id=p_id;return;
  end if;
  if t.street='river' then perform game_private.poker_settle(p_id,true);return;end if;
  next_street:=case t.street when 'preflop' then 'flop' when 'flop' then 'turn' else 'river' end;
  draw_count:=case when next_street='flop' then 3 else 1 end;
  -- Burn one unseen card, then expose only the cards for the next street.
  update game_private.poker_tables set street=next_street,board=board||deck[(cursor+1):(cursor+draw_count)],cursor=cursor+draw_count+1,current_bet=0,min_raise=cfg.big_blind where lobby_id=p_id;
  update game_private.poker_players set street_bet=0,acted=false,last_bet=0,last_raise=cfg.big_blind where lobby_id=p_id;
  p_after:=t.dealer;
 end loop;
 raise exception 'Poker advancement exceeded its bound';
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_api (
  p_lobby    uuid,
  p_action   text,
  p_hand     uuid    DEFAULT NULL::uuid,
  p_revision integer DEFAULT NULL::integer,
  p_amount   bigint  DEFAULT NULL::bigint
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare actor uuid:=game_private.valid_actor();l game_private.lobbies;t game_private.poker_tables;p game_private.poker_players;target bigint;paid bigint;full_raise boolean;raise_ok boolean;
begin
 if actor is null then raise exception 'Your session ended. Sign in again.' using errcode='PT401';end if;
 if p_action is null or p_action not in ('start','fold','check','call','raise_to','all_in','next','rebuy') then raise exception 'Unknown poker action.' using errcode='22023';end if;
 if p_action<>'start' and (p_hand is null or p_revision is null or p_revision<0 or (p_action='raise_to' and (p_amount is null or p_amount<1 or p_amount>240000)) or (p_action<>'raise_to' and p_amount is not null)) then raise exception 'Invalid poker input.' using errcode='22023';end if;
 perform game_private.consume_budget(actor);
 select * into l from game_private.lobbies where id=p_lobby for update;
 if not found or l.game_id<>'poker' or not exists(select 1 from game_private.memberships where lobby_id=p_lobby and user_id=actor) then raise exception 'You are not a member of this poker table.' using errcode='42501';end if;
 if p_action='start' then
  if p_hand is not null or p_revision is not null or p_amount is not null then raise exception 'Invalid start input.' using errcode='22023';end if;
  if l.host_id<>actor then raise exception 'Only the host can start.' using errcode='42501';end if;
  if not (select playable from public.game_catalog where id='poker') then raise exception 'Poker is not available yet.';end if;
  perform game_private.prune_lobby(p_lobby);
  select * into l from game_private.lobbies where id=p_lobby;
  if l.status not in ('waiting','playing') then raise exception 'This table has finished.';end if;
  perform game_private.poker_start(p_lobby);return game_private.room_snapshot(p_lobby);
 end if;
 perform game_private.poker_tick(p_lobby);
 if not exists(select 1 from game_private.memberships where lobby_id=p_lobby and user_id=actor) then return jsonb_build_object('error','Your table seat expired.','code','42501');end if;
 select * into l from game_private.lobbies where id=p_lobby;
 select * into t from game_private.poker_tables where lobby_id=p_lobby for update;
 if not found then raise exception 'Start the table first.';end if;
 if t.hand_id<>p_hand or t.revision<>p_revision then return jsonb_build_object('error','The hand changed. Check the table and choose again.','code','40001');end if;
 if p_action='rebuy' then
  if l.status<>'playing' then raise exception 'This table has finished.';end if;
  perform game_private.poker_rebuy(p_lobby,actor);perform game_private.poker_assert(p_lobby);
  return game_private.room_snapshot(p_lobby);
 end if;
 if p_action='next' then
  if l.host_id<>actor then raise exception 'Only the host can deal the next hand.' using errcode='42501';end if;
  if l.status<>'playing' then raise exception 'This table has finished.';end if;
  if not (select playable from public.game_catalog where id='poker') then raise exception 'New hands are not available.';end if;
  perform game_private.poker_new_hand(p_lobby);return game_private.room_snapshot(p_lobby);
 end if;
 perform game_private.poker_apply(p_lobby,actor,p_action,p_amount);
 return game_private.room_snapshot(p_lobby);
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_assert (
  p_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare total bigint;bank bigint;
begin
 select sum(stack+committed) into total from game_private.poker_players where lobby_id=p_id;
 select minted into bank from game_private.poker_tables where lobby_id=p_id;
 if total is distinct from bank then raise exception 'Chip conservation failed';end if;
 if (select minted from game_private.poker_tables where lobby_id=p_id)<>(select count(*) from game_private.poker_players where lobby_id=p_id)*(select starting_chips from game_private.poker_settings where lobby_id=p_id)+coalesce((select sum(amount) from game_private.poker_rebuys where lobby_id=p_id),0) then raise exception 'Chip issuance ledger mismatch';end if;
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_default_settings()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
 if new.game_id='poker' then insert into game_private.poker_settings(lobby_id) values(new.id);end if;return new;
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_legacy_api (
  p_lobby    uuid,
  p_action   text,
  p_hand     uuid    DEFAULT NULL::uuid,
  p_revision integer DEFAULT NULL::integer,
  p_amount   bigint  DEFAULT NULL::bigint
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare actor uuid:=game_private.valid_actor();
begin
 if actor is null then raise exception 'Your session ended. Sign in again.' using errcode='PT401';end if;
 if not exists(select 1 from game_private.memberships where lobby_id=p_lobby and user_id=actor) then raise exception 'You are not a member of this table.' using errcode='42501';end if;
 if exists(select 1 from game_private.poker_settings where lobby_id=p_lobby and (starting_chips<>1000 or big_blind<>20 or turn_seconds<>30 or rebuy_limit<>0)) then raise exception 'Refresh this page to play with these table settings.';end if;
 return game_private.poker_api(p_lobby,p_action,p_hand,p_revision,p_amount);
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_new_hand (
  p_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare t game_private.poker_tables;seats smallint[];v_deck smallint[];n integer;i integer;j integer;tmp smallint;button smallint;sb smallint;bb smallint;position integer:=1;seat_no smallint;round_no integer;paid bigint;cfg game_private.poker_settings;
begin
 select * into t from game_private.poker_tables where lobby_id=p_id for update;
 select * into cfg from game_private.poker_settings where lobby_id=p_id;
 if t.street<>'complete' then raise exception 'This hand is still in progress.';end if;
 select array_agg(p.seat order by p.seat) into seats from game_private.poker_players p where p.lobby_id=p_id and not p.departed and p.stack>0
  and (p.is_bot or (exists(select 1 from game_private.memberships m where m.lobby_id=p_id and m.user_id=p.user_id)
  and exists(select 1 from game_private.connections c where c.lobby_id=p_id and c.user_id=p.user_id and c.expires_at>now())));
 n:=coalesce(cardinality(seats),0);if n<2 then raise exception 'Two connected players with chips are required.';end if;
 if t.hand_no=0 then button:=seats[game_private.poker_random(n)+1];
 elsif n=2 then
  select s into bb from unnest(seats)s order by (s-t.big_blind+5)%6 limit 1;
  select s into button from unnest(seats)s where s<>bb;
 else select s into button from unnest(seats)s order by (s-t.dealer+5)%6 limit 1;end if;
 if n=2 then sb:=button;select s into bb from unnest(seats)s where s<>button;
 else
  select s into sb from unnest(seats)s order by (s-button+5)%6 limit 1;
  select s into bb from unnest(seats)s order by (s-sb+5)%6 limit 1;
 end if;
 select array_agg(x::smallint order by x) into v_deck from generate_series(0,51)x;
 for i in reverse 52..2 loop j:=game_private.poker_random(i)+1;tmp:=v_deck[i];v_deck[i]:=v_deck[j];v_deck[j]:=tmp;end loop;
 update game_private.poker_players set hole='{}',in_hand=seat=any(seats),folded=false,acted=false,last_bet=0,last_raise=cfg.big_blind,street_bet=0,committed=0,payout=0,rank_score=null where lobby_id=p_id;
 for round_no in 1..2 loop
  for seat_no in select s from unnest(seats)s order by (s-button+5)%6 loop
   update game_private.poker_players set hole=array_append(hole,v_deck[position]) where lobby_id=p_id and seat=seat_no;position:=position+1;
  end loop;
 end loop;
 update game_private.poker_tables set hand_id=gen_random_uuid(),hand_no=hand_no+1,dealer=button,small_blind=sb,big_blind=bb,turn_seat=null,
  street='preflop',board='{}',deck=v_deck,cursor=position,current_bet=cfg.big_blind,min_raise=cfg.big_blind,revision=0,deadline=null,pots='[]',showdown=false,last_action='Blinds '||(cfg.big_blind/2)||'/'||cfg.big_blind||'.' where lobby_id=p_id;
 for seat_no in select unnest(array[sb,bb]) loop
  select least(stack,case when seat_no=sb then cfg.big_blind/2 else cfg.big_blind end) into paid from game_private.poker_players where lobby_id=p_id and seat=seat_no;
  update game_private.poker_players set stack=stack-paid,street_bet=paid,committed=paid where lobby_id=p_id and seat=seat_no;
 end loop;
 update game_private.lobbies set round=t.hand_no+1,status='playing',closed_at=null,reason=null where id=p_id;
 perform game_private.poker_advance(p_id,bb);
 perform game_private.sync_summary(p_id);perform game_private.poker_assert(p_id);
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_rebuy (
  p_id   uuid,
  p_user uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare t game_private.poker_tables;p game_private.poker_players;cfg game_private.poker_settings;
begin
 select * into t from game_private.poker_tables where lobby_id=p_id for update;
 select * into cfg from game_private.poker_settings where lobby_id=p_id;
 select * into p from game_private.poker_players where lobby_id=p_id and user_id=p_user for update;
 if not found or t.street<>'complete' or p.departed or p.stack<>0 or p.committed<>0 or p.rebuy_count>=cfg.rebuy_limit then raise exception 'A rebuy requires an empty stack between hands and an unused rebuy.';end if;
 insert into game_private.poker_rebuys(lobby_id,user_id,rebuy_no,hand_id,amount) values(p_id,p_user,p.rebuy_count+1,t.hand_id,cfg.starting_chips);
 update game_private.poker_players set stack=cfg.starting_chips,rebuy_count=rebuy_count+1 where lobby_id=p_id and user_id=p_user;
 update game_private.poker_tables set minted=minted+cfg.starting_chips,revision=revision+1,last_action='Seat '||p.seat||': rebuy ('||cfg.starting_chips||').' where lobby_id=p_id;
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_rehost (
  p_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare next_host uuid;
begin
 if not exists(select 1 from game_private.lobbies l join game_private.memberships m on m.lobby_id=l.id and m.user_id=l.host_id where l.id=p_id) then
  select user_id into next_host from game_private.memberships where lobby_id=p_id order by seat limit 1;
  if next_host is null then update game_private.lobbies set status='closed',closed_at=coalesce(closed_at,now()),reason='The table is empty.' where id=p_id;
  else update game_private.lobbies set host_id=next_host where id=p_id;end if;
 end if;
 if exists(select 1 from game_private.poker_tables where lobby_id=p_id and street='complete')
  and (select count(*) from game_private.poker_players where lobby_id=p_id and not departed and (stack>0 or rebuy_count<(select rebuy_limit from game_private.poker_settings where lobby_id=p_id)))<2 then
  update game_private.lobbies set status='finished',closed_at=coalesce(closed_at,now()) where id=p_id and status<>'closed';
 end if;
 perform game_private.sync_summary(p_id);
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_settings_view (
  p_id uuid
)
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
 select jsonb_build_object('starting_chips',starting_chips,'small_blind',big_blind/2,'big_blind',big_blind,'turn_seconds',turn_seconds,'rebuy_limit',rebuy_limit,'locked',true) from game_private.poker_settings where lobby_id=p_id;
$function$;

CREATE OR REPLACE FUNCTION game_private.poker_settle (
  p_id       uuid,
  p_showdown boolean
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare t game_private.poker_tables;level bigint;previous bigint:=0;amount bigint;n integer;eligible integer[];winners integer[];best bigint;share bigint;odd integer;seat_no integer;v_pots jsonb:='[]';result jsonb;survivor smallint;bot record;
begin
 select * into t from game_private.poker_tables where lobby_id=p_id for update;
 if t.street='complete' then return;end if;
 if p_showdown then
  update game_private.poker_players set rank_score=game_private.poker_score7(hole||t.board) where lobby_id=p_id and in_hand and not folded;
 else select seat into survivor from game_private.poker_players where lobby_id=p_id and in_hand and not folded;end if;
 update game_private.poker_players set payout=0 where lobby_id=p_id;
 for level in select distinct committed from game_private.poker_players where lobby_id=p_id and committed>0 order by committed loop
  select count(*) into n from game_private.poker_players where lobby_id=p_id and committed>=level;
  amount:=(level-previous)*n;previous:=level;
  if n=1 then
   select array_agg(seat::integer) into winners from game_private.poker_players where lobby_id=p_id and committed>=level;
  elsif not p_showdown then winners:=array[survivor::integer];
  else
   select max(rank_score) into best from game_private.poker_players where lobby_id=p_id and committed>=level and in_hand and not folded;
   select array_agg(seat::integer order by (seat-t.dealer+5)%6) into winners from game_private.poker_players where lobby_id=p_id and committed>=level and in_hand and not folded and rank_score=best;
  end if;
  if cardinality(winners) is null then raise exception 'No eligible pot winner';end if;
  share:=amount/cardinality(winners);odd:=(amount%cardinality(winners))::integer;
  for seat_no in select unnest(winners) loop
   update game_private.poker_players set stack=stack+share+case when odd>0 then 1 else 0 end,payout=payout+share+case when odd>0 then 1 else 0 end where lobby_id=p_id and seat=seat_no;
   odd:=odd-1;
  end loop;
  v_pots:=v_pots||jsonb_build_array(jsonb_build_object('amount',amount,'winners',winners,'kind',case when n=1 then 'return' else 'pot' end));
 end loop;
 select jsonb_build_object('hand_id',t.hand_id,'hand_no',t.hand_no,'board',t.board,'showdown',p_showdown,'pots',v_pots,
  'players',(select jsonb_agg(jsonb_build_object('seat',seat,'user_id',user_id,'name',display_name,'committed',committed,'payout',payout,'stack',stack,'folded',folded,
   'cards',case when p_showdown and in_hand and not folded then to_jsonb(hole) else 'null'::jsonb end) order by seat) from game_private.poker_players where lobby_id=p_id)) into result;
 insert into game_private.poker_hands values(t.hand_id,p_id,t.hand_no,result,now());
 update game_private.poker_players set committed=0,street_bet=0 where lobby_id=p_id;
 update game_private.poker_tables set street='complete',turn_seat=null,deadline=null,pots=v_pots,showdown=p_showdown,revision=revision+1,last_action=case when p_showdown then 'Showdown.' else 'Hand won without showdown.' end where lobby_id=p_id;
 if exists(select 1 from game_private.poker_players where lobby_id=p_id and not is_bot and not departed) then
  for bot in select user_id from game_private.poker_players where lobby_id=p_id and is_bot and not departed and stack=0 and rebuy_count<(select rebuy_limit from game_private.poker_settings where lobby_id=p_id) loop
   perform game_private.poker_rebuy(p_id,bot.user_id);
  end loop;
 end if;
 if (select count(*) from game_private.poker_players where lobby_id=p_id and not departed and (stack>0 or rebuy_count<(select rebuy_limit from game_private.poker_settings where lobby_id=p_id)))<2 then
  update game_private.lobbies set status='finished',closed_at=now() where id=p_id;
  perform game_private.sync_summary(p_id);
 end if;
 perform game_private.poker_assert(p_id);
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_start (
  p_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare n integer;chips integer;
begin
 if exists(select 1 from game_private.poker_tables where lobby_id=p_id) then return;end if;
 select (select count(*) from game_private.memberships where lobby_id=p_id)+(select count(*) from game_private.room_bots where lobby_id=p_id) into n;
 if n<2 or n>6 or exists(select 1 from game_private.memberships m where m.lobby_id=p_id and not exists(select 1 from game_private.connections c where c.lobby_id=p_id and c.user_id=m.user_id and c.expires_at>now())) then raise exception 'Two to six connected players are required.';end if;
 insert into game_private.poker_tables(lobby_id,minted) values(p_id,n*(select starting_chips from game_private.poker_settings where lobby_id=p_id));
 insert into game_private.poker_players(lobby_id,user_id,seat,display_name,is_bot) select lobby_id,user_id,seat,display_name,false from game_private.memberships where lobby_id=p_id union all select lobby_id,user_id,seat,display_name,true from game_private.room_bots where lobby_id=p_id;
 update game_private.poker_players set stack=(select starting_chips from game_private.poker_settings where lobby_id=p_id) where lobby_id=p_id;
 perform game_private.poker_new_hand(p_id);
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_view (
  p_id    uuid,
  p_actor uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
declare t game_private.poker_tables;p game_private.poker_players;raise_ok boolean;to_call bigint;
begin
 select * into t from game_private.poker_tables where lobby_id=p_id;
 if not found then return null;end if;
 select * into p from game_private.poker_players where lobby_id=p_id and user_id=p_actor;
 to_call:=greatest(t.current_bet-coalesce(p.street_bet,0),0);
 raise_ok:=not coalesce(p.acted,true) or t.current_bet-p.last_bet>=p.last_raise;
 raise_ok:=coalesce(raise_ok,false) and (select count(*) from game_private.poker_players where lobby_id=p_id and in_hand and not folded and not departed and stack>0)>1;
 return jsonb_build_object('hand_id',t.hand_id,'hand_no',t.hand_no,'revision',t.revision,'street',t.street,'board',t.board,'dealer',t.dealer,'small_blind',t.small_blind,'big_blind',t.big_blind,
 'turn_seat',t.turn_seat,'deadline',t.deadline,'server_time',now(),'current_bet',t.current_bet,'min_raise_to',t.current_bet+t.min_raise,'pot',(select sum(committed) from game_private.poker_players where lobby_id=p_id),
 'last_action',t.last_action,'pots',t.pots,'showdown',t.showdown,'starting_chips',(select starting_chips from game_private.poker_settings where lobby_id=p_id),'settings',game_private.poker_settings_view(p_id),'blinds',(select jsonb_build_array(big_blind/2,big_blind) from game_private.poker_settings where lobby_id=p_id),
 'players',(select jsonb_agg(jsonb_build_object('user_id',user_id,'seat',seat,'name',display_name,'is_bot',is_bot,'rebuy_count',rebuy_count,'stack',stack,'bet',street_bet,'committed',committed,'folded',folded,'in_hand',in_hand,'departed',departed,'all_in',in_hand and not folded and stack=0,'payout',payout,
 'hand_rank',case when t.showdown and in_hand and not folded then (array['High card','Pair','Two pair','Three of a kind','Straight','Flush','Full house','Four of a kind','Straight flush'])[(rank_score/759375)::integer+1] else null end,
 'cards',case when user_id=p_actor or (t.showdown and in_hand and not folded) then to_jsonb(hole) else 'null'::jsonb end) order by seat) from game_private.poker_players where lobby_id=p_id),
 'actions',jsonb_build_object('can_rebuy',t.street='complete' and not p.departed and p.stack=0 and p.rebuy_count<(select rebuy_limit from game_private.poker_settings where lobby_id=p_id),'can_act',t.street<>'complete' and t.turn_seat=p.seat and not p.departed and not p.folded and p.stack>0,'to_call',least(p.stack,to_call),'can_check',to_call=0,
 'can_raise',raise_ok and p.stack>to_call,'max_raise_to',p.stack+p.street_bet,'can_all_in',p.stack<=to_call or raise_ok));
end;$function$;

CREATE OR REPLACE FUNCTION game_private.room_snapshot (
  p_id uuid
)
  RETURNS jsonb
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
 select game_private.room_snapshot_base(p_id)||case when (select game_id from game_private.lobbies where id=p_id)='poker' then
 jsonb_build_object('settings',game_private.poker_settings_view(p_id),'poker',game_private.poker_view(p_id,auth.uid()),'members',
  (game_private.room_snapshot_base(p_id)->'members')||coalesce((select jsonb_agg(jsonb_build_object('user_id',user_id,'display_name',display_name,'seat',seat,'mark',null,'rematch',false,'connected',true,'is_bot',true) order by seat) from game_private.room_bots where lobby_id=p_id),'[]'::jsonb))
 else '{}'::jsonb end;
$function$;

CREATE OR REPLACE FUNCTION public.create_poker_room (
  p_capacity   integer DEFAULT 6,
  p_visibility text    DEFAULT 'public'::text,
  p_settings   jsonb   DEFAULT '{}'::jsonb,
  p_connection uuid    DEFAULT NULL::uuid
)
  RETURNS uuid
  LANGUAGE sql
  SET search_path TO ''
  AS $function$select game_private.create_poker_room_api(p_capacity,p_visibility,p_settings,p_connection);$function$;

REVOKE ALL ON FUNCTION "public"."create_poker_room"(integer, text, jsonb, uuid) FROM PUBLIC, "anon";

CREATE OR REPLACE FUNCTION public.poker_action (
  p_lobby    uuid,
  p_action   text,
  p_hand     uuid    DEFAULT NULL::uuid,
  p_revision integer DEFAULT NULL::integer,
  p_amount   bigint  DEFAULT NULL::bigint
)
  RETURNS jsonb
  LANGUAGE sql
  SET search_path TO ''
  AS $function$select game_private.poker_legacy_api(p_lobby,p_action,p_hand,p_revision,p_amount);$function$;

CREATE OR REPLACE FUNCTION public.poker_table_action (
  p_lobby    uuid,
  p_action   text,
  p_hand     uuid    DEFAULT NULL::uuid,
  p_revision integer DEFAULT NULL::integer,
  p_amount   bigint  DEFAULT NULL::bigint
)
  RETURNS jsonb
  LANGUAGE sql
  SET search_path TO ''
  AS $function$select game_private.poker_api(p_lobby,p_action,p_hand,p_revision,p_amount);$function$;

REVOKE ALL ON FUNCTION "public"."poker_table_action"(uuid, text, uuid, integer, bigint) FROM PUBLIC, "anon";

ALTER TABLE "game_private"."poker_players"
  ADD CONSTRAINT "poker_players_rebuy_count_check" CHECK (((rebuy_count >= 0) AND (rebuy_count <= 3)));

ALTER TABLE "game_private"."poker_rebuys"
  ADD CONSTRAINT "poker_rebuys_lobby_id_user_id_fkey" FOREIGN KEY (lobby_id, user_id) REFERENCES game_private.poker_players(lobby_id, user_id) ON DELETE CASCADE;

ALTER TABLE "game_private"."poker_settings"
  ADD CONSTRAINT "poker_settings_lobby_id_fkey" FOREIGN KEY (lobby_id) REFERENCES game_private.lobbies(id) ON DELETE CASCADE;

ALTER TABLE "game_private"."poker_tables"
  ADD CONSTRAINT "poker_tables_min_raise_check" CHECK ((min_raise >= 10));

ALTER TABLE "game_private"."poker_tables"
  ADD CONSTRAINT "poker_tables_minted_check" CHECK (((minted >= 200) AND (minted <= 240000)));

CREATE TRIGGER poker_default_settings
  AFTER INSERT ON game_private.lobbies
  FOR EACH ROW
  EXECUTE FUNCTION game_private.poker_default_settings();

REVOKE ALL ON FUNCTION "game_private"."create_poker_room_api"(integer, text, jsonb, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "game_private"."create_poker_room_api"(integer, text, jsonb, uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "game_private"."poker_default_settings"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_legacy_api"(uuid, text, uuid, integer, bigint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "game_private"."poker_legacy_api"(uuid, text, uuid, integer, bigint) TO "authenticated";

REVOKE ALL ON FUNCTION "game_private"."poker_rebuy"(uuid, uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_settings_view"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."create_poker_room"(integer, text, jsonb, uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."create_poker_room"(integer, text, jsonb, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."create_poker_room"(integer, text, jsonb, uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."create_poker_room"(integer, text, jsonb, uuid) TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."poker_table_action"(uuid, text, uuid, integer, bigint) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."poker_table_action"(uuid, text, uuid, integer, bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."poker_table_action"(uuid, text, uuid, integer, bigint) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."poker_table_action"(uuid, text, uuid, integer, bigint) TO "service_role";


REVOKE ALL ON game_private.poker_settings, game_private.poker_rebuys FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_default_settings() FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_rebuy(uuid, uuid) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_settings_view(uuid) FROM anon, authenticated;

-- Preserve the rules of every pre-settings room, including active mixed tables.
INSERT INTO game_private.poker_settings(lobby_id) SELECT id FROM game_private.lobbies WHERE game_id='poker' ON CONFLICT(lobby_id) DO NOTHING;
NOTIFY pgrst,'reload schema';
COMMIT;
