# Release operations

## Local verification

Use Node 22.12+, Docker, and the pinned npm dependencies in both repositories. Start local Supabase from the hub and apply migrations with `npx supabase migration up`. Both `.env.local` files must contain the same loopback Supabase URL and publishable key. Never use a hosted target for database integration tests.

```bash
npm ci
npm run supabase:start
npx supabase migration up
npx playwright install chromium firefox
GAME_SITE_DIR=/absolute/path/to/tic-tac-toe POKER_SITE_DIR=/absolute/path/to/poker npm run test:release
E2E_BROWSER=firefox GAME_SITE_DIR=/absolute/path/to/tic-tac-toe POKER_SITE_DIR=/absolute/path/to/poker npm run test:e2e
```

Install the game's locked dependencies with `npm ci` in that checkout too. The release command validates local settings, tests/builds both apps, runs backend permissions/rules/concurrency/cleanup checks, then serves both builds for browser tests. It stops on failure. Docker group membership is required by the local administrative fixtures. Builds must finish before the test server starts; do not rebuild while browser tests run. Different dev-server ports do not share saved sessions; the test server serves both project paths on one origin.

## Production deployment and verification

Keep Supabase on Free and Pages on the existing public repositories. Do not enable paid add-ons. Before expanding access, review the Dashboard usage page and current limits; Free service restrictions remain possible. No custom email threshold alert is provisioned. See the [security review](security-review.md) for Auth budgets, CAPTCHA, provider notices, and the open development-only dependency advisory.

1. Review the code diff, tests, and migration history. Preserve unrelated working changes.
2. Preview production settings with `npx supabase config diff --workdir config/production --remote=ivjznofekldhkocheija`. Undeclared properties are intentionally left unchanged. Apply only reviewed settings.
3. Apply new versioned migrations, if any, with `npx supabase migration up --remote=ivjznofekldhkocheija`. Never edit an applied migration or introduce temporary permissive policies.
4. Push reviewed site commits to their `main` branches. Confirm **Deploy GitHub Pages** succeeds in both repositories. Both Actions variables must target the same hosted project; private credentials are forbidden.
5. Run published browser smoke tests, keeping anonymous signup volume below the provider's per-IP hourly limit:

```bash
E2E_BASE_URL=https://kumori1313.github.io npm run test:e2e -- tests/browser/release.spec.js tests/browser/gameplay.spec.js
```

Record commit IDs, test counts, browser engines, and unresolved limitations in the [release report](release-report.md). Published smoke tests create anonymous Auth users; room cleanup does not delete those users. Repeated full hosted suites can exhaust signup limits. Use local testing for repeated regression runs.

## Rollback and incidents

Revert the faulty source commit in the affected repository, push the revert, and confirm Pages deployment. This produces a reviewable rollback without rewriting history. Check both sites if guest or theme code changed. A site rollback does not revert SQL: use a reviewed forward migration that preserves identity checks and retained results. Compatible older site commits must understand the current database contract.

For a serious gameplay problem, stop the pilot and record the affected commits, visible errors, and steps. Keep credentials out of reports. Review Auth/Realtime logs and the read-only [operator queries](../supabase/monitoring.sql), rather than disabling access policies to make a test pass.

## Data and monitoring

Display names are untrusted labels; guest UUIDs authorize actions. Browser storage holds the guest session, shared across both trusted Pages project paths. Clearing storage loses that saved identity. There are no passwords, scores, chat, or account-recovery features in this release.

Connection leases last 90 seconds and are renewed per tab every 15 seconds. Another connected tab keeps the seat alive. A trusted cleanup job runs every minute; it frees an expired waiting guest's seat, closes a departed host's room, and interrupts an active match without awarding a result. Completed results remain unchanged on departure. Closed/finished rooms and their dependent records are retained seven days. Request-budget rows expire after two inactive hours. Anonymous Auth users persist until deliberate administrator cleanup; do not blindly delete users whose saved identity may still be in use.

During the pilot, review usage daily and after each test session: anonymous sign-ins/failures, database growth, Realtime message/connection usage, and successful cleanup jobs. If usage spikes, stop inviting testers and investigate before increasing limits. Fine-grained custom budget alerts and CAPTCHA have not been configured.

## Troubleshooting

| Symptom | Check/action |
| --- | --- |
| Signup rate limit | Wait for the provider bucket to refill; reuse existing guest identities. Use local tests for repeated runs. |
| Lobby disappears | Check host departure/lease expiry. A stale room must not remain joinable. |
| Move not confirmed | Let the snapshot refresh; never replay automatically. Check connection and server logs if it persists. |
| Session ended | Enter a name again. Revoked sessions cannot renew private membership leases. |
| Missing assets or 404 | Check both Pages deployments and `/game-hub/` / `/tic-tac-toe/` Vite base paths. |
| Backend unavailable | Check Supabase project status and usage, then the browser's project URL. Never substitute a secret key. |
| Docker permission denied | Activate the existing Docker group (`sg docker -c 'command'`) or sign in again; avoid running npm with sudo. |

## Third site and room contract

Milestone 8.1 adds the poker checkout/build to release checks and the `/poker/` Pages path. Build/test all three repositories with matching local settings. Include `tests/browser/shared-rooms.spec.js` in focused published checks. The [version 2 room contract](shared-room-contract.md) specifies private codes, retained rematch rooms, capacity, migration compatibility, and stale-round protection. No paid service is required by this extension.
