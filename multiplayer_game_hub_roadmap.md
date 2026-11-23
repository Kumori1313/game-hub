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

- [x] Test the entire flow on published GitHub Pages URLs with two independent browsers or devices, including asset paths and guest-session handoff.
- [x] Test full lobbies, simultaneous joins, illegal actions, refreshes, lost connections, host departure, and stale-room cleanup.
- [x] Check mobile layouts, keyboard navigation, readable contrast, and clear error messages.
- [x] Deploy reviewed SQL migrations, RLS policies, database functions, and site builds. Confirm production settings and usage alerts; never expose unrestricted test policies.
- [ ] Invite a small group to try the game, record problems and feedback, and fix the highest-impact issues.
- [x] Document deployment, rollback, troubleshooting, and the data/cleanup policy in the repositories.

**Milestone:** Automated release verification passed: 17 scenarios in each of Chromium and Firefox locally, four published release/gameplay scenarios, backend checks, and production settings/cleanup review. The owner confirms two-browser self-play, full-room rejection, and successful laptop/mobile play. External feedback is recorded and prioritized for Phase 8; separate-person playtest details remain unconfirmed. See the [release report](docs/release-report.md), [runbook](docs/release-runbook.md), and [playtest guide](docs/playtest-guide.md).

## Phase 8 — Expand the platform

### Milestone 8.1 — Shared lobbies and repeat play

- [x] Define and version the shared catalog, identity, seat, lobby, and round contract before adding a second game.
- [x] Add public and code-only rooms with backend-validated entry; keep private rooms out of discovery.
- [x] Default code-only rooms to four-character invites, with a host option for a 16-character code. Verify both invite lengths across the game clients and limit repeated code attempts.
- [x] Support game-specific player limits and host-selected capacity. Keep tic-tac-toe at two seats and verify poker lobby capacity from two to six.
- [x] Keep completed players in the room and require both to accept a tic-tac-toe rematch. Reject stale requests from previous rounds.
- [x] Randomly assign X for the first game and swap marks on rematches; host permissions remain independent of marks.
- [x] Publish a poker lobby preview in its own repository, with shared guest identity and no playable-poker claim.
- [x] Verify private entry, competing joins, full rooms, consent, reconnects, and cross-game isolation locally and on the published sites within the $0/month constraint.

**Milestone:** Complete. Public/code-only rooms, configurable 2–6-seat poker waiting rooms, randomized initial tic-tac-toe marks, and consent-based rematches are deployed. All 19 local browser scenarios pass in each of Chromium and Firefox; four focused published scenarios pass. Backend rules/concurrency and legacy-data upgrade replay pass. See the [shared room contract](docs/shared-room-contract.md) and [release report](docs/release-report.md). Poker dealing and betting remain 8.2.

### Milestone 8.2 — One complete poker variant

- [x] Implement play-money No-Limit Texas Hold’em for two to six players in the poker repository.
- [x] Keep the deck and other players’ hole cards on the trusted backend; return only each player’s authorized view.
- [x] Implement secure shuffling/dealing, rotating dealer/blinds, legal betting/raises/folds, all-ins, side pots, split pots, and correct payouts.
- [x] Continue through multiple hands in the same table. Define trusted turn deadlines, disconnect/rejoin behavior, departures, and table ownership.
- [x] Test rule fixtures, chip conservation, concurrent/stale actions, hidden-card isolation, and complete multi-player hands before publishing gameplay.
- [x] Add host-managed bots and mixed human/bot tables with shared seat limits, private decision inputs, and legal server-side turns.

**Milestone:** Complete. Play-money No-Limit Hold’em is deployed for 2–6 players with private cards, validated bets, side/split pots, trusted deadlines, host transfer, successive hands, and optional bot seats. All 23 browser scenarios pass locally in Chromium and Firefox; three focused published scenarios pass. Rule/accounting fixtures and legacy-data migration replay pass. See the [Hold’em contract](docs/poker-contract.md) and [release report](docs/release-report.md). Fixed 1,000-chip stacks, 10/20 blinds, and a 30-second clock remain until 8.3 adds settings.

### Milestone 8.3 — Configurable poker tables

- [x] Add bounded host settings for starting chips, blinds, turn timer, player limit, and rebuy policy. Show the agreed settings to players before play.
- [x] Lock or explicitly agree setting changes between hands; never rewrite an active hand’s rules.
- [x] Verify settings validation, defaults, mobile controls, reconnects, and saved table configuration.

**Milestone:** Complete. Hosts can configure starting chips, blinds, turn time, 2–6 total seats, and no/one/three rebuys per player. Rules lock at creation and persist across refreshes and hands; all guests see the agreed settings. Human rebuys are voluntary between hands; bots follow the same allowance. All 25 browser scenarios pass in Chromium and Firefox, three published scenarios pass, and settings/ledger fixtures plus old-client upgrade replay pass. See the [Hold’em contract](docs/poker-contract.md) and [release report](docs/release-report.md).

### Milestone 8.4 — Platform and ecosystem expansion

Platform expansion and additional games are the next priority. Further poker variants are outside the current roadmap and can be requested separately.

- [x] Publish a [game development guide](docs/game-development-guide.md) covering independent UI, existing routes, shared identity, backend integration, and verification.
- [x] Generalize hub navigation so new games can be listed through reviewed entries in `src/game-catalog.js`. Verify the existing development and production routes.
- [x] Generalize game-specific room dispatch through private backend adapters. Verify existing room behavior and snapshot compatibility locally.
- [x] Add and verify another game using the development guide. [Relay Room](docs/relay-room.md) covers guest entry, code admission, a full playthrough through extraction, recovery after refresh, and return to the hub in its browser playtest.
- [x] Integrate a game deployed by another owner. [Counter-Attack Web](docs/cs-web.md) keeps its original Pages origin and uses Game Hub lobbies with a browser-hosted match.
- [x] Verify Counter-Attack Web's cross-origin launch without exporting Game Hub credentials. Live Chromium checks passed for code admission, peer connection, guest recovery, and return to the hub.
- [x] Add a private relay for Counter-Attack Web when direct connections fail. Live Chromium checks covered both transports, a touch-enabled host, equipped weapon sync, and guest movement while the host stopped rendering.
- [x] Continue exchanging late ICE candidates and predict guest relay movement. Automated Chromium checks passed for a direct connection with delayed candidates and for gameplay over the forced relay.
- [x] Verify Counter-Attack Web on two physical devices. Player testing confirmed a direct match and reported barely noticeable guest latency after the relay update.
- [ ] Open Game Hub to more games from other owners. Counter-Attack Web's launch was built for that one game; turn it into a documented contract any outside game can adopt, following the [third-party integration plan](docs/third-party-games.md). The two items below are part of this work.
- [ ] Label standalone external links separately from games that use Game Hub lobbies.
- [ ] Define and test cross-origin authentication handoff before integrating games on another owner’s origin. Review trust and redistribution permission before hosting code on the hub’s origin.
- [ ] Extract shared code after the lobby contract is verified. Define supported client versions, migrations, and compatibility errors.
- [ ] Revisit host transfer, spectator mode, moderation, private game state, stronger anti-cheat, and scaling based on feedback.
- [ ] Review costs, usage, CAPTCHA, and upstream dependency fixes before wider promotion; keep paid changes outside the existing $0/month authorization.

**Milestone:** Additional games can integrate through a documented, tested contract and appropriate trust boundaries.

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
