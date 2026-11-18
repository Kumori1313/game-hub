# Phase 7 release report

Status: automated release verification and owner-reported laptop/mobile play passed; external feedback is recorded below. Separate-person playtest details remain unconfirmed.

## Candidate and user feedback

- Hub application baseline: `1542d375066c5c23c9adc5a543612d7f2d36cb6c`.
- Game: `34729da906ea4546b99981756803e7c995bb5c6d`.
- The owner reports successful self-play across two different browsers and confirms full lobbies reject another join. The owner subsequently confirmed successful play across a laptop and a mobile device and supplied external feedback. Browser/OS/network details and whether different people played together were not specified.

## Verification record

The Chromium local suite passes all 17 scenarios, including a host plus two contenders released together for the last seat. Exactly one contender joins; the loser remains outside with a full-room message and cannot create a third seat. Backend API/concurrency/rules/expiry/retention suites pass locally. The new `test:release` command completes successfully with Firefox.

Production review confirms the organization is on Free, the scheduled cleanup job is enabled and its latest run succeeded, there are no terminal rooms beyond the retention window, and every application table has RLS. Database size was approximately 13 MB at review. There are zero outstanding declared production configuration changes. Existing advisor notices remain documented in the security review; no permissive test policy or paid resource was added.

Runtime dependency audit reports zero known vulnerabilities. The full audit still reports the development-only picomatch advisory and its dependency chain (four high-severity entries). The upstream advisory lists no patched version. This is not a clean full audit; development/build inputs remain trusted and the dev server stays on loopback. See the [security review](security-review.md).

## Browser and build evidence

| Check | Result |
| --- | --- |
| Local Chromium | All 17 scenarios pass. |
| Local Firefox | All 17 scenarios pass using Playwright’s bundled Firefox 159 fallback build on Fedora. |
| Published Chromium smoke | All four release/gameplay scenarios pass, including the competing joins and complete X/O wins/draws. |
| Builds and unit checks | Pass in both repositories. |
| Backend integration | Lobby and security/game-rule suites pass; expiry is simulated only locally. |
| Viewports/themes | 320px phone, 768px tablet, and 1440px desktop layouts; dark/light tokens, focus/validation, reduced motion, and keyboard moves checked automatically. |
| User report | Successful play in two browsers and across laptop/mobile devices; full-room entry is rejected. |

Playwright is pinned at 1.65.1. These browser checks exercise independent sessions; they are not a physical-device, screen-reader, load, or formal accessibility certification. The published suite is intentionally smaller to respect hosted signup limits; the Phase 6 full published suite already passed before these release additions. No gameplay code changed in Phase 7.

## Pending human checks and decisions

- [x] Successful play on separate devices, including laptop and mobile, reported by the owner.
- [x] External feedback recorded and prioritized for Phase 8.
- [ ] Confirm a complete session between separate people and record browser/OS/network details.
- [ ] Safari/device-specific and assistive-technology behavior; viewport automation does not establish these.
- [ ] Before wider public promotion, revisit CAPTCHA setup and the upstream development-tool fix.

No external invitations have been sent and no custom usage alerts have been created. Provider quota notifications and Dashboard review are documented; monitor usage during the invited pilot. Use the [playtest guide](playtest-guide.md) and [release runbook](release-runbook.md).

## Pilot feedback and Phase 8 follow-up

No gameplay failure was reported in the laptop/mobile test. External feedback identified three usability requests:

| Feedback | Current behavior | Proposed follow-up |
| --- | --- | --- |
| Host always moves first | Host is X; X starts, as specified for the first release. | Decouple hosting from marks. Randomly assign X for the initial game and swap X/O on rematches. |
| Playing again requires rebuilding the room | One match per lobby; both players leave and join a new room. | Offer a rematch after a completed game, keep both players in the room, and require both to accept. |
| No code-only rooms | All waiting rooms appear in public discovery. | Add a private/code-only option while retaining public lobbies. Exclude private rooms from public discovery and validate the code on the backend. |

These requests were implemented in milestone 8.1, as recorded below. Poker gameplay remains a later milestone. Host permissions should remain separate from move order; private-room access must not depend only on hiding a link in the interface.

## Milestone 8.1 completion

- Hub client/migration: `88a0f48`; tic-tac-toe: `142d753`; poker lobby preview: `1743e69`.
- All 19 browser scenarios pass locally in Chromium and Firefox, including private admission, retained rematch rooms, swapped marks, stale-round replies, and six-seat rooms.
- Four focused published scenarios pass across all three sites, covering complete tic-tac-toe games/recovery, private entry/rematches, and the poker preview with a seventh guest kept outside a full room.
- Unit checks and builds pass in all three repositories. Existing lobby/security/rule suites, new shared-room integration checks, API surface checks, and isolated legacy-data migration replay pass.
- Firefox testing exposed a discovery-refresh interaction that could replace a Join control between pointer-down/up. Both clients now preserve controls during updates, and the explicit mid-click-refresh regression passes in both engines and live.
- Migration `20261118030904` is applied. Hosted checks confirm no missing seats, RLS on every application table, private vote/helper access denied, and poker capacity six with gameplay disabled. Advisor notices remain the documented intentional guest-access/private-table/password notices; production has zero outstanding declared configuration changes.
- All three Pages deployments succeeded. No paid resource, project, or plan upgrade was added. The open development-tool advisory and wider-release CAPTCHA decision remain documented.

