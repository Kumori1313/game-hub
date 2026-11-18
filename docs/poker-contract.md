# Hold’em contract (milestone 8.2)

Poker uses play-money chips only: 2–6 seats, 1,000 chips each, fixed 10/20 blinds, and a 30-second turn clock. Configuration is milestone 8.3. No late seats or rebuys are accepted after starting. The host deals subsequent hands in the same room; the table finishes when fewer than two remaining players have chips.

## Rules and accounting

The server shuffles 52 distinct cards with cryptographic rejection sampling and Fisher–Yates, deals two private cards per seat, burns before each community street, and evaluates the best five of seven cards. The first button is random and moves clockwise between hands. Heads-up, the button posts the small blind and acts first preflop; the big blind acts first postflop. Transitioning to heads-up rotates the big blind from its previous seat.

Raises specify the total street contribution. A short all-in does not reopen a previous actor's betting unless cumulative increases reach the last full raise. Contribution layers form main and side pots; unmatched contributions return to their owner. Tied winners split each pot, with odd chips moving clockwise from the button. Every action and settlement checks that stacks plus committed chips equal the original table total, including departed players' chips.

These choices follow the [Poker TDA rules](https://www.pokertda.com/view-poker-tda-rules/) for betting, heads-up action, and odd chips. This game uses a moving button rather than tournament dead-button handling.

## Authority and recovery

`poker_action` accepts `start`, `next`, `fold`, `check`, `call`, `raise_to`, and `all_in`. Betting and next-hand requests require the exact hand UUID and revision. Room locks serialize competing requests; stale replies require a fresh snapshot, never automatic replay. Starting is host-only and idempotent. Old preview clients receive a refresh message through their original start endpoint.

Only the caller's hole cards appear before showdown. Showdown reveals nonfolded participants; folded cards, the deck, and future community cards stay private. Membership and a live Auth session are required. Table data has no direct browser grants; Presence carries advisory connection identifiers only.

Refresh preserves the seat and cards. Connections renew 90-second leases. Expired turns check when free and fold when facing a bet. Reads/actions enforce deadlines; minute cleanup can delay unattended enforcement by up to a minute. Leaving folds a funded player; an all-in player retains pot eligibility. Host ownership transfers to the lowest remaining seat. Closed/finished records follow the existing seven-day retention policy.

## Validation

Run `npm run test:poker` against local Supabase only. Fixtures cover hand ranks, 2–6-player play, side pots, split/odd chips, chip conservation, short/cumulative raises, concurrent/stale actions, private grants/cards, deadlines, departures, and reconnect leases. Browser scenarios in `tests/browser/poker.spec.js` complete successive hands and exercise three-player betting, recovery, keyboard controls, and narrow screens.

## Bots and mixed tables

The host can use **Add bot** in a waiting lobby and remove an individual bot before starting. A table can have one human with up to five bots, multiple humans with bots, or only humans. Humans and bots share the selected 2–6-seat capacity; a bot reserves its seat in discovery and join validation. Bots cannot be added, removed, or substituted during a started table. Ownership always stays with a human, and the room closes when the last human leaves or loses their connection lease.

Bots are labeled in both the waiting room and the hand view. They use a basic randomized, rule-based strategy based on their own hole cards, dealt community cards, public betting amounts, and remaining chips. The strategy function receives those values explicitly and cannot read the deck or opponents' cards. There is one bot difficulty, with no external AI or paid API. Bots can check, call, fold, and raise through the same legal mutation function used by human players.

Bot turns have a two-second target delay. Server reads/actions and existing cleanup process due turns under the room lock; client polling normally advances them within another second. Background tabs or unattended tables can update more slowly. Browsers cannot submit actions on a bot's behalf. Bots have private seat identifiers without Auth users, sessions, or heartbeat leases; human player references still enforce Auth foreign keys. Chip conservation, all-in eligibility, and payouts apply to every seat.

`poker_bot(p_lobby, p_action, p_seat)` accepts host-only `add` (no seat argument) and `remove` (bot seat required). The private bot registry has no browser grants. Run `npm run test:bots` locally for solo/mixed hands, five-bot tables, capacity races, private cards/grants, human ownership, and chip accounting. Browser coverage is in `tests/browser/bots.spec.js`.
