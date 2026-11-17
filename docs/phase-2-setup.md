# Phase 2 Setup

## Repository layout

The hub owns `supabase/config.toml`, future migrations, and the platform plan. Each repository owns its own `src/`, `scripts/`, `vite.config.js`, package manifest, lockfile, and Pages workflow. Game-specific code lives only in [tic-tac-toe](https://github.com/Kumori1313/tic-tac-toe).

## Local Supabase

Install Docker Engine and grant your user access to its socket. Node.js 22.12+ and npm are required. From the hub:

```bash
npm ci
npm run supabase:start
npm run supabase:status
```

The existing generated configuration is preserved with anonymous sign-ins enabled, local app URLs configured, empty seed paths, and automatic Data API exposure disabled. Phase 2 began with no application tables; apply the versioned Phase 4 migrations for the current lobby schema. Future migrations must explicitly grant access, enable RLS on exposed tables, and provide policies before exposing user data.

Copy `.env.example` to `.env.local` in both repositories. Set the local project URL (`http://127.0.0.1:54321`) and the publishable key from Supabase status. A legacy local anon key is acceptable if the local CLI does not provide a publishable key. Never copy the secret/service-role key. Do not commit `.env.local` or redirect the complete status output into frontend environment files.

Run `npm run check:backend` in each repository to verify anonymous sign-in, validated guest identity, and the restricted lobby Data API. The check only accepts loopback backends. Each run leaves a signed-out anonymous user in the local development database.

Start the hub with `npm run dev` on port 5173 and the game on port 5174. Both use `127.0.0.1`; the different ports have separate session storage. Test shared-origin handoff on published Pages paths when Phase 3 implements guest entry. Stop the backend with `npm run supabase:stop`.

## Hosted Supabase

The shared hosted project is **game-hub**, owned by **Kumori1313’s Org**, in **us-east-1** (quoted at $0/month when created). Its reference is `ivjznofekldhkocheija`, its API URL is `https://ivjznofekldhkocheija.supabase.co`, and its [dashboard](https://supabase.com/dashboard/project/ivjznofekldhkocheija) manages Auth and Postgres. Anonymous sign-ins are enabled and the two Pages URLs are configured. Both GitHub repositories have their hosted URL and publishable key set as Actions variables. Local `.env.local` files continue to target the local backend.

Set these GitHub Actions repository variables in **both** repositories:

- `VITE_SUPABASE_URL`: the hosted project API URL.
- `VITE_SUPABASE_PUBLISHABLE_KEY`: its publishable key.

Never use local loopback values in a production deployment. Keys prefixed `sb_secret_` and legacy service-role JWTs must never be supplied to Vite. Management access tokens and database passwords stay outside the repository and browser bundle.

The CLI is pinned to v3.1.0. Local and hosted configuration are separate: enabling anonymous sign-ins locally does not enable them in the hosted project. Inspect `npx supabase <command> --help` before hosted operations; v3 uses explicit remote targets and confirmation for hosted writes. Version migrations here before applying them to production.

## GitHub Pages

Both repositories use Actions as the Pages build source. Pushing `main` runs `npm ci`, builds the site, uploads `dist/`, and deploys it. Pull requests build without deploying. Project base paths are `/game-hub/` and `/tic-tac-toe/` respectively.

- Hub: https://kumori1313.github.io/game-hub/
- Game: https://kumori1313.github.io/tic-tac-toe/

A landing page can deploy before hosted environment variables exist. It will not create a Supabase client until both variables are configured. Change variables and re-run the workflow to rebuild their values into the site.

For rollback, revert the problematic source commit and push the revert, which redeploys the previous behavior. Database migrations require a separate reviewed recovery plan; reverting a site does not revert the database.

## Troubleshooting

- **Docker permission denied:** log out and back in after group changes; restart the coding session too. `sg docker -c 'npm run supabase:start'` activates existing membership for one command.
- **Root-owned `supabase/.temp/start-secrets`:** repair only that generated directory using `sudo chown -R "$USER:$(id -gn)" supabase/.temp/start-secrets`. Do not run npm or Supabase with sudo.
- **Missing browser backend:** check the two environment variables, then restart Vite or rebuild Pages.
- **Anonymous sign-in disabled:** enable it in the correct local configuration or hosted project. Restart the local stack after configuration changes.
- **404 or missing assets:** verify Pages uses Actions and Vite's base matches the repository path.

## Verified setup

The current backend checks verify local anonymous sign-in, identity, and the restricted lobby Data API. Hosted anonymous sign-in and an authenticated PostgREST request also passed. Hosted OpenAPI discovery requires a secret key; use ordinary API requests for browser-safe connectivity checks. Phase 2 verified an empty hosted `public` schema; Phase 4 adds the [restricted lobby schema](lobby-contract.md) and documents its advisor review. One-time hosted smoke tests created signed-out anonymous users.

The reviewed production configuration is tracked separately at `config/production/supabase/config.toml` to avoid pushing development defaults to production. Inspect changes before applying:

```bash
npx supabase config diff --workdir config/production --remote=ivjznofekldhkocheija
npx supabase config push --workdir config/production --remote=ivjznofekldhkocheija
```

Future application tables need versioned SQL migrations with explicit grants and RLS policies. Phase 2 introduced no application schema or privileged database functions; those are now versioned by Phase 4.

## Scope

This phase sets up deployable pages and backend development configuration. Guest entry, lobby tables, game state, RPC authorization, and concurrency tests belong to later roadmap phases. Phase 1 acceptance checks remain unexecuted until those features exist.
