# Shared room contract — version 2

## Scope and clients

The hub owns the catalog and backend migrations. Tic-tac-toe and poker use `room_action` and the same guest identity on the trusted `kumori1313.github.io` origin. The game ID is supplied explicitly and verified against the room. A single guest has one room membership across the platform. Different-origin integration remains milestone 8.5.

| Game | Seats | Start behavior |
| --- | --- | --- |
| `tic-tac-toe` | Exactly two | Host starts; the server randomly assigns X once and X goes first. |
| `poker` | Host chooses 2–6 | No-Limit Hold’em, mixed bot/human seats, and locked table settings. |

The authenticated catalog publishes stable IDs, names, minimum/maximum players, launch paths, contract version, and whether gameplay is available. Catalog settings are maintained by trusted migrations, not clients. Room capacity and public/private visibility are fixed at creation. Poker chip/blind/timer/rebuy settings lock at room creation; additional poker modes remain milestone 8.4.

## Room API and authorization

`room_action(p_action, p_lobby, p_connection, p_game, p_capacity, p_visibility, p_code, p_round)` dispatches `create`, `join`, `join_code`, `current`, `snapshot`, `heartbeat`, `leave`, `start`, `rematch`, and `cancel_rematch`. Optional values have explicit defaults. Every private action validates the live Auth session, derives the actor from `auth.uid()`, and checks membership or admission before returning a snapshot. Game and seat limits are enforced server-side.

Rows are locked while admitting players, starting games, or consenting to rematches. A per-guest advisory lock prevents concurrent membership in different rooms. Seats have unique room-local numbers; tic-tac-toe marks are independent of seats and host privileges. Poker seats have no X/O mark. An expired waiting guest frees its seat; host departure closes a waiting room. Existing 90-second per-tab leases and trusted cleanup remain authoritative.

Public discovery still exposes only the eight safe summary fields documented in the lobby contract. **Private rooms never have a public summary row**, even for their members. A UUID/link cannot admit a nonmember to a private room. Existing admitted members can refresh without reentering the code.

## Code-only rooms

The backend generates a 64-bit random code displayed to admitted members in four-character groups. Codes can be shared by the players; they are bearer invitations, not permanent passwords. Code entry is case-insensitive and ignores spaces/hyphens. The client does not put codes or credentials in URLs, browser storage, or Presence payloads. The code is stored only in the unexposed private room row and returned only after membership authorization.

Unknown, closed, full, and wrong-game code attempts return a generic error envelope. Unlike raised exceptions, these replies commit the per-guest request-budget charge, so rejected attempts count too. The UI translates the envelope to a visible error. Standard input/auth failures use errors as before. Existing Auth limits and high-entropy codes complement access checks; distributed abuse is not eliminated. Codes expire with their room; closed/finished rooms do not admit new players.

## Rematches and stale requests

Completed tic-tac-toe players retain their seats and see **Rematch**. Each may consent or cancel consent for that round. Both must still be members with live connection leases. The second consent atomically creates the next match in the same room, swaps X/O, clears the completed-room timestamp, and begins with an empty board. A single consent never resets state. Leaving removes that player's votes; a remaining player cannot restart alone. There is no automatic host transfer.

Each match has a unique UUID and a room-local round number. `submit_move(p_lobby, p_cell, p_revision, p_match)` requires that exact current match ID in addition to the expected board revision. Old move requests cannot affect a new round with revision zero. Repeated consent for an earlier round is an authorized no-op, not another restart. Clients reject older-round snapshots/replies and compare revisions within a round. Hosts retain start/close privileges regardless of who has X.

Snapshots return the current match only. Prior match rows remain immutable private records until room retention deletes them; there is no history UI. Finished rooms keep polling/heartbeating to support consent, refresh, and reconnection. Closed rooms stop regular updates. After seven days from the last terminal room timestamp, cleanup cascades through matches, votes, members, connections, and summaries. Active rooms still expire through leases.

## Compatibility and migration

The original `lobby_action` and `play_move` wrappers remain for version 1 clients. Version 1 creation/start retains host-as-X for its first round. New rooms are version 2; calling the old start wrapper on them does not force the host to X. Legacy move requests are rejected after the room advances beyond its first round. New clients use the match-bound `submit_move` API.

Migration `20261118030904` preserves existing rooms, backfills their seats from old marks before enforcing non-null uniqueness, and seeds the poker catalog entry explicitly. A structural replay in an isolated local database verifies waiting/active/finished legacy fixtures and continuation of an old active match. Minimal Auth/Realtime/cron stubs in that replay are complemented by full local Supabase API, RLS, concurrency, and browser tests.

## Verification

```bash
npm run test:lobbies
npm run test:security
npm run test:rooms
npm run test:upgrade
GAME_SITE_DIR=/path/to/tic-tac-toe POKER_SITE_DIR=/path/to/poker npm run test:release
E2E_BROWSER=firefox GAME_SITE_DIR=/path/to/tic-tac-toe POKER_SITE_DIR=/path/to/poker npm run test:e2e
```

Build all three sites before browser-only checks. Integration scripts target local Docker/Supabase only. Tests cover six-way competing joins, smaller capacities, seat reuse, private discovery/admission, persistent failed-code accounting, cross-game rejection, consent cancellation and duplicate votes, mark swapping, prior results, stale moves/replies, and the existing full game flow. Published tests create real anonymous test users, so use a focused suite below provider signup limits.

## Poker gameplay (8.2)

Started poker rooms use `poker_table_action` with a hand UUID and revision; `poker_action` remains available for default-rule legacy clients. Authorized room snapshots include a caller-specific `poker` view; `match` remains reserved for tic-tac-toe. Private deck/players/history tables are never exposed to clients or Realtime. Shared connection leases and room admission still apply; poker departures transfer ownership instead of aborting the table. See the [Hold’em contract](poker-contract.md) for rules, payouts, deadlines, and recovery.
