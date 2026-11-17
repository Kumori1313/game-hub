# Lobby Contract (Phase 4)

## User flow

Choose tic-tac-toe from the hub to open its public lobby list. Create a room or join an available seat. The host plays X and the other guest plays O. Only the host sees **Start game**, and it is disabled until two connected members are present. Full and in-progress rooms cannot be joined.

Waiting rooms use `?room=<UUID>`. Starting creates the shared match record and both browsers transition to `?lobby=<UUID>`. Every arrival verifies membership through the backend; a copied link does not grant a seat. Refreshing or reopening the game restores an active membership. URLs contain only the lobby UUID, never guest tokens or names.

The game repository owns lobby discovery, waiting-room UI, and match entry. The hub owns the shared database configuration, migrations, and integration tests. Phase 4 initializes an empty board. Phase 5 adds the guarded move API; Phase 6 adds the playable board.

## Data model and access

| Object | Data and access |
| --- | --- |
| `public.game_catalog` | Authenticated guests can read game names and capacities. |
| `public.lobby_summaries` | Read-only discovery fields: room ID, game, title, count, capacity, status, host lease expiry, creation time. No member IDs, tokens, or match state. |
| `game_private.lobbies` | Host UUID, lifecycle, departure reason, and timestamps. |
| `game_private.memberships` | Guest UUID, display-name label, and X/O mark. One current membership per guest; marks are unique within a room. |
| `game_private.connections` | Separate server-timestamped lease for each tab/connection. |
| `game_private.matches` | Match UUID, lobby, board, turn, revision, result, and interrupted state. |

All tables have RLS. Clients receive no direct access to private tables and no writes to public tables. New public objects require explicit client grants. Trusted `service_role` defaults remain available for server administration, never browser code.

`public.lobby_action` is an invoker wrapper around a guarded security-definer dispatcher in the unexposed private schema. Its operations are `create`, `join`, `current`, `snapshot`, `heartbeat`, `leave`, and `start`. Every operation derives the actor from `auth.uid()`; callers cannot submit another actor or host ID. Names are untrusted labels sourced from that actor’s Auth record and displayed with `textContent`.

Room row locks serialize joins and starts. A per-guest transaction advisory lock prevents two tabs from creating or joining separate rooms concurrently. A repeated host start is idempotent. Creating more than ten rooms per minute for one guest is rejected. Internal maintenance functions have no client execution grants; exposed wrappers use an empty search path and explicit grants.

## Presence, leases, and cleanup

Each attached page sends a heartbeat every 15 seconds, extending its connection lease by 90 seconds using database time. Any unexpired connection keeps the guest present, so closing one tab does not remove another tab’s seat. Refresh and navigation can reattach during the lease. After all leases expire, a waiting non-host’s seat is freed; a departed host closes the room; either departure during play aborts the match without awarding a result.

Explicit **Leave** is immediate. Navigating through a Game Hub link also leaves explicitly; active matches require confirmation. Ordinary tab closure, network loss, or browser-history navigation uses lease expiration instead of unreliable unload requests. A returning browser cannot resume a terminal match.

A private `lobby:<UUID>` Presence channel provides advisory connection indicators. Realtime policies restrict room Presence to members. Payloads contain only guest IDs, never tokens, names, board state, or authorization claims. Presence payloads and cached channel permissions are never authoritative for membership, starting, or cleanup. Supabase caches channel authorization until reconnection/token refresh; clients remove their channels when leaving.

Postgres Changes on public summaries triggers discovery refreshes. Summaries are updated only when their values change, avoiding a feedback loop from snapshot reads. A 10-second discovery refresh handles lease expiry and rows becoming unreadable under RLS; member snapshots refresh every four seconds. Realtime failures retain polling and heartbeats. Network failures disable actions and preserve membership until its lease expires.

`game_private.sweep_lobbies`, scheduled by pg_cron every minute, closes abandoned rooms even without a browser. It uses server state and skips locked rooms. Snapshot/join/heartbeat calls also prune the relevant room. Cleanup therefore occurs after the 90-second lease, with up to an additional scheduler minute when no client remains. Closed room, member, connection, and match records are deleted after seven days through cascading foreign keys.

## Local setup and verification

From the hub, start local Supabase and apply migrations:

```bash
npm run supabase:start
npx supabase migration up
npm run check:backend
npm run test:lobbies
```

The integration runner targets loopback only and uses the local Docker database to simulate expired leases. It checks atomic competing joins, host-only and idempotent starts, forbidden reads/writes, private Presence rejection, multiple connections, guest/host departures, match aborts, per-guest room serialization, and scheduled retention. It creates anonymous test users and closes test rooms; no production requests are permitted.

Build both sites with local environment files, then run `GAME_SITE_DIR=/absolute/path/to/tic-tac-toe npm run test:e2e`. Two browser scenarios cover discovery, joining/full rooms, unauthorized links, leaving/rejoining, host start, shared URL transition, refresh, interruption, multiple tabs, mobile layout, and offline recovery. The existing guest/theme scenarios remain part of the suite.

For hosted deployment, inspect migration state first and apply the reviewed migrations using an explicit remote target. Run security advisors afterward. Never edit applied migrations; add a new migration for subsequent schema changes. Reverting site code does not revert database changes. See the [Phase 5 review](security-review.md) for live-session checks, move validation, abuse controls, and their limits. Phase 6 adds the playable interface.

## Advisor review

The missing foreign-key index reported after initial deployment is covered by the follow-up index migration. New indexes may still be listed as unused while the project has little data. The private tables intentionally have RLS with no client policies because they have no client grants and are accessed only through guarded functions; the [RLS-without-policy notice](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy) reflects that deny-by-default design.

The [anonymous-access notices](https://supabase.com/docs/guides/database/database-advisors?queryGroups=lint&lint=0012_auth_allow_anonymous_sign_ins) are expected for public game/lobby discovery and member-checked Presence: this platform intentionally supports signed-in anonymous guests. pg_cron’s extension-owned job policies also generate this notice; `authenticated` lacks usage on the unexposed `cron` schema, and the job’s owner is the trusted database role. Leaked-password protection remains a future account-security setting because this app has no password login.

## Completion record

Local backend checks, unit checks, and builds pass in both repositories. The local integration runner verifies permissions, competing joins, idempotent starts, Presence allow/deny behavior, forced lease expiry, multiple connections, retention, and creation limits. All 11 browser scenarios pass locally and on the published sites, including authorized private Presence and recovery from an invalid link while already in a room. Hosted migrations are applied and the scheduled cleanup job has completed successfully. Desktop and mobile waiting-room screenshots were reviewed.

Phase 5 continues with broader adversarial and abuse-control coverage. Phase 6 implements actual tic-tac-toe moves, wins/draws, and result handling; Phase 4 provides only verified match initialization and interruption.
