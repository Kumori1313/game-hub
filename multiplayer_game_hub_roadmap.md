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

See the [setup guide](docs/phase-2-setup.md). Both repositories have Vite scaffolds and successful Pages deployments. Published HTML, JavaScript, and CSS return HTTP 200 at both project paths. Hosted Supabase project `game-hub` (`ivjznofekldhkocheija`, US East) is healthy, anonymous Auth is enabled, and both repositories have matching public build variables. Local Supabase is running; both repositories passed anonymous sign-in, verified-identity, and empty Data API checks.

- [x] Create repositories for the hub and the first game. Add a README, local setup instructions, and a Git ignore file to each.
- [x] Create a Supabase project, enable anonymous sign-ins, and configure both sites with its project URL and publishable key. Version the Postgres schema using SQL migrations when application tables are introduced.
- [x] Set up local Supabase using its CLI and a Docker-compatible runtime for development and authorization testing. Use a separate production project when ready to release.
- [x] Configure GitHub Pages for each repository and confirm each site loads at its project URL.
- [x] Configure the build tool's base path and links for each repository's subdirectory; verify assets load on the published site.
- [x] Keep secret/service-role keys, database passwords, and management tokens out of repositories and browser code. The project URL and publishable key are client-visible; enforce access with grants and Row Level Security (RLS).

**Milestone:** Complete. Both Pages sites are deployed, local backend checks pass in both repositories, and hosted anonymous Auth and Data API connectivity are verified. No application tables exist yet; schema migrations and RLS policies arrive with lobby implementation.

## Phase 3 — Guest entry and hub

- [x] Build the hub's welcome screen, display-name entry, and game selection cards.
- [x] Sign in anonymously and store the display name with the guest ID. Validate its length and allowed characters, and display names as text rather than HTML.
- [x] Use the same Supabase project and compatible session storage configuration across hub and game sites. Test that the guest session survives navigation between project paths on the same `USERNAME.github.io` origin; handle a missing session by asking the player to enter a name again.
- [x] Explain that names are not reserved and guest identity may be lost when browser data is cleared or a different device is used.
- [x] Show loading, connection, and error states, plus a way to change the display name.

**Milestone:** Complete. Guests can enter or change a name, select tic-tac-toe, and carry their identity between both published sites. Four browser scenarios pass locally and on GitHub Pages. See the [guest-session contract and verification notes](docs/phase-3-guests.md).

## Phase 3.5 — Redesign the visual experience

This phase follows guest entry and precedes lobby implementation. Existing phase numbers remain unchanged. See the [UI redesign brief](docs/ui-redesign.md) for reference analysis, layout direction, and acceptance criteria.

- [x] Design an original Game Hub visual identity, including a mark and coordinated artwork for the top navigation and mission banner, inspired by the supplied CentOS reference.
- [x] Establish a spacious layout with clear typography, restrained accents, and a desktop side panel inspired by AI 2027.
- [x] Add light and dark modes with dark as the first-visit default, an accessible navigation toggle, and a persisted theme choice shared across both sites. Verify both themes without resetting guest sessions or form input.
- [x] Prototype a side visual that responds to scrolling and guest-entry progress using an illustrative tic-tac-toe sequence; distinguish illustrations from live game data.
- [x] Apply the design to the hub and tic-tac-toe entry pages while preserving guest identity, name editing, connection feedback, and navigation.
- [x] Define reusable styles and layouts for upcoming lobby lists, waiting rooms, and match screens.
- [x] Provide narrow-screen layouts and reduced-motion alternatives; verify keyboard use, contrast, focus visibility, and animation controls.
- [x] Review desktop and mobile previews, rerun guest-session browser tests, and verify the redesign on both published project URLs.

**Milestone:** Complete. Both published sites share original navigation/banner artwork, dark-by-default themes with a remembered toggle, and a scroll-responsive side illustration. Unit checks and builds pass in both repositories; all nine browser scenarios pass locally and on GitHub Pages. See the [component guide](docs/ui-components.md) for the shared styling and future screen sketches.

