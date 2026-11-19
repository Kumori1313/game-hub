# Developing a Game for Game Hub

This guide assumes you have the Game Hub source checkout. It explains how to build a separate game that uses the hub's navigation, guest identity, and multiplayer services. Use tic-tac-toe and poker as working references; new games still need reviewed hub/backend integration.

## Your game can have its own UI

Your game does **not** need to match the hub's colors, typography, layout, artwork, or theme controls. Use the visual style and rendering technology that suit it: ordinary HTML, a frontend framework, Canvas, or WebGL. The hub's CSS, decorative illustrations, and dark/light theme implementation are optional.

Compatibility comes from routes, identity, and server contracts. Provide accessible controls, readable connection/error feedback, and a clear way back to the hub. If you adopt the shared theme preference, keep it separate from authentication; its existing storage key is `game-hub-theme`.

## Understand the current integration boundary

The hub launches separate static websites with normal links. It does not embed games in iframes or discover executable plugins. Production paths currently share one origin:

| Site | Production path |
| --- | --- |
| Hub | `https://kumori1313.github.io/game-hub/` |
| Tic-tac-toe | `https://kumori1313.github.io/tic-tac-toe/` |
| Poker | `https://kumori1313.github.io/poker/` |

The hub renders game links from the reviewed entries in `src/game-catalog.js`. Add an entry there to show a new game in the menu. The database catalog and room dispatch control multiplayer admission separately. Room dispatch currently accepts `tic-tac-toe` and `poker`, so maintainers must extend it for a new game.

A simple external link is another integration level, but it does not grant shared identity or lobbies. A different owner's GitHub Pages site has a different origin. It cannot access the saved hub session just by using the same storage key. Shared integration there requires a separately implemented and reviewed authentication handoff. Never put access tokens, refresh tokens, or room codes in launch URLs.

## Divide the code by responsibility

Keep the game in its own repository or sibling checkout:

```text
projects/
  game-hub/                 # Platform source, shared backend, integration tests
  my-game/
    src/
      main.js               # Bootstrap and navigation
      supabase.js           # Shared-project client configuration
      guest.js              # Guest session/name service
      rooms.js              # Your room adapter and lifecycle
      game.js               # Rendering and player input
    public/                 # Game-owned assets
    scripts/                # Build/security/verification helpers
    package.json
    vite.config.js          # If using Vite
```

These names are suggestions, not required interfaces. Keep rendering separate from identity, room coordination, and server actions. The hub owns `supabase/config.toml` and `supabase/migrations/`; contribute game-specific schema and trusted rules there, rather than creating a separate production backend for shared-platform play.

Useful references in your hub checkout:

- `src/supabase.js`, `src/guest.js`: reusable identity configuration and service.
- `src/guest-ui.js`: optional DOM-based guest interface; inspect its selectors before copying it.
- `scripts/security-policy.mjs`, `vite.config.js`: browser configuration checks and security policy.
- [Shared room contract](shared-room-contract.md): admission, membership, codes, leases, rounds.
- [Hold’em contract](poker-contract.md): an example with private information and configurable rules.

