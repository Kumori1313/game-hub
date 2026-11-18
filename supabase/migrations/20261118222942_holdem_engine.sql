-- Generated from the locally tested schema; catalog activation is deployed separately.
BEGIN;
SET local check_function_bodies = off;

CREATE TABLE "game_private"."poker_hands" (
  "id"          uuid                     NOT NULL,
  "lobby_id"    uuid                     NOT NULL,
  "hand_no"     integer                  NOT NULL,
  "result"      jsonb                    NOT NULL,
  "finished_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "poker_hands_lobby_id_hand_no_key" UNIQUE (lobby_id, hand_no),
  CONSTRAINT "poker_hands_pkey" PRIMARY KEY (id)
);

ALTER TABLE "game_private"."poker_hands"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "game_private"."poker_players" (
  "lobby_id"     uuid       NOT NULL,
  "user_id"      uuid       NOT NULL,
  "seat"         smallint   NOT NULL,
  "display_name" text       NOT NULL,
  "stack"        bigint     NOT NULL DEFAULT 1000,
  "street_bet"   bigint     NOT NULL DEFAULT 0,
  "committed"    bigint     NOT NULL DEFAULT 0,
  "hole"         smallint[] NOT NULL DEFAULT '{}'::smallint[],
  "in_hand"      boolean    NOT NULL DEFAULT false,
  "folded"       boolean    NOT NULL DEFAULT false,
  "departed"     boolean    NOT NULL DEFAULT false,
  "acted"        boolean    NOT NULL DEFAULT false,
  "last_bet"     bigint     NOT NULL DEFAULT 0,
  "last_raise"   bigint     NOT NULL DEFAULT 20,
  "payout"       bigint     NOT NULL DEFAULT 0,
  "rank_score"   bigint,
  CONSTRAINT "poker_players_check" CHECK ((committed >= street_bet)),
  CONSTRAINT "poker_players_lobby_id_seat_key" UNIQUE (lobby_id, seat),
  CONSTRAINT "poker_players_payout_check" CHECK ((payout >= 0)),
  CONSTRAINT "poker_players_pkey" PRIMARY KEY (lobby_id, user_id),
  CONSTRAINT "poker_players_seat_check" CHECK (((seat >= 1) AND (seat <= 6))),
  CONSTRAINT "poker_players_stack_check" CHECK ((stack >= 0)),
  CONSTRAINT "poker_players_street_bet_check" CHECK ((street_bet >= 0))
);

ALTER TABLE "game_private"."poker_players"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "game_private"."poker_tables" (
  "lobby_id"    uuid                     NOT NULL,
  "hand_id"     uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "hand_no"     integer                  NOT NULL DEFAULT 0,
  "dealer"      smallint,
  "small_blind" smallint,
  "big_blind"   smallint,
  "turn_seat"   smallint,
  "street"      text                     NOT NULL DEFAULT 'complete'::text,
  "board"       smallint[]               NOT NULL DEFAULT '{}'::smallint[],
  "deck"        smallint[]               NOT NULL DEFAULT '{}'::smallint[],
  "cursor"      integer                  NOT NULL DEFAULT 1,
  "current_bet" bigint                   NOT NULL DEFAULT 0,
  "min_raise"   bigint                   NOT NULL DEFAULT 20,
  "revision"    integer                  NOT NULL DEFAULT 0,
  "deadline"    timestamp with time zone,
  "minted"      bigint                   NOT NULL,
  "pots"        jsonb                    NOT NULL DEFAULT '[]'::jsonb,
  "last_action" text                     NOT NULL DEFAULT ''::text,
  "showdown"    boolean                  NOT NULL DEFAULT false,
  CONSTRAINT "poker_tables_current_bet_check" CHECK ((current_bet >= 0)),
  CONSTRAINT "poker_tables_hand_no_check" CHECK ((hand_no >= 0)),
  CONSTRAINT "poker_tables_min_raise_check" CHECK ((min_raise >= 20)),
  CONSTRAINT "poker_tables_minted_check" CHECK (((minted >= 2000) AND (minted <= 6000))),
  CONSTRAINT "poker_tables_pkey" PRIMARY KEY (lobby_id),
  CONSTRAINT "poker_tables_revision_check" CHECK ((revision >= 0)),
  CONSTRAINT "poker_tables_street_check" CHECK ((street = ANY (ARRAY['preflop'::text, 'flop'::text, 'turn'::text, 'river'::text, 'complete'::text])))
);

