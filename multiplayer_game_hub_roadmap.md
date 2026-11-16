# Multiplayer Game Hub: Development Roadmap

## Project goal

Build a GitHub Pages hub where guests enter a display name, browse or host multiplayer lobbies, and play games hosted in separate GitHub repositories. Supabase Auth supplies guest identities, Postgres stores lobby and match data, and Supabase Realtime delivers live updates.

## Initial scope and assumptions

- The hub and each game are separate GitHub Pages project sites, for example `https://USERNAME.github.io/game-hub/` and `https://USERNAME.github.io/tic-tac-toe/`.
- Guests do not create accounts or passwords. Supabase anonymous authentication assigns an ID behind the scenes; a display name is just a label and need not be unique.
- Start with two-player tic-tac-toe to prove the end-to-end design. Other games come later.
- Use Supabase Postgres as the source of truth, Realtime Postgres Changes for live updates, and Presence for connection indicators. Use transactional database functions for joins and moves.
- Treat this as a small initial release; the exact game, design, and scope can change as you learn.

## Phase 1 — Define the first release

- [x] Pick the first game, number of players, basic rules, and win/draw conditions.
- [x] Define the guest journey: enter name → choose game → browse/create lobby → join → play → return to hub.
- [x] Decide whether lobbies are public, invite-only, or both. For the first release, use public lobbies; add private invitations later if desired.
- [x] Decide what happens when a player leaves, the host disconnects, a lobby fills, or a game ends. A simple first policy: close the lobby when the host leaves and end an active match if either player leaves.
- [x] Sketch the hub, lobby list, lobby room, and game screens. Choose basic accessibility and mobile support goals.

**Milestone:** Complete. The [first-release specification](docs/first-release.md) defines tic-tac-toe rules, the guest journey, public lobby policies, screen sketches, accessibility goals, and implementation acceptance checks. Decisions beyond the selected game are initial defaults and may be revised before implementation.

## Phase 2 — Set up the projects

See the [setup guide](docs/phase-2-setup.md). Both repositories have Vite scaffolds and successful Pages deployments. Published HTML, JavaScript, and CSS return HTTP 200 at both project paths. Hosted Supabase creation awaits organization selection. Local Supabase is running; both repositories passed anonymous sign-in, verified-identity, and empty Data API checks.

- [x] Create repositories for the hub and the first game. Add a README, local setup instructions, and a Git ignore file to each.
- [ ] Create a Supabase project, enable anonymous sign-ins, and configure both sites with its project URL and publishable key. Version the Postgres schema using SQL migrations.
- [x] Set up local Supabase using its CLI and a Docker-compatible runtime for development and authorization testing. Use a separate production project when ready to release.
- [x] Configure GitHub Pages for each repository and confirm each site loads at its project URL.
- [x] Configure the build tool's base path and links for each repository's subdirectory; verify assets load on the published site.
- [x] Keep secret/service-role keys, database passwords, and management tokens out of repositories and browser code. The project URL and publishable key are client-visible; enforce access with grants and Row Level Security (RLS).

**Milestone:** Both sites display a basic page, and the local app can connect to local Supabase services.

## Phase 3 — Guest entry and hub

- [ ] Build the hub's welcome screen, display-name entry, and game selection cards.
- [ ] Sign in anonymously and store the display name with the guest ID. Validate its length and allowed characters, and display names as text rather than HTML.
- [ ] Use the same Supabase project and compatible session storage configuration across hub and game sites. Test that the guest session survives navigation between project paths on the same `USERNAME.github.io` origin; handle a missing session by asking the player to enter a name again.
- [ ] Explain that names are not reserved and guest identity may be lost when browser data is cleared or a different device is used.
- [ ] Show loading, connection, and error states, plus a way to change the display name.

**Milestone:** A guest can enter a name, select the first game, and arrive at its site with their guest session available.

## Phase 4 — Lobbies and presence

- [ ] Design a shared Postgres schema: game catalog, public lobby summaries, lobby membership, and match state. Use Auth user UUIDs for identity and generated UUIDs for lobbies and matches, not display names.
- [ ] Build a live lobby list with game, lobby name, player count, capacity, and waiting/in-progress status.
- [ ] Let guests create, join, and leave lobbies; assign the creator as host. Make joining atomic so simultaneous joins cannot exceed capacity or claim the same slot.
- [ ] Build the waiting room and a host-only start action. Prevent starting until the required players are present.
- [ ] Use Presence for connection indicators and authenticated, server-timestamped heartbeats for durable membership leases. Define a timeout and trusted cleanup executor for abandoned rooms; Presence leave events alone must not authorize cleanup. Aggregate multiple connections per guest and implement the Phase 1 departure policy.
- [ ] Pass a lobby ID to the game via a URL; verify the guest belongs to that lobby when they arrive. Avoid placing credentials in URLs.

