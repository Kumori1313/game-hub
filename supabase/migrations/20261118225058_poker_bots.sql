-- Mixed human/bot seats; existing human players retain their Auth foreign key.
BEGIN;
SET local check_function_bodies = off;

DROP INDEX "game_private"."poker_players_user_idx";

ALTER TABLE "game_private"."poker_players"
  DROP CONSTRAINT "poker_players_user_id_fkey";

CREATE TABLE "game_private"."room_bots" (
  "lobby_id"     uuid     NOT NULL,
  "user_id"      uuid     NOT NULL DEFAULT gen_random_uuid(),
  "seat"         smallint NOT NULL,
  "display_name" text     NOT NULL,
  CONSTRAINT "room_bots_lobby_id_seat_key" UNIQUE (lobby_id, seat),
  CONSTRAINT "room_bots_pkey" PRIMARY KEY (lobby_id, user_id),
  CONSTRAINT "room_bots_seat_check" CHECK (((seat >= 1) AND (seat <= 6)))
);

ALTER TABLE "game_private"."room_bots"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "game_private"."poker_players"
  ADD COLUMN "is_bot" boolean NOT NULL DEFAULT false;

ALTER TABLE "game_private"."poker_players"
  ADD COLUMN "human_user_id" uuid GENERATED ALWAYS AS (
CASE
    WHEN is_bot THEN NULL::uuid
    ELSE user_id
END) STORED;

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
   update game_private.poker_tables set turn_seat=next_seat,deadline=clock_timestamp()+case when (select is_bot from game_private.poker_players where lobby_id=p_id and seat=next_seat) then interval '2 seconds' else interval '30 seconds' end where lobby_id=p_id;return;
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
 perform game_private.poker_apply(p_lobby,actor,p_action,p_amount);
 return game_private.room_snapshot(p_lobby);
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_apply (
  p_lobby  uuid,
  p_actor  uuid,
  p_action text,
  p_amount bigint DEFAULT NULL::bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare actor uuid:=p_actor;t game_private.poker_tables;p game_private.poker_players;target bigint;paid bigint;full_raise boolean;raise_ok boolean;
begin
 if p_action not in ('fold','check','call','raise_to','all_in') then raise exception 'Unknown poker action.';end if;
 select * into t from game_private.poker_tables where lobby_id=p_lobby for update;
 if not found then raise exception 'Table not started.';end if;
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
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_bot_api (
  p_lobby  uuid,
  p_action text,
  p_seat   integer DEFAULT NULL::integer
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare actor uuid:=game_private.valid_actor();l game_private.lobbies;free_seat smallint;
begin
 if actor is null then raise exception 'Your session ended. Sign in again.' using errcode='PT401';end if;
 if p_action is null or p_action not in ('add','remove') or (p_action='add' and p_seat is not null) or (p_action='remove' and (p_seat is null or p_seat<1 or p_seat>6)) then raise exception 'Invalid bot input.' using errcode='22023';end if;
 perform game_private.consume_budget(actor);
 select * into l from game_private.lobbies where id=p_lobby for update;
 if not found or l.game_id<>'poker' or l.host_id<>actor or not exists(select 1 from game_private.memberships where lobby_id=p_lobby and user_id=actor) then raise exception 'Only the poker host can manage bots.' using errcode='42501';end if;
 perform game_private.prune_lobby(p_lobby);
 if (select status from game_private.lobbies where id=p_lobby)<>'waiting' or exists(select 1 from game_private.poker_tables where lobby_id=p_lobby) then raise exception 'Bots can only change before the table starts.';end if;
 if p_action='add' then
  select n::smallint into free_seat from generate_series(1,l.capacity)n where not exists(select 1 from game_private.memberships where lobby_id=p_lobby and seat=n) and not exists(select 1 from game_private.room_bots where lobby_id=p_lobby and seat=n) order by n limit 1;
  if free_seat is null then raise exception 'This table is full.';end if;
  insert into game_private.room_bots(lobby_id,seat,display_name) values(p_lobby,free_seat,'Bot '||free_seat);
 else
  delete from game_private.room_bots where lobby_id=p_lobby and seat=p_seat;
  if not found then raise exception 'That seat is not a bot.';end if;
 end if;
 perform game_private.sync_summary(p_lobby);
 return game_private.room_snapshot(p_lobby);
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_bot_choice (
  p_hole    smallint[],
  p_board   smallint[],
  p_call    bigint,
  p_pot     bigint,
  p_stack   bigint,
  p_bet     bigint,
  p_current bigint,
  p_min     bigint,
  p_raise   boolean
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare strength integer;roll integer:=game_private.poker_random(50);category integer;hi integer;lo integer;target bigint;
begin
 if cardinality(p_hole)<>2 then raise exception 'A bot needs its own two cards';end if;
 if cardinality(p_board)=0 then
  hi:=greatest(p_hole[1]%13+2,p_hole[2]%13+2);lo:=least(p_hole[1]%13+2,p_hole[2]%13+2);
  strength:=case when hi=lo then 65+hi*2 else hi*3+lo+case when p_hole[1]/13=p_hole[2]/13 then 7 else 0 end+case when hi-lo=1 then 5 else 0 end end;
 else
  category:=(game_private.poker_visible_score(p_hole||p_board)/759375)::integer;
  strength:=(array[18,50,65,75,82,90,95,98,100])[category+1];
 end if;
 if p_call>0 and ((strength<35 and p_call>20 and roll<35) or (strength<75 and p_call>p_stack*(strength+15)/100 and roll<40)) then
  return jsonb_build_object('action','fold');
 end if;
 if p_raise and p_stack>p_call and strength>=(case when p_call=0 then 65 else 85 end) and roll<15 then
  target:=least(p_bet+p_stack,p_current+greatest(p_min,p_pot/2));
  if target>=p_current+p_min then return jsonb_build_object('action','raise_to','amount',target);end if;
 end if;
 return jsonb_build_object('action',case when p_call=0 then 'check' else 'call' end);
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_bot_turn (
  p_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare t game_private.poker_tables;p game_private.poker_players;choice jsonb;raise_ok boolean;
begin
 select * into t from game_private.poker_tables where lobby_id=p_id for update;
 select * into p from game_private.poker_players where lobby_id=p_id and seat=t.turn_seat;
 if not found or not p.is_bot or t.street='complete' or t.deadline>clock_timestamp() then return;end if;
 raise_ok:=(not p.acted or t.current_bet-p.last_bet>=p.last_raise) and (select count(*) from game_private.poker_players where lobby_id=p_id and in_hand and not folded and not departed and stack>0)>1;
 choice:=game_private.poker_bot_choice(p.hole,t.board,least(p.stack,greatest(0,t.current_bet-p.street_bet)),
  (select sum(committed)::bigint from game_private.poker_players where lobby_id=p_id),p.stack,p.street_bet,t.current_bet,t.min_raise,raise_ok);
 perform game_private.poker_apply(p_id,p.user_id,choice->>'action',(choice->>'amount')::bigint);
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
 select (select count(*) from game_private.memberships where lobby_id=p_id)+(select count(*) from game_private.room_bots where lobby_id=p_id) into n;
 if n<2 or n>6 or exists(select 1 from game_private.memberships m where m.lobby_id=p_id and not exists(select 1 from game_private.connections c where c.lobby_id=p_id and c.user_id=m.user_id and c.expires_at>now())) then raise exception 'Two to six connected players are required.';end if;
 insert into game_private.poker_tables(lobby_id,minted) values(p_id,n*1000);
 insert into game_private.poker_players(lobby_id,user_id,seat,display_name,is_bot) select lobby_id,user_id,seat,display_name,false from game_private.memberships where lobby_id=p_id union all select lobby_id,user_id,seat,display_name,true from game_private.room_bots where lobby_id=p_id;
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
 if not found or (select status from game_private.lobbies where id=p_id) in ('closed','finished') then return;end if;
 delete from game_private.connections where lobby_id=p_id and expires_at<=now();
 for gone in select m.user_id from game_private.memberships m where m.lobby_id=p_id and not exists(select 1 from game_private.connections c where c.lobby_id=p_id and c.user_id=m.user_id) order by m.seat loop
  perform game_private.poker_depart(p_id,gone.user_id);
  delete from game_private.memberships where lobby_id=p_id and user_id=gone.user_id;
 end loop;
 perform game_private.poker_rehost(p_id);
 if not exists(select 1 from game_private.memberships where lobby_id=p_id) then return;end if;
 select * into t from game_private.poker_tables where lobby_id=p_id;
 if t.street<>'complete' and t.deadline<=clock_timestamp() then
  select * into p from game_private.poker_players where lobby_id=p_id and seat=t.turn_seat;
  if p.is_bot then perform game_private.poker_bot_turn(p_id);return;end if;
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
 'players',(select jsonb_agg(jsonb_build_object('user_id',user_id,'seat',seat,'name',display_name,'is_bot',is_bot,'stack',stack,'bet',street_bet,'committed',committed,'folded',folded,'in_hand',in_hand,'departed',departed,'all_in',in_hand and not folded and stack=0,'payout',payout,
 'hand_rank',case when t.showdown and in_hand and not folded then (array['High card','Pair','Two pair','Three of a kind','Straight','Flush','Full house','Four of a kind','Straight flush'])[(rank_score/759375)::integer+1] else null end,
 'cards',case when user_id=p_actor or (t.showdown and in_hand and not folded) then to_jsonb(hole) else 'null'::jsonb end) order by seat) from game_private.poker_players where lobby_id=p_id),
 'actions',jsonb_build_object('can_act',t.street<>'complete' and t.turn_seat=p.seat and not p.departed and not p.folded and p.stack>0,'to_call',least(p.stack,to_call),'can_check',to_call=0,
 'can_raise',raise_ok and p.stack>to_call,'max_raise_to',p.stack+p.street_bet,'can_all_in',p.stack<=to_call or raise_ok));
end;$function$;

CREATE OR REPLACE FUNCTION game_private.poker_visible_score (
  p_cards smallint[]
)
  RETURNS bigint
  LANGUAGE plpgsql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
declare n integer:=cardinality(p_cards);i integer;score bigint:=0;
begin
 if n=5 then return game_private.poker_score5(p_cards);
 elsif n=7 then return game_private.poker_score7(p_cards);
 elsif n=6 then
  for i in 1..6 loop score:=greatest(score,game_private.poker_score5(p_cards[1:i-1]||p_cards[i+1:6]));end loop;
  return score;
 end if;
 raise exception 'Expected five to seven visible cards';
end;$function$;

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
   if room.status<>'waiting' or ((select count(*) from game_private.memberships where lobby_id=p_lobby)+(select count(*) from game_private.room_bots where lobby_id=p_lobby))>=room.capacity then
    if p_action='join_code' then return jsonb_build_object('error','Room not found or unavailable.','code','ROOM_UNAVAILABLE'); end if;
    if room.status<>'waiting' then raise exception 'This lobby is no longer accepting players.'; end if;
    raise exception 'This lobby is full.';
   end if;
   select n::smallint into free_seat from generate_series(1,room.capacity) n where not exists(select 1 from game_private.memberships m where m.lobby_id=p_lobby and m.seat=n) and not exists(select 1 from game_private.room_bots b where b.lobby_id=p_lobby and b.seat=n) order by n limit 1;
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
 select game_private.room_snapshot_base(p_id)||case when (select game_id from game_private.lobbies where id=p_id)='poker' then
 jsonb_build_object('poker',game_private.poker_view(p_id,auth.uid()),'members',
  (game_private.room_snapshot_base(p_id)->'members')||coalesce((select jsonb_agg(jsonb_build_object('user_id',user_id,'display_name',display_name,'seat',seat,'mark',null,'rematch',false,'connected',true,'is_bot',true) order by seat) from game_private.room_bots where lobby_id=p_id),'[]'::jsonb))
 else '{}'::jsonb end;
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
 ((select count(*) from game_private.memberships p where p.lobby_id=l.id)+(select count(*) from game_private.room_bots b where b.lobby_id=l.id))::smallint,l.capacity,l.status,
 coalesce((select max(c.expires_at) from game_private.connections c where c.lobby_id=l.id and c.user_id=l.host_id),'-infinity'),l.created_at
 from game_private.lobbies l left join game_private.memberships m on m.lobby_id=l.id and m.user_id=l.host_id
 where l.id=p_id and l.visibility='public'
 on conflict(id) do update set title=excluded.title,player_count=excluded.player_count,capacity=excluded.capacity,status=excluded.status,host_expires_at=excluded.host_expires_at
 where (lobby_summaries.title,lobby_summaries.player_count,lobby_summaries.capacity,lobby_summaries.status,lobby_summaries.host_expires_at)
 is distinct from(excluded.title,excluded.player_count,excluded.capacity,excluded.status,excluded.host_expires_at);
end;
$function$;

CREATE OR REPLACE FUNCTION public.poker_bot (
  p_lobby  uuid,
  p_action text,
  p_seat   integer DEFAULT NULL::integer
)
  RETURNS jsonb
  LANGUAGE sql
  SET search_path TO ''
  AS $function$select game_private.poker_bot_api(p_lobby,p_action,p_seat);$function$;

REVOKE ALL ON FUNCTION "public"."poker_bot"(uuid, text, integer) FROM PUBLIC, "anon";

ALTER TABLE "game_private"."poker_players"
  ADD CONSTRAINT "poker_players_human_user_id_fkey" FOREIGN KEY (human_user_id) REFERENCES auth.users(id);

ALTER TABLE "game_private"."room_bots"
  ADD CONSTRAINT "room_bots_lobby_id_fkey" FOREIGN KEY (lobby_id) REFERENCES game_private.lobbies(id) ON DELETE CASCADE;

CREATE INDEX poker_players_human_user_idx ON game_private.poker_players USING btree (human_user_id);

REVOKE ALL ON FUNCTION "game_private"."poker_apply"(uuid, uuid, text, bigint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_bot_api"(uuid, text, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "game_private"."poker_bot_api"(uuid, text, integer) TO "authenticated";

REVOKE ALL ON FUNCTION "game_private"."poker_bot_choice"(smallint[], smallint[], bigint, bigint, bigint, bigint, bigint, bigint, boolean) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_bot_turn"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."poker_visible_score"(smallint[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."poker_bot"(uuid, text, integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."poker_bot"(uuid, text, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."poker_bot"(uuid, text, integer) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."poker_bot"(uuid, text, integer) TO "service_role";


REVOKE ALL ON game_private.room_bots FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_apply(uuid, uuid, text, bigint) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_bot_choice(smallint[], smallint[], bigint, bigint, bigint, bigint, bigint, bigint, boolean) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_bot_turn(uuid) FROM anon, authenticated;
REVOKE ALL ON FUNCTION game_private.poker_visible_score(smallint[]) FROM anon, authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