ALTER TABLE "game_private"."poker_tables"
  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION game_private.poker_advance (
  p_id    uuid,
  p_after integer
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare t game_private.poker_tables;live integer;funded integer;next_seat smallint;other_bet bigint;guard integer;draw_count integer;next_street text;
begin
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
   update game_private.poker_tables set turn_seat=next_seat,deadline=clock_timestamp()+interval '30 seconds' where lobby_id=p_id;return;
  end if;
  if t.street='river' then perform game_private.poker_settle(p_id,true);return;end if;
  next_street:=case t.street when 'preflop' then 'flop' when 'flop' then 'turn' else 'river' end;
  draw_count:=case when next_street='flop' then 3 else 1 end;
  -- Burn one unseen card, then expose only the cards for the next street.
  update game_private.poker_tables set street=next_street,board=board||deck[(cursor+1):(cursor+draw_count)],cursor=cursor+draw_count+1,current_bet=0,min_raise=20 where lobby_id=p_id;
  update game_private.poker_players set street_bet=0,acted=false,last_bet=0,last_raise=20 where lobby_id=p_id;
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
 if p_action is null or p_action not in ('start','fold','check','call','raise_to','all_in','next') then raise exception 'Unknown poker action.' using errcode='22023';end if;
 if p_action<>'start' and (p_hand is null or p_revision is null or p_revision<0 or (p_action='raise_to' and (p_amount is null or p_amount<1 or p_amount>6000)) or (p_action<>'raise_to' and p_amount is not null)) then raise exception 'Invalid poker input.' using errcode='22023';end if;
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
 if p_action='next' then
  if l.host_id<>actor then raise exception 'Only the host can deal the next hand.' using errcode='42501';end if;
  if l.status<>'playing' then raise exception 'This table has finished.';end if;
  if not (select playable from public.game_catalog where id='poker') then raise exception 'New hands are not available.';end if;
  perform game_private.poker_new_hand(p_lobby);return game_private.room_snapshot(p_lobby);
 end if;
 if t.street='complete' then raise exception 'This hand is complete.';end if;
 select * into p from game_private.poker_players where lobby_id=p_lobby and user_id=actor;
 if p.departed or p.folded or not p.in_hand or p.stack<=0 or p.seat<>t.turn_seat then raise exception 'It is not your turn.' using errcode='42501';end if;
 if p_action='fold' then update game_private.poker_players set folded=true,acted=true where lobby_id=p_lobby and user_id=actor;
 else
  if p_action='check' then
   if p.street_bet<t.current_bet then raise exception 'Call or fold when facing a bet.';end if;target:=p.street_bet;
  elsif p_action='call' then target:=least(p.street_bet+p.stack,t.current_bet);
  elsif p_action='all_in' then target:=p.street_bet+p.stack;
  else target:=p_amount;end if;
  if target<p.street_bet or target>p.street_bet+p.stack then raise exception 'That amount exceeds your chips.';end if;
  if target>t.current_bet then
   raise_ok:=(not p.acted or t.current_bet-p.last_bet>=p.last_raise) and (select count(*) from game_private.poker_players where lobby_id=p_lobby and in_hand and not folded and not departed and stack>0)>1;
   if not raise_ok then raise exception 'Betting has not reopened for a raise.';end if;
   full_raise:=target-t.current_bet>=t.min_raise;
   if not full_raise and target<>p.street_bet+p.stack then raise exception 'Raise to at least %.',t.current_bet+t.min_raise;end if;
   if full_raise then
    update game_private.poker_players set acted=false where lobby_id=p_lobby and user_id<>actor;
    update game_private.poker_tables set min_raise=target-t.current_bet where lobby_id=p_lobby;
   end if;
   update game_private.poker_tables set current_bet=target where lobby_id=p_lobby;
  elsif p_action='raise_to' then raise exception 'A raise must increase the current bet.';end if;
  paid:=target-p.street_bet;
  update game_private.poker_players set stack=stack-paid,committed=committed+paid,street_bet=target,acted=true,last_bet=greatest(t.current_bet,target),last_raise=(select min_raise from game_private.poker_tables where lobby_id=p_lobby) where lobby_id=p_lobby and user_id=actor;
 end if;
 update game_private.poker_tables set revision=revision+1,last_action='Seat '||p.seat||': '||replace(p_action,'_',' ')||case when target is not null then ' ('||target||')' else '' end||'.' where lobby_id=p_lobby;
 perform game_private.poker_advance(p_lobby,p.seat);perform game_private.poker_assert(p_lobby);
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
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_depart (
  p_id   uuid,
  p_user uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare t game_private.poker_tables;p game_private.poker_players;
begin
 select * into t from game_private.poker_tables where lobby_id=p_id for update;
 if not found then return;end if;
 select * into p from game_private.poker_players where lobby_id=p_id and user_id=p_user;
 if not found or p.departed then return;end if;
 -- All-in chips and cards remain eligible even if their owner departs.
 update game_private.poker_players set departed=true,folded=case when t.street<>'complete' and stack>0 then true else folded end where lobby_id=p_id and user_id=p_user;
 if t.street<>'complete' then
  if t.turn_seat=p.seat or p.stack>0 then
   update game_private.poker_tables set revision=revision+1,last_action='A player left the table.' where lobby_id=p_id;
   perform game_private.poker_advance(p_id,case when t.turn_seat=p.seat then p.seat else coalesce(t.turn_seat,1)-1 end);
  end if;
 end if;
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_new_hand (
  p_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare t game_private.poker_tables;seats smallint[];v_deck smallint[];n integer;i integer;j integer;tmp smallint;button smallint;sb smallint;bb smallint;position integer:=1;seat_no smallint;round_no integer;paid bigint;
begin
 select * into t from game_private.poker_tables where lobby_id=p_id for update;
 if t.street<>'complete' then raise exception 'This hand is still in progress.';end if;
 select array_agg(p.seat order by p.seat) into seats from game_private.poker_players p where p.lobby_id=p_id and not p.departed and p.stack>0
  and exists(select 1 from game_private.memberships m where m.lobby_id=p_id and m.user_id=p.user_id)
  and exists(select 1 from game_private.connections c where c.lobby_id=p_id and c.user_id=p.user_id and c.expires_at>now());
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
 update game_private.poker_players set hole='{}',in_hand=seat=any(seats),folded=false,acted=false,last_bet=0,last_raise=20,street_bet=0,committed=0,payout=0,rank_score=null where lobby_id=p_id;
 for round_no in 1..2 loop
  for seat_no in select s from unnest(seats)s order by (s-button+5)%6 loop
   update game_private.poker_players set hole=array_append(hole,v_deck[position]) where lobby_id=p_id and seat=seat_no;position:=position+1;
  end loop;
 end loop;
 update game_private.poker_tables set hand_id=gen_random_uuid(),hand_no=hand_no+1,dealer=button,small_blind=sb,big_blind=bb,turn_seat=null,
  street='preflop',board='{}',deck=v_deck,cursor=position,current_bet=20,min_raise=20,revision=0,deadline=null,pots='[]',showdown=false,last_action='Blinds 10/20.' where lobby_id=p_id;
 for seat_no in select unnest(array[sb,bb]) loop
  select least(stack,case when seat_no=sb then 10 else 20 end) into paid from game_private.poker_players where lobby_id=p_id and seat=seat_no;
  update game_private.poker_players set stack=stack-paid,street_bet=paid,committed=paid where lobby_id=p_id and seat=seat_no;
 end loop;
 update game_private.lobbies set round=t.hand_no+1,status='playing',closed_at=null,reason=null where id=p_id;
 perform game_private.poker_advance(p_id,bb);
 perform game_private.sync_summary(p_id);perform game_private.poker_assert(p_id);
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_random (
  p_bound integer
)
  RETURNS integer
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare n integer;
begin
 if p_bound<1 or p_bound>52 then raise exception 'Invalid random bound'; end if;
 loop n:=get_byte(extensions.gen_random_bytes(1),0); exit when n<256-(256%p_bound); end loop;
 return n%p_bound;
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
  and (select count(*) from game_private.poker_players where lobby_id=p_id and not departed and stack>0)<2 then
  update game_private.lobbies set status='finished',closed_at=coalesce(closed_at,now()) where id=p_id and status<>'closed';
 end if;
 perform game_private.sync_summary(p_id);
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_score5 (
  p_cards smallint[]
)
  RETURNS bigint
  LANGUAGE plpgsql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
declare ranks integer[]; groups integer[]; counts integer[]; kick integer[]; category integer:=0; straight integer:=0; flush boolean; score bigint; n integer;
begin
 if cardinality(p_cards)<>5 or exists(select 1 from unnest(p_cards)c where c<0 or c>51) or (select count(distinct c) from unnest(p_cards)c)<>5 then raise exception 'Invalid five-card hand'; end if;
 select array_agg(r order by r desc) into ranks from (select (c%13+2)::integer r from unnest(p_cards)c)s;
 select array_agg(r order by cnt desc,r desc),array_agg(cnt order by cnt desc,r desc) into groups,counts from (select r,count(*)::integer cnt from unnest(ranks)r group by r)s;
 flush:=(select count(distinct c/13)=1 from unnest(p_cards)c);
 if cardinality(groups)=5 then
  if ranks[1]-ranks[5]=4 then straight:=ranks[1]; elsif ranks=array[14,5,4,3,2] then straight:=5; end if;
 end if;
 if flush and straight>0 then category:=8;kick:=array[straight];
 elsif counts[1]=4 then category:=7;kick:=groups;
 elsif counts[1]=3 and counts[2]=2 then category:=6;kick:=groups;
 elsif flush then category:=5;kick:=ranks;
 elsif straight>0 then category:=4;kick:=array[straight];
 elsif counts[1]=3 then category:=3;kick:=groups;
 elsif counts[1]=2 and counts[2]=2 then category:=2;kick:=groups;
 elsif counts[1]=2 then category:=1;kick:=groups;
 else kick:=ranks;end if;
 score:=category;
 for n in 1..5 loop score:=score*15+coalesce(kick[n],0);end loop;
 return score;
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_score7 (
  p_cards smallint[]
)
  RETURNS bigint
  LANGUAGE plpgsql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
declare a integer;b integer;c integer;d integer;e integer;best bigint:=0;
begin
 if cardinality(p_cards)<>7 or (select count(distinct x) from unnest(p_cards)x)<>7 then raise exception 'Invalid seven-card hand';end if;
 for a in 1..3 loop for b in a+1..4 loop for c in b+1..5 loop for d in c+1..6 loop for e in d+1..7 loop
  best:=greatest(best,game_private.poker_score5(array[p_cards[a],p_cards[b],p_cards[c],p_cards[d],p_cards[e]]));
 end loop;end loop;end loop;end loop;end loop;
 return best;
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_settle (
  p_id       uuid,
  p_showdown boolean
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare t game_private.poker_tables;level bigint;previous bigint:=0;amount bigint;n integer;eligible integer[];winners integer[];best bigint;share bigint;odd integer;seat_no integer;v_pots jsonb:='[]';result jsonb;survivor smallint;
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
 if (select count(*) from game_private.poker_players where lobby_id=p_id and not departed and stack>0)<2 then
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
declare n integer;
begin
 if exists(select 1 from game_private.poker_tables where lobby_id=p_id) then return;end if;
 select count(*) into n from game_private.memberships where lobby_id=p_id;
 if n<2 or n>6 or exists(select 1 from game_private.memberships m where m.lobby_id=p_id and not exists(select 1 from game_private.connections c where c.lobby_id=p_id and c.user_id=m.user_id and c.expires_at>now())) then raise exception 'Two to six connected players are required.';end if;
 insert into game_private.poker_tables(lobby_id,minted) values(p_id,n*1000);
 insert into game_private.poker_players(lobby_id,user_id,seat,display_name) select lobby_id,user_id,seat,display_name from game_private.memberships where lobby_id=p_id;
 perform game_private.poker_new_hand(p_id);
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_tick (
  p_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare t game_private.poker_tables;gone record;p game_private.poker_players;
begin
 select * into t from game_private.poker_tables where lobby_id=p_id for update;
 if not found then return;end if;
 delete from game_private.connections where lobby_id=p_id and expires_at<=now();
 for gone in select m.user_id from game_private.memberships m where m.lobby_id=p_id and not exists(select 1 from game_private.connections c where c.lobby_id=p_id and c.user_id=m.user_id) order by m.seat loop
  perform game_private.poker_depart(p_id,gone.user_id);
  delete from game_private.memberships where lobby_id=p_id and user_id=gone.user_id;
 end loop;
 perform game_private.poker_rehost(p_id);
 select * into t from game_private.poker_tables where lobby_id=p_id;
 if t.street<>'complete' and t.deadline<=clock_timestamp() then
  select * into p from game_private.poker_players where lobby_id=p_id and seat=t.turn_seat;
  update game_private.poker_players set folded=street_bet<t.current_bet,acted=true,last_bet=t.current_bet,last_raise=t.min_raise where lobby_id=p_id and user_id=p.user_id;
  update game_private.poker_tables set revision=revision+1,last_action=case when p.street_bet<t.current_bet then 'Turn timed out: fold.' else 'Turn timed out: check.' end where lobby_id=p_id;
  perform game_private.poker_advance(p_id,p.seat);
 end if;
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
 'last_action',t.last_action,'pots',t.pots,'showdown',t.showdown,'starting_chips',1000,'blinds',jsonb_build_array(10,20),
 'players',(select jsonb_agg(jsonb_build_object('user_id',user_id,'seat',seat,'name',display_name,'stack',stack,'bet',street_bet,'committed',committed,'folded',folded,'in_hand',in_hand,'departed',departed,'all_in',in_hand and not folded and stack=0,'payout',payout,
 'hand_rank',case when t.showdown and in_hand and not folded then (array['High card','Pair','Two pair','Three of a kind','Straight','Flush','Full house','Four of a kind','Straight flush'])[(rank_score/759375)::integer+1] else null end,
 'cards',case when user_id=p_actor or (t.showdown and in_hand and not folded) then to_jsonb(hole) else 'null'::jsonb end) order by seat) from game_private.poker_players where lobby_id=p_id),
 'actions',jsonb_build_object('can_act',t.street<>'complete' and t.turn_seat=p.seat and not p.departed and not p.folded and p.stack>0,'to_call',least(p.stack,to_call),'can_check',to_call=0,
 'can_raise',raise_ok and p.stack>to_call,'max_raise_to',p.stack+p.street_bet,'can_all_in',p.stack<=to_call or raise_ok));
end;$function$;

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
 if room.game_id='poker' and exists(select 1 from game_private.poker_tables where lobby_id=p_id) then
  perform game_private.poker_tick(p_id);perform game_private.sync_summary(p_id);return;
 end if;
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
  if p_game='poker' and exists(select 1 from game_private.poker_tables where lobby_id=p_lobby) then
   perform game_private.poker_depart(p_lobby,actor);
   delete from game_private.memberships where lobby_id=p_lobby and user_id=actor;
   perform game_private.poker_rehost(p_lobby);perform game_private.sync_summary(p_lobby);return null;
  end if;
  if room.status in ('waiting','playing') then
   if room.host_id=actor then perform game_private.close_lobby(p_lobby,'The host left.');
   elsif room.status='playing' then perform game_private.close_lobby(p_lobby,'A player left. The match was interrupted.'); end if;
  end if;
  delete from game_private.memberships where lobby_id=p_lobby and user_id=actor;
  perform game_private.sync_summary(p_lobby); return null;
 elsif p_action='start' then
  if room.host_id<>actor then raise exception 'Only the host can start.' using errcode='42501'; end if;
  if p_game='poker' then raise exception 'Refresh this page to play poker.';end if;
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
 select game_private.room_snapshot_base(p_id)||case when (select game_id from game_private.lobbies where id=p_id)='poker'
 then jsonb_build_object('poker',game_private.poker_view(p_id,auth.uid())) else '{}'::jsonb end;
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
 'match',(select jsonb_build_object('id',a.id,'status',a.status,'board',a.board,'current_turn',a.current_turn,'reason',a.reason,
 'revision',a.revision,'winner',a.winner,'winning_line',a.winning_line,'round',a.round) from game_private.matches a where a.lobby_id=l.id and a.round=l.round))
 from game_private.lobbies l join public.game_catalog g on g.id=l.game_id where l.id=p_id;
$function$;

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
  AS $function$select game_private.poker_api(p_lobby,p_action,p_hand,p_revision,p_amount);$function$;

REVOKE ALL ON FUNCTION "public"."poker_action"(uuid, text, uuid, integer, bigint) FROM PUBLIC, "anon";

ALTER TABLE "game_private"."poker_players"
  ADD CONSTRAINT "poker_players_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id);

ALTER TABLE "game_private"."poker_tables"
  ADD CONSTRAINT "poker_tables_lobby_id_fkey" FOREIGN KEY (lobby_id) REFERENCES game_private.lobbies(id) ON DELETE CASCADE;

ALTER TABLE "game_private"."poker_hands"
  ADD CONSTRAINT "poker_hands_lobby_id_fkey" FOREIGN KEY (lobby_id) REFERENCES game_private.poker_tables(lobby_id) ON DELETE CASCADE;

ALTER TABLE "game_private"."poker_players"
  ADD CONSTRAINT "poker_players_lobby_id_fkey" FOREIGN KEY (lobby_id) REFERENCES game_private.poker_tables(lobby_id) ON DELETE CASCADE;

CREATE INDEX poker_players_user_idx ON game_private.poker_players USING btree (user_id);

REVOKE ALL ON FUNCTION "game_private"."poker_advance"(uuid, integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_api"(uuid, text, uuid, integer, bigint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "game_private"."poker_api"(uuid, text, uuid, integer, bigint) TO "authenticated";

REVOKE ALL ON FUNCTION "game_private"."poker_assert"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_depart"(uuid, uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_new_hand"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_random"(integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_rehost"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_score5"(smallint[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_score7"(smallint[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_settle"(uuid, boolean) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_start"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_tick"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_view"(uuid, uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."room_snapshot_base"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."poker_action"(uuid, text, uuid, integer, bigint) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."poker_action"(uuid, text, uuid, integer, bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."poker_action"(uuid, text, uuid, integer, bigint) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."poker_action"(uuid, text, uuid, integer, bigint) TO "service_role";


REVOKE ALL ON game_private.poker_tables, game_private.poker_players, game_private.poker_hands FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_advance(uuid, integer) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_assert(uuid) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_depart(uuid, uuid) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_new_hand(uuid) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_random(integer) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_rehost(uuid) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_score5(smallint[]) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_score7(smallint[]) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_settle(uuid, boolean) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_start(uuid) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_tick(uuid) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_view(uuid, uuid) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.room_snapshot_base(uuid) FROM anon, authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