## Phase 4 — Lobbies and presence

- [x] Design a shared Postgres schema: game catalog, public lobby summaries, lobby membership, and match state. Use Auth user UUIDs for identity and generated UUIDs for lobbies and matches, not display names.
- [x] Build a live lobby list with game, lobby name, player count, capacity, and waiting/in-progress status.
- [x] Let guests create, join, and leave lobbies; assign the creator as host. Make joining atomic so simultaneous joins cannot exceed capacity or claim the same slot.
- [x] Build the waiting room and a host-only start action. Prevent starting until the required players are present.
- [x] Use Presence for connection indicators and authenticated, server-timestamped heartbeats for durable membership leases. Define a timeout and trusted cleanup executor for abandoned rooms; Presence leave events alone must not authorize cleanup. Aggregate multiple connections per guest and implement the Phase 1 departure policy.
- [x] Pass a lobby ID to the game via a URL; verify the guest belongs to that lobby when they arrive. Avoid placing credentials in URLs.

**Milestone:** Complete. Public discovery, atomic two-player rooms, host-only start, private Presence, 90-second multi-connection leases, scheduled cleanup, and verified match-entry URLs are deployed. Local API/concurrency tests and all 11 browser scenarios pass, including the published sites. See the [lobby contract](docs/lobby-contract.md). Gameplay remains Phase 6; broader adversarial and abuse-control work remains Phase 5.

## Phase 5 — Secure the shared backend

Security is part of the first playable release, not an optional later addition.

- [x] Enable RLS on exposed tables with deny-by-default grants and policies. Expose only intended public lobby fields; restrict other reads and writes to the appropriate guests.
- [x] Tie membership and writes to `auth.uid()`. Anonymous signed-in users use the `authenticated` database role, not the unauthenticated `anon` role. Restrict host actions and membership transitions.
- [x] Validate field types, lengths, allowed values, capacities, and legal state transitions. Prevent players from changing another player's identity or escalating themselves to host.
- [x] Model access carefully: data readable by a client cannot be hidden from that client through the interface. Keep secrets and hidden game information out of publicly readable records.
- [x] Use transactional Postgres functions with row locking for joins, starts, and moves. Validate identity, membership, turn order, and state transitions inside each function. Restrict execution grants and audit any security-definer functions; RLS alone does not enforce game rules.
- [x] Write local database/RLS and API integration tests for allowed and denied actions, including unauthorized host actions, invalid moves, overfilled lobbies, and edits to another player. Test concurrent joins and moves.
- [x] Review Supabase usage limits and available alerts, including anonymous sign-ins and Realtime usage. Configure rate limits and consider CAPTCHA for abuse protection; these do not replace RLS or server-side validation.

**Milestone:** Complete. Local authorization, session, game-rule, and concurrency checks pass. Hosted migrations and Auth limits are applied; both sites enforce browser policies. See the [security review](docs/security-review.md) for scope, monitoring, and the CAPTCHA decision before wider release. Phase 6 adds the playable board.

## Phase 6 — Build the first playable game

- [x] Implement and test the game's rules locally: legal moves, turns, wins, draws, and reset/end behavior.
- [x] Connect the game to the lobby and store the minimum match state needed to synchronize players.
- [x] Enforce turn order and valid moves in transactional database functions. Restrict direct match-state writes so clients cannot bypass validation.
- [x] Handle simultaneous actions, disconnects, refreshes, and duplicate clicks. Make the current turn, result, and connection state clear.
- [x] Add a clear way to leave the match and return to the hub. Clean up or expire completed match data according to a documented policy.

**Milestone:** Complete. Two independent browser sessions can play X/O wins and draws, retain the same final board, and return to the hub for a fresh match. All 15 browser scenarios pass locally and on the published sites; server rule/concurrency checks pass locally. See the [gameplay contract](docs/gameplay-contract.md). Physical-device and small-group release testing remain Phase 7.

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
