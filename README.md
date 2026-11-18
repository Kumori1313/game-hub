# Game Hub

The discovery hub for small multiplayer games. Tic-tac-toe lives in a separate [repository](https://github.com/Kumori1313/tic-tac-toe). Guest entry is implemented: enter or change a display name, restore your anonymous session, and navigate between the hub and tic-tac-toe. Public lobbies and waiting rooms are implemented in the game site. Two guests can play complete tic-tac-toe matches with synchronized turns and results.

## Local development

Requires Node.js 22.12+ and npm. Use Node 22 for parity with CI.

```bash
npm ci
cp .env.example .env.local
npm run dev
```

Open `http://127.0.0.1:5173/game-hub/`. Start both repositories to follow their local links. Production links target the matching GitHub Pages project paths.

## Backend setup

The hub owns the single shared `supabase/` configuration and future SQL migrations. Do not create a second backend for the game. See [Phase 2 setup](docs/phase-2-setup.md) for Docker, local credentials, hosted setup, and troubleshooting.

Configure `.env.local` with `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`. These values are bundled into browser code; never supply a secret/service-role key. Both apps use the `game-hub-auth` session storage key. Local dev ports have separate browser storage; shared-origin session handoff must be verified with both production paths.

## Commands and validation

- `npm run dev`: start the local Vite server.
- `npm run build`: produce `dist/` with the `/game-hub/` base path.
- `npm run preview`: serve the production build locally.
- `npm test`: run guest validation and session-service checks with Node’s built-in test runner.
- `npm run check:backend`: verify local anonymous sign-in, identity, and restricted lobby Data API. Creates one local guest, then signs out; no hosted requests are allowed.

Guest behavior is tested with Node’s built-in runner; no coverage threshold is configured. Local API integration tests cover lobby/move authorization, all winning lines, draws, duplicate submissions, and concurrent writes. Never treat a successful build as gameplay validation.

## Deployment

GitHub Actions builds pull requests and deploys `main` to GitHub Pages. Select **GitHub Actions** as the Pages source. Add repository Actions variables `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` for the hosted project, using identical values in both repositories. Without them the landing page still builds, with no backend client. Re-run deployment after changing variables.

Published URL: https://kumori1313.github.io/game-hub/

## Conventions

Use ES modules, two-space indentation, single quotes in JavaScript, and kebab-case file names. Keep source in `src/` and verification scripts in `scripts/`. Dependencies are pinned and lockfiles committed. No formatter or linter is configured.

## Guest identity contract

Both sites use the same Supabase project and `game-hub-auth` browser storage key. Display names are trimmed, limited to 24 Unicode code points, and saved in Auth `user_metadata.display_name` alongside the guest UUID. Names are untrusted labels, never authorization claims. User-visible names are rendered with `textContent`.

Production navigation uses the two project paths on the same origin, so the session survives navigation. Different local dev ports do not share browser storage. Clearing site data or switching devices loses the guest identity; a missing session prompts for entry again. Network failures preserve saved sessions and entered names.

## Browser verification

Install Chromium once with `npx playwright install chromium`. Start local Supabase, configure the same local backend in both repositories, and build each site. Then run:

```bash
GAME_SITE_DIR=/absolute/path/to/tic-tac-toe npm run test:e2e
```

The test server hosts both builds under one origin to exercise production-style session handoff. The suite covers name validation, safe text rendering, identity continuity, duplicate display names, connection failures, offline recovery, missing sessions, keyboard input, and a 320px viewport. Screenshots are written to `/tmp/game-hub-phase3.png` and `/tmp/tic-tac-toe-phase3.png`.

To verify deployed sites, use `E2E_BASE_URL=https://kumori1313.github.io npm run test:e2e`. Browser tests create anonymous test users in the target backend; use local Supabase for routine work. Both builds must use the local project URL for local verification.

## Visual design and themes

The shared visual language uses original SVG artwork (`public/art/playfield.svg`), a plum mission banner, editorial typography, and a desktop side illustration. Semantic color tokens in `src/style.css` support both themes. Dark is the first-visit default, even when the operating system prefers light. The navigation toggle saves `dark` or `light` under the origin-wide `game-hub-theme` key, which is independent of guest identity.

A small inline head script selects the saved theme before paint. If storage is unavailable, dark remains the default and the toggle still works for the current page. `src/theme.js` also synchronizes other tabs. `src/illustration.js` updates the preview only in response to scroll or guest progress and while visible; reduced-motion mode displays a static final board. There is no autonomous animation loop. The playable board lives in the game repository; its decorative preview is hidden during matches.

The hub’s [component guide](https://github.com/Kumori1313/game-hub/blob/main/docs/ui-components.md) documents matching styles, future screen sketches, and verification. Keep shared presentation files aligned across repositories until they are extracted into a package.

## Public lobbies

The tic-tac-toe site supports public discovery, creating/joining/leaving two-player rooms, host-only start, refresh recovery, connection feedback, and interruption. Started matches show a synchronized board with server-validated turns and results. See the [lobby contract](https://github.com/Kumori1313/game-hub/blob/main/docs/lobby-contract.md) for API permissions, the 90-second lease, scheduled cleanup, and the seven-day retention policy.

Apply local migrations with `npx supabase migration up` before backend/browser tests. `npm run test:lobbies` exercises real local APIs and uses the local Docker database to force lease expiry and test cleanup. It never targets a hosted project. Migrations and scheduled maintenance are versioned in `supabase/migrations/`.

## Backend security

See the [Phase 5 review](docs/security-review.md) for authorization boundaries, move validation, request limits, deployment, monitoring, and remaining release decisions. Run `npm run test:security` against local Supabase to verify them. The [Phase 6 gameplay contract](docs/gameplay-contract.md) covers the playable board, synchronization, and recovery.

## Release verification

Use `GAME_SITE_DIR=/absolute/path/to/tic-tac-toe npm run test:release` with local Supabase to check both repositories and the full flow. Set `E2E_BROWSER=firefox` for a second browser engine. See the [release runbook](docs/release-runbook.md), [verification report](docs/release-report.md), and [small-group playtest guide](docs/playtest-guide.md).
