# Phase 5 security review

## Scope and trust

The hub and tic-tac-toe share a Supabase project and a browser origin. A publishable key identifies the project; it grants no private-data exemption. All code hosted on `kumori1313.github.io` must be trusted because it can access the shared browser session. External games need the separate integration and handoff design planned for Phase 8.

Names and user metadata are labels, never authority. Private operations derive identity from `auth.uid()` and verify the JWT session ID against `auth.sessions`, including deleted/banned users and session expiry. The next private RPC rejects a revoked session; this does not cancel an already running transaction. Public discovery fields remain readable with an otherwise valid access token until token expiry. Presence authorization can remain cached until reconnect; its payload is advisory and contains no match state.

## Database boundaries

All application tables have RLS. Guests can read only catalog entries and public lobby summaries directly; private tables and maintenance helpers have no client grants. Public RPC wrappers use invoker privileges and call explicitly granted private dispatchers with empty search paths. Dispatchers validate membership, host actions, capacity, and lifecycle under row locks.

Review found a null-action dispatch error that could return a known room's snapshot without membership. Migration `20261117032830` rejects null actions before dispatch. A regression verifies rejection. This review does not establish whether earlier unauthorized access occurred.

`play_move(lobby, cell, revision)` accepts only a room ID, zero-based cell, and expected revision. The server assigns the stored mark, checks membership/turn/empty cell, serializes competing writes, and calculates wins and draws. Finished results survive departures and expire after seven days. The playable board remains Phase 6.

## Abuse controls and configuration

Anonymous signup is enabled; email signup is disabled. Declared Auth limits are 30 anonymous sign-ins/hour/IP, 30 sign-in/sign-up requests per five minutes/IP, and 150 token refreshes per five minutes/IP. Provider rate limits are separate from database authorization.

Successful private RPC transactions have a 600-unit per-guest, fixed-minute budget. Ordinary calls cost one; moves cost two because they return a guarded snapshot. Leave is exempt. Failed transactions roll back their counters; public discovery queries are outside this budget. Creating rooms also has a ten-per-minute per-guest limit. These controls do not prevent distributed abuse or guarantee availability.

CAPTCHA remains disabled because no provider keys are configured. Before a wider release, configure and test a supported provider or explicitly accept that risk. Do not automatically delete old anonymous accounts: a saved browser identity may still need them.

## Browser and supply chain

Both builds reject private/session credentials in the public key setting and require HTTPS for hosted backends. A generated CSP allows same-origin scripts, hashes the theme bootstrap, restricts connections to the configured backend, and blocks objects, frames, base tags, and form submission. It permits inline styles. Meta CSP cannot enforce `frame-ancestors`; GitHub Pages does not provide custom response headers. Referrers are suppressed. Names render as text.

Dependencies use exact versions and committed lockfiles. Deployment workflows pin their direct actions to commit SHAs; composite actions may have their own dependencies. Both dependency audits reported zero known vulnerabilities at review time.

## Verification and operations

Run against local Supabase only:

```bash
npm test
npm run build
npm run test:lobbies
npm run test:security
GAME_SITE_DIR=/absolute/path/to/tic-tac-toe npm run test:e2e
```

Build the game before the browser suite. Never rebuild either `dist` directory while the suite serves it. Integration scripts use local administrative fixtures to exercise expiry, revocation, budgets, grants, legal results, and competing actions; they refuse hosted targets.

Review Supabase Dashboard usage and Auth/Realtime logs during testing and daily after opening access. Check sign-in failures, growth in anonymous users, database size, Realtime messages, and peak connections. Use [operator queries](../supabase/monitoring.sql) for aggregate room/session cleanup checks. No custom usage alert or paid monitoring service has been provisioned. Supabase provides quota emails/grace periods; Free projects can be restricted when limits are exceeded. Keep the project on Free and review current quotas before expanding access.

Deploy forward migrations before compatible site builds. Do not edit applied SQL. Roll back site commits if needed; database changes require a reviewed forward migration, preserving authorization checks and finished results.

References: [anonymous sign-ins](https://supabase.com/docs/guides/auth/auth-anonymous), [Auth limits](https://supabase.com/docs/guides/auth/rate-limits), [cost control](https://supabase.com/docs/guides/platform/cost-control), [Realtime usage](https://supabase.com/docs/guides/platform/manage-your-usage/realtime-messages).

## Advisor findings

Hosted warnings remain for intentional guest-readable catalog/summary/member Presence policies and extension-owned cron policies. The authenticated role lacks usage on the unexposed cron schema. Leaked-password protection is disabled; no permanent users existed at review and email signup is disabled. The local Docker image also reports an older Vault extension; this application does not use Vault. Review image/extension upgrades separately before using it. These notices are not a clean security certification.

## Completion record

Both repositories pass unit checks and production builds. The local lobby and security integration suites pass, including all eight winning lines, draws, ninth-move wins, duplicate/concurrent requests, revoked sessions, and denied private operations. All 13 browser scenarios pass locally and on the published GitHub Pages sites. Both Pages deployments succeeded. Hosted function definitions and grants match the reviewed boundaries, every application table has RLS, and production has zero outstanding declared configuration changes. Existing advisor notices and deferred controls are listed above. No paid resources were added.

## Dependency follow-up (Phase 6)

A later audit reports [GHSA-fc5q-39xc-vjpf](https://github.com/advisories/GHSA-fc5q-39xc-vjpf) in development-only picomatch and its Vite dependency chain. The advisory currently lists no patched version. The published static game does not include this build dependency or accept user-supplied glob patterns. Keep the development server on loopback, use trusted build inputs, and review upstream fixes before the Phase 7 release. The earlier zero-vulnerability audit is a historical result, not the current audit status.

## Milestone 8.1 extension

The [version 2 room contract](shared-room-contract.md) adds code-only rooms and private rematch votes without client table grants. Invalid code replies commit request-budget usage. Match-bound moves and round-aware snapshots reject stale actions across rematches; host privileges are independent of randomly assigned marks. The migration preserves first-round legacy clients and was replayed against existing-room fixtures before production deployment. Poker has no dealing or hidden-card state yet; start is rejected by the backend.

## Hold’em additions (8.2)

Poker cards, deck order, chip commitments, and hand history live in three private RLS-enabled tables without browser grants. A session-validated internal definer implements the public invoker RPC; helpers are not executable by guest roles. Room locks, exact hand/revision checks, bounded integer bets, and chip conservation protect mutations. Snapshots expose only the caller's hole cards before showdown, then nonfolded showdown hands; folded cards and future community cards remain private. Presence never transports cards or game state.

The engine is deployed before the new client; a separate catalog migration enables new hands afterward. Disabling that flag stops new starts/deals while allowing active hands to finish. The old room-start endpoint cannot launch unsupported poker gameplay. Local fixtures cover unauthorized actors/grants, concurrent/stale moves, and card isolation. No payment, withdrawal, or real-money features are implemented.
