# Repository Guidelines

## Project structure

Game Hub is the discovery site for small multiplayer browser games. It is published at `https://kumori1313.github.io/game-hub/`, and every game lives in its own repository and route:

| Game | Repository | Route | Lobby integration |
| --- | --- | --- | --- |
| Tic-Tac-Toe | `Kumori1313/tic-tac-toe` | `/tic-tac-toe/` | Shared identity and lobbies |
| Poker | `Kumori1313/poker` | `/poker/` | Shared identity and lobbies |
| Relay Room | `Kumori1313/Horror-Friendslop`, published by `Kumori1313/relay-room` | `/relay-room/` | Shared identity and lobbies, browser-hosted match |
| Counter-Attack Web | Another owner's site | Embedded from its own origin | Game Hub lobbies through a message port |

- `src/`: the hub page. `game-catalog.js` holds the reviewed launch entries; `guest.js` and `guest-ui.js` handle guest identity; `cs-web-room.js` and `cs-web-relay.js` run Counter-Attack Web's lobby and relay.
- `supabase/`: the single shared backend for the hub and every game. It holds `config.toml`, the SQL migrations, Realtime channel policies, and monitoring queries. Games must not create a second backend.
- `scripts/`: backend checks, API integration tests, the release check, `security-policy.mjs` (CSP and environment validation), and `serve-session-test.mjs`, which serves the hub and game builds under one origin on port 4175.
- `tests/`: Node unit tests at the top level; Playwright suites in `tests/browser/`.
- `docs/`: the game development guide, contracts (lobby, gameplay, shared room, poker), per-game docs, the release runbook and report, the security review, and plans such as `third-party-games.md`.
- `multiplayer_game_hub_roadmap.md`: milestones with checkbox progress. Preserve its headings and checkbox format.

`dist/`, `test-results/`, and `UI-Ideas/` are ignored.

## Build, test, and development

Node 22.12 or later. Copy `.env.example` to `.env.local` and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`. These are bundled into browser code; never use a secret or service-role key.

```sh
npm ci
npm run supabase:start      # local Supabase in Docker (needed by most checks)
npx supabase migration up   # apply new migrations
npm run dev                 # http://127.0.0.1:5173/game-hub/
npm run build               # dist/ with the /game-hub/ base path
npm test                    # Node unit tests: guest validation, security policy
npm run check:backend       # local anonymous sign-in and restricted Data API
npm run test:lobbies        # also test:rooms, test:security, test:poker, test:bots, test:settings, test:upgrade
npm run test:e2e            # all Playwright suites; needs GAME_SITE_DIR (and the other game checkouts built)
npm run dev:relay           # hub plus Relay Room (../Horror-Friendslop/dist) on port 4175
npm run test:relay          # Relay Room acceptance tests; needs port 4175 free
npm run test:release        # full release check; set GAME_SITE_DIR and POKER_SITE_DIR
```

To check the published sites instead, set `E2E_BASE_URL=https://kumori1313.github.io`. Browser tests create anonymous users in whichever backend they target, so use local Supabase for routine work. A successful build is not gameplay validation.

## Coding style

ES modules, two-space indentation, single quotes in JavaScript, and kebab-case file names. Dependencies are pinned and lockfiles are committed. There is no formatter or linter. For Markdown, use descriptive headings, short paragraphs, fenced code blocks for commands, and relative links.

## Testing

Node's built-in runner covers unit tests; Playwright covers browser flows in Chromium (set `E2E_BROWSER=firefox` for a second engine). Before a release, run `npm run test:release` against local Supabase and record the browser engine and exact commits of every repository in the release report. The Relay Room suite imports the game's own route planner from the sibling checkout (`RELAY_SITE_DIR`, default `../Horror-Friendslop`).

## Commits and pull requests

Short, imperative subjects that name the change, such as `Default private lobbies to four-character codes`. Pull requests describe the change, link the roadmap milestone, and record validation. Include screenshots for interface changes, and for game integrations include the game ID, route, player limits, and licenses.

## Deployment

GitHub Actions builds pull requests and deploys `main` to GitHub Pages. The Pages build reads the `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` Actions variables; listing flags such as `VITE_ENABLE_RELAY_ROOM` control which games appear. See `docs/release-runbook.md`.

## Security

Treat display names as untrusted text and render them with `textContent`. Identity is the Supabase guest UUID, never a name. Keep backend access deny-by-default, verify membership server-side, and keep privileged credentials out of commits and browser code. Same-origin game code can read the hub's browser storage, so only trusted code may be hosted on the hub's origin. See `docs/security-review.md`.