The game repositories contain their own `src/lobbies.js` and renderers: [tic-tac-toe source](https://github.com/Kumori1313/tic-tac-toe/tree/main/src), [poker source](https://github.com/Kumori1313/poker/tree/main/src). Their copied room controller still contains game-specific selectors, imports, and action dispatch. Passing a new `gameId` or `mountGame` alone will not integrate another game. Adapt that coordination code or implement an adapter for your own UI. Preserve applicable licenses when reusing code and assets.

## Choose a stable game ID and root route

Use a lowercase, hyphenated ID such as `my-game`, with a matching deployment path `/my-game/`. Repository naming can differ, but the configured base, approved launch path, asset URLs, and deployed directory must agree.

For a Vite frontend, copy the hub's security-policy helper into the game's `scripts/` directory and adapt its configuration:

```js
import { defineConfig, loadEnv } from 'vite';
import { validateClientConfig, securityMeta } from './scripts/security-policy.mjs';

export default defineConfig(({ mode, command }) => {
  const env = loadEnv(mode, process.cwd(), 'VITE_');
  const backend = validateClientConfig(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_PUBLISHABLE_KEY);
  return {
    base: '/my-game/',
    server: { host: '127.0.0.1', port: 5176, strictPort: true },
    plugins: [{
      name: 'browser-security-policy',
      transformIndexHtml: { order: 'post', handler: html =>
        securityMeta(html, backend, command === 'serve' ? 5176 : null) },
    }],
  };
});
```

Use the hub's pinned dependency versions as a reference, commit your lockfile, and define your own exact install/dev/build/test commands. Other build systems are fine if they produce static files and support the deployment prefix. Reference public assets through that prefix, for example `${import.meta.env.BASE_URL}art/board.svg` in Vite.

The current navigation convention uses one entry document and query parameters:

| URL | Meaning |
| --- | --- |
| `/my-game/` | Guest entry or lobby selection |
| `/my-game/?room=<uuid>` | Requested waiting room |
| `/my-game/?lobby=<uuid>` | Requested active or completed room |

Read `lobby` first and fall back to `room`, as existing clients do:

```js
const url = new URL(location.href);
const requestedRoom = url.searchParams.get('lobby') ?? url.searchParams.get('room');
```

Validate the ID and ask the backend for authorized membership before opening the room. A URL is a request, not admission. Existing clients recover their current room when no link is supplied, and show a useful error if a requested room is unavailable. Keep private invitations in the code-entry flow.

After an authorized transition, update the query using `history.replaceState`; preserve the `/my-game/` pathname and remove the obsolete query alias. This keeps refreshes on an existing static document. Additional clean paths such as `/my-game/match/123` need their own static files or a tested hosting fallback; the current Pages setup does not supply an SPA router rewrite.

Provide a return link to `/game-hub/`. Resolve leaving an active room through the server first, using the game's departure policy, so navigation does not leave a ghost seat until its lease expires.

## Reuse the guest identity contract

Use the same Supabase project URL, browser-safe publishable key, and client options as `src/supabase.js`:

```js
const client = createClient(projectUrl, publishableKey, {
  auth: {
    storageKey: 'game-hub-auth',
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
  },
});
```

Supply `projectUrl` and `publishableKey` from the game's environment/build configuration. Never bundle database passwords, secret/service-role keys, or management credentials. Ignore `.env.local` in Git. Namespace game-specific storage keys; do not clear or repurpose `game-hub-auth`.

Reuse `createGuestService` and `displayName` from `src/guest.js`, or implement equivalent behavior in your framework. Restore and verify an existing session before showing name entry. When needed, use the service's `save(name)` to create an anonymous guest or update the existing name. Names are nonunique, untrusted labels; use the verified UUID for identity and render names as text.

If you reuse `mountGuestEntry`, mount listeners before it emits `guest-state`, and handle `{ ready, userId }` to start or pause room coordination. Custom UI can call the guest service directly instead. Stop coordination and return to entry when the server reports an ended session; transient network errors should preserve the saved identity.

Different ports are different origins. Separate Vite servers on 5173 and 5176 are useful for development but do not demonstrate shared browser storage or seamless identity handoff.

## Define the game's server contract with the maintainers

Before enabling shared lobbies, contribute reviewed migrations and agree on these behaviors:

1. **Registration and admission.** Seed the catalog fields `id`, `name`, `min_players`, `capacity`, `playable`, `contract_version`, and `launch_path`. Extend the current game allowlist and relevant dispatch. Shared room limits currently support 2–6 total seats; other sizes require schema and client work. Admission, capacity, and seat allocation must be atomic. One guest currently has one platform room membership.
2. **Start and snapshots.** Define host permissions and initialization; include only the caller's authorized game state in guarded room snapshots. The current `match` payload belongs to tic-tac-toe and `poker` to poker. Add an explicit game payload and compatible dispatch rather than treating either as a universal model.
3. **Actions and synchronization.** Implement trusted action handlers that validate the live session, game, membership, turn, rules, and current match/hand/round ID plus revision. Derive the actor server-side. Keep decks, hidden hands, answers, or other private information off clients that cannot see them. Browser-computed results are not authoritative.
4. **Recovery and completion.** Define disconnects, departures, ownership, deadlines, results, replay/rematch consent, and cleanup. The existing reference uses 15-second heartbeats, 90-second per-tab leases, guarded polling, and seven-day terminal retention. This suits small turn-based games; propose a reviewed transport/runtime design if your game needs continuous real-time simulation. Private Presence is advisory; it is not the membership or game-state authority.
5. **Permissions and compatibility.** Keep game tables private with RLS and restricted grants. Expose narrow authenticated RPCs, and update API-exposure checks for reviewed endpoints. Preserve old-client behavior or return a clear refresh/incompatibility response. Add a new migration; never rewrite an applied one.

Inspect the **latest** definitions across migrations: `game_private.room_api`, `room_snapshot`, `prune_lobby`, and `sync_summary` contain shared lifecycle integration. The current implementations have tic-tac-toe/poker branches for starts, snapshots, departures, and cleanup; those need deliberate extension. Poker-only bots, settings, and rebuys are not generic platform APIs.

Handle both Supabase RPC errors and returned `{ error, code }` envelopes; some room denials use an envelope so the request-budget charge commits.

Render confirmed snapshots. Ignore older rounds/revisions and late responses from a previous room. Bound requests, disable duplicate submissions, and reread state after a lost reply rather than automatically replaying an action that may already have committed.

## Wire navigation and test one origin locally

A complete integration PR must cover both repositories:

- Add a reviewed entry in `src/game-catalog.js` with the slug, title, link label, display details, unique title and link IDs, and local dev port. For `my-game` on port `5176`, the hub generates `/my-game/` in production and `http://127.0.0.1:5176/my-game/` in development.
- Add the catalog/backend migration and new-game lifecycle/action tests in the hub. Keep gameplay disabled until its compatible client and reviewed backend are ready.
- Add a root mapping in `scripts/serve-session-test.mjs`, for example:

  ```js
  'my-game': resolve(process.env.MY_GAME_SITE_DIR ?? '../my-game', 'dist'),
  ```

- Build the hub and game, then serve both from the test server at `http://127.0.0.1:4175/game-hub/` and `/my-game/`. Supply `MY_GAME_SITE_DIR` when needed. The mapping does not build the game or register it with the backend.
- Extend browser tests and release orchestration for the new checkout. Existing `GAME_SITE_DIR`, `POKER_SITE_DIR`, and `scripts/check-release.mjs` currently describe tic-tac-toe and poker; a new environment variable alone does not add a game to the release suite.

Run local Supabase from the hub checkout using `npm ci`, `npm run supabase:start`, and `npx supabase migration up`. Follow the [backend setup guide](phase-2-setup.md) for Docker and local publishable-key setup. Configure each frontend with the same **local** backend in its ignored `.env.local`. Keep routine fixture and expiry tests local.

Verify hub → game → room → match → hub, direct links, refresh, unavailable rooms, private-code entry, competing joins, wrong-game access, stale/lost actions, disconnect/rejoin, results, and leaving. Use independent browser contexts, mobile widths, keyboard controls, and any private-information isolation tests your game needs. Retain regression coverage for existing games.

## Deployment and contribution checklist

For current shared identity, arrange reviewed deployment under the hub's trusted origin. A separately owned source repository can be compatible, but publishing it under another owner's Pages origin does not provide session sharing. Same-origin game code can access the shared session, so review source, dependencies, permissions, and redistribution licenses before hosting it there.

Use the existing Pages workflow as a build/deployment reference. Match the approved base path, output directory, and the shared project's `VITE_SUPABASE_URL` / `VITE_SUPABASE_PUBLISHABLE_KEY` Actions variables when using Vite. Coordinate backend-first deployment, client publication, and gameplay enablement with the maintainers. Stay within the existing $0/month scope unless paid resources are explicitly approved.

Include these in your contribution:

- Stable game ID, rules, player limits, proposed route/origin, source and asset licenses.
- Game repository, reproducible commands, and corresponding hub/backend changes.
- Defined lifecycle, private-state boundaries, supported contracts, and recovery behavior.
- Test results and screenshots showing the game's own UI and complete navigation flow.

The acceptance criterion is a game that reliably reuses the platform's identity, admission, and routing. Matching the hub's visual design is optional.