Poker is a lobby preview at https://kumori1313.github.io/poker/. Dealing, private cards, betting, payouts, and successive hands begin in milestone 8.2; chip/blind/table controls follow in 8.3. The poker repository initially contained its MIT license, which was retained.

## Milestone 8.2 completion

Play-money No-Limit Texas Hold’em is live at https://kumori1313.github.io/poker/. Fixed defaults are 1,000 chips per player, 10/20 blinds, and a 30-second turn clock. Configurable tables remain milestone 8.3. See the [Hold’em contract](poker-contract.md).

- Implementation commits: hub `267787f`, poker `364d0b0`, tic-tac-toe shared client `908fc26`; staged activation and upgrade checks `e1bce61`.
- All 21 browser scenarios pass locally in Chromium (1.6 minutes) and Firefox (1.8 minutes). New scenarios complete a showdown, refresh private cards, deal a successive hand, fold without exposing future cards, and continue a three-player table after host departure. Narrow-screen light mode and keyboard controls pass.
- Three focused published Chromium scenarios pass (1.1 minutes): complete tic-tac-toe games/recovery, successive heads-up Hold’em hands, and three-player betting/recovery/host transfer. These checks used independent anonymous browser sessions; they do not establish physical-device or Safari behavior.
- Eight unit checks and production builds pass in each repository. Lobby/security/shared-room suites, the local API surface check, poker rule/accounting fixtures, and isolated legacy-data upgrade replay pass. The replay preserves active tic-tac-toe gameplay and verifies disabled-before/enabled-after poker activation.
- Poker fixtures cover every hand category and kickers, wheel straights, unequal all-ins and side pots, split/odd chips, unmatched returns, heads-up button/blind rotation, short and cumulative all-ins, six-way all-ins with unique cards, chip conservation, concurrent/stale requests, unauthorized/private-card access, idempotent host-only starts, trusted timeouts, leases, and departed all-in eligibility.
- Hosted migrations `20261118222942` and `20261118223537` are applied and history matches local files. The engine deployed with the catalog disabled; activation followed successful deployment of all three compatible clients. Hosted checks confirm three new RLS tables, no guest card-table/helper access, and no unauthenticated action grant.
- Hosted advisors report the existing intentional guest-access/password notices and private tables without policies; the latter deny direct browser access. Performance findings are informational unused indexes. The local image reports its unused Vault extension version notice. No new declared production configuration differences exist. The previously documented development-tool advisory remains open.
- GitHub Pages deployments succeeded. Existing Supabase Free resources were retained; no paid project, branch, plan, or service was added.

## Poker bots follow-up

Hosts can add/remove labeled bots before starting. Humans and bots share the selected 2–6-seat capacity, supporting one human with up to five bots and mixed tables with several humans. Bots use one basic randomized strategy with their own cards and public information; configurable difficulty and active-seat replacement are not implemented.

- Implementation: hub `6409a0c`, poker `0811d3c`, tic-tac-toe shared client `cba1afa`. All three Pages deployments succeeded. Migration `20261118225058` is applied; local and hosted history agree.
- The complete local release command passes: unit checks/builds in all three repositories, lobby/security/room/poker/bot integration, legacy upgrade replay, and all 23 Chromium browser scenarios (2.1 minutes). All 23 scenarios also pass in Firefox (2.3 minutes).
- Published solo bot play, mixed two-human/two-bot play with host departure, and complete tic-tac-toe regression pass. The first mixed run hit a GitHub Pages navigation timeout before lobby creation; its focused rerun passed in 29.3 seconds without application changes.
- Local bot fixtures additionally complete a one-human/five-bot hand, check chip conservation and private cards, reject nonhost and in-game bot management, race human/bot final-seat allocation, verify no bot Auth accounts, preserve human ownership, and close code-only tables when the last human's lease expires. Closed rooms stop bot actions.
- Upgrade replay preserves and completes an active pre-bot poker hand and continues legacy tic-tac-toe. Generated human references retain Auth foreign keys; hosted checks find no incorrect references. Browser roles cannot read the bot registry, execute the shared action helper, or invoke bot management without a session. Advisor findings remain the documented guest-access/password/private-table notices; no new error findings occur.

Bot turns use existing server reads/actions and cleanup, with a two-second target delay and no external AI service. No paid project, branch, plan, or runtime was added. Physical-device and Safari bot play remain unverified; automated narrow-screen and independent-browser coverage passed. The fixed chip/blind/turn settings remain unchanged until milestone 8.3.
