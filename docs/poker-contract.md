# Hold’em contract

Poker uses play-money chips only, with 2–6 seats. Defaults are 1,000 chips each, 10/20 blinds, a 30-second turn clock, and no rebuys. Hosts configure rules before creating a lobby; the agreed rules then lock for that room. No late seats are accepted. The host deals subsequent hands; a table finishes when fewer than two remaining players have chips or an available rebuy.

## Rules and accounting

The server shuffles 52 distinct cards with cryptographic rejection sampling and Fisher–Yates, deals two private cards per seat, burns before each community street, and evaluates the best five of seven cards. The first button is random and moves clockwise between hands. Heads-up, the button posts the small blind and acts first preflop; the big blind acts first postflop. Transitioning to heads-up rotates the big blind from its previous seat.

Raises specify the total street contribution. A short all-in does not reopen a previous actor's betting unless cumulative increases reach the last full raise. Contribution layers form main and side pots; unmatched contributions return to their owner. Tied winners split each pot, with odd chips moving clockwise from the button. Every action and settlement checks that stacks plus committed chips equal the original table total, including departed players' chips. With rebuys enabled, an issuance ledger records each additional starting stack and the table total increases by that exact amount.

These choices follow the [Poker TDA rules](https://www.pokertda.com/view-poker-tda-rules/) for betting, heads-up action, and odd chips. This game uses a moving button rather than tournament dead-button handling.

## Authority and recovery

`poker_table_action` accepts `start`, `next`, `fold`, `check`, `call`, `raise_to`, `all_in`, and `rebuy`. The older `poker_action` endpoint continues to support default-rules tables; custom tables return a refresh message to old clients. Betting and next-hand requests require the exact hand UUID and revision. Room locks serialize competing requests; stale replies require a fresh snapshot, never automatic replay. Starting is host-only and idempotent. Old preview clients receive a refresh message through their original start endpoint.

Only the caller's hole cards appear before showdown. Showdown reveals nonfolded participants; folded cards, the deck, and future community cards stay private. Membership and a live Auth session are required. Table data has no direct browser grants; Presence carries advisory connection identifiers only.

Refresh preserves the seat and cards. Connections renew 90-second leases. Expired turns check when free and fold when facing a bet. Reads/actions enforce deadlines; minute cleanup can delay unattended enforcement by up to a minute. Leaving folds a funded player; an all-in player retains pot eligibility. Host ownership transfers to the lowest remaining seat. Closed/finished records follow the existing seven-day retention policy.

## Validation

Run `npm run test:poker` against local Supabase only. Fixtures cover hand ranks, 2–6-player play, side pots, split/odd chips, chip conservation, short/cumulative raises, concurrent/stale actions, private grants/cards, deadlines, departures, and reconnect leases. Browser scenarios in `tests/browser/poker.spec.js` complete successive hands and exercise three-player betting, recovery, keyboard controls, and narrow screens.

## Bots and mixed tables

The host can use **Add bot** in a waiting lobby and remove an individual bot before starting. A table can have one human with up to five bots, multiple humans with bots, or only humans. Humans and bots share the selected 2–6-seat capacity; a bot reserves its seat in discovery and join validation. Bots cannot be added, removed, or substituted during a started table. Ownership always stays with a human, and the room closes when the last human leaves or loses their connection lease.

Bots are labeled in both the waiting room and the hand view. They use a basic randomized, rule-based strategy based on their own hole cards, dealt community cards, public betting amounts, and remaining chips. The strategy function receives those values explicitly and cannot read the deck or opponents' cards. There is one bot difficulty, with no external AI or paid API. Bots can check, call, fold, and raise through the same legal mutation function used by human players.

Bot turns have a two-second target delay. Server reads/actions and existing cleanup process due turns under the room lock; client polling normally advances them within another second. Background tabs or unattended tables can update more slowly. Browsers cannot submit actions on a bot's behalf. Bots have private seat identifiers without Auth users, sessions, or heartbeat leases; human player references still enforce Auth foreign keys. Chip conservation, all-in eligibility, and payouts apply to every seat.

`poker_bot(p_lobby, p_action, p_seat)` accepts host-only `add` (no seat argument) and `remove` (bot seat required). The private bot registry has no browser grants. Run `npm run test:bots` locally for solo/mixed hands, five-bot tables, capacity races, private cards/grants, human ownership, and chip accounting. Browser coverage is in `tests/browser/bots.spec.js`.

## Configurable tables (8.3)

Expand **Table settings** before creating a lobby. The server accepts only known settings with integer values:

| Setting | Accepted values |
| --- | --- |
| Starting chips | Hundreds from 100–10,000, covering at least 20 big blinds (effective minimum 200) |
| Blinds | 5/10, 10/20, 25/50, 50/100, 100/200, 250/500 |
| Human turn time | 15, 30, 45, 60, or 90 seconds |
| Seats | 2–6 total, including bots |
| Rebuys | None, one, or three per player |

`create_poker_room` atomically validates settings and creates the room using the existing admission, connection, and creation-rate rules. The private settings record and room capacity persist across refreshes and hands. All admitted players see the authoritative rules in the waiting room. There is no settings-edit endpoint: leave and create another lobby to change rules. The browser also saves valid hosting preferences locally; storage failure leaves creation and server-side recovery available.

A rebuy refills a zero-chip stack with the original starting amount, only between completed hands. Humans choose **Rebuy**; eligible bots rebuy automatically at settlement. Every seat has the same configured limit. A rebuy requires the exact hand/revision and only affects the caller's own stack; concurrent duplicate requests issue chips once. Seats with chips cannot top up. Departed players cannot rebuy, and no late joins or active-hand rebuys are allowed.

A table stays open while at least two remaining players are funded or eligible to rebuy. Dealing requires two connected, funded seats. If a player declines an available rebuy, they can leave; there is no automatic human rebuy or forced new hand. Each issuance is recorded in a private ledger. The maximum table supply is 240,000 play chips (six players, 10,000 starting chips, three rebuys each). Normal turn checks, private cards, and chip conservation apply throughout.

Pre-settings rooms receive their original default rules during migration. Run `npm run test:settings` locally for validation, custom clocks/blinds, large bets, voluntary and bot rebuys, concurrent issuance, bounded elimination, and private grants. Browser scenarios in `tests/browser/settings.spec.js` cover shared rules, saved preferences, refresh, mobile validation, blocked preference storage, and the rebuy button.