**Milestone:** Two separate browser sessions can create and join a lobby, see updates, and handle leaving or losing a connection.

## Phase 5 — Secure the shared backend

Security is part of the first playable release, not an optional later addition.

- [ ] Enable RLS on exposed tables with deny-by-default grants and policies. Expose only intended public lobby fields; restrict other reads and writes to the appropriate guests.
- [ ] Tie membership and writes to `auth.uid()`. Anonymous signed-in users use the `authenticated` database role, not the unauthenticated `anon` role. Restrict host actions and membership transitions.
- [ ] Validate field types, lengths, allowed values, capacities, and legal state transitions. Prevent players from changing another player's identity or escalating themselves to host.
- [ ] Model access carefully: data readable by a client cannot be hidden from that client through the interface. Keep secrets and hidden game information out of publicly readable records.
- [ ] Use transactional Postgres functions with row locking for joins, starts, and moves. Validate identity, membership, turn order, and state transitions inside each function. Restrict execution grants and audit any security-definer functions; RLS alone does not enforce game rules.
- [ ] Write local database/RLS and API integration tests for allowed and denied actions, including unauthorized host actions, invalid moves, overfilled lobbies, and edits to another player. Test concurrent joins and moves.
- [ ] Review Supabase usage limits and available alerts, including anonymous sign-ins and Realtime usage. Configure rate limits and consider CAPTCHA for abuse protection; these do not replace RLS or server-side validation.

**Milestone:** RLS, database-function, and concurrency tests pass locally, and common unauthorized actions fail from another guest session.

## Phase 6 — Build the first playable game

- [ ] Implement and test the game's rules locally: legal moves, turns, wins, draws, and reset/end behavior.
- [ ] Connect the game to the lobby and store the minimum match state needed to synchronize players.
- [ ] Enforce turn order and valid moves in transactional database functions. Restrict direct match-state writes so clients cannot bypass validation.
- [ ] Handle simultaneous actions, disconnects, refreshes, and duplicate clicks. Make the current turn, result, and connection state clear.
- [ ] Add a clear way to leave the match and return to the hub. Clean up or expire completed match data according to a documented policy.

**Milestone:** Two people on separate devices can play one complete game, see the same outcome, and return to the hub.

## Phase 7 — Test and release

- [ ] Test the entire flow on published GitHub Pages URLs with two independent browsers or devices, including asset paths and guest-session handoff.
- [ ] Test full lobbies, simultaneous joins, illegal actions, refreshes, lost connections, host departure, and stale-room cleanup.
- [ ] Check mobile layouts, keyboard navigation, readable contrast, and clear error messages.
- [ ] Deploy reviewed SQL migrations, RLS policies, database functions, and site builds. Confirm production settings and usage alerts; never expose unrestricted test policies.
- [ ] Invite a small group to try the game, record problems and feedback, and fix the highest-impact issues.
- [ ] Document deployment, rollback, troubleshooting, and the data/cleanup policy in the repositories.

**Milestone:** A small group can reliably discover, join, and complete a game on the live sites.

## Phase 8 — Expand the platform

- [ ] Add another game using the same guest and lobby conventions; document the shared data contract and link format first.
- [ ] Extract shared code only after patterns are clear. Version shared contracts so a game update does not silently break the hub.
- [ ] Consider invite links or codes, rematches, host transfer, spectator mode, and configurable lobby settings based on feedback.
- [ ] Revisit architecture for faster real-time games, private game state, stronger anti-cheat, moderation, and scaling. These may require trusted server logic or a dedicated game server.
- [ ] Review cost and usage as player counts and update frequency grow.

**Milestone:** A second game can join the platform without redesigning the core guest and lobby flow.

## Suggested first steps

1. Follow the [tic-tac-toe first-release specification](docs/first-release.md); Phase 1 planning is complete.
2. Create the two repositories and publish a basic page from each.
3. Set up Supabase locally, then prove anonymous guest entry and a live lobby with two browsers.
4. Add and test RLS policies and database functions before exposing real multiplayer data publicly.

## Useful official references

- [GitHub Pages overview and site types](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages)
- [Supabase anonymous sign-ins](https://supabase.com/docs/guides/auth/auth-anonymous)
- [Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Supabase database functions](https://supabase.com/docs/guides/database/functions)
- [Supabase local development](https://supabase.com/docs/guides/local-development)
- [Supabase Realtime](https://supabase.com/docs/guides/realtime)
