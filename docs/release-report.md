# Phase 7 release report

Status: automated release verification passed; ready for an invited pilot. Phase 7 remains open for small-group/device feedback.

## Candidate and user feedback

- Hub application baseline: `1542d375066c5c23c9adc5a543612d7f2d36cb6c`.
- Game: `34729da906ea4546b99981756803e7c995bb5c6d`.
- The owner reports successful self-play across two different browsers and confirms full lobbies reject another join. Browser names, devices, and a separate-person trial have not been supplied.

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
| User report | Two different browsers can play; full-room entry is rejected. |

Playwright is pinned at 1.65.1. These browser checks exercise independent sessions; they are not a physical-device, screen-reader, load, or formal accessibility certification. The published suite is intentionally smaller to respect hosted signup limits; the Phase 6 full published suite already passed before these release additions. No gameplay code changed in Phase 7.

## Pending human checks and decisions

- [ ] Small-group session between separate people/devices, including an actual phone.
- [ ] Record browser/device/network combinations, problems, and fixes/rechecks.
- [ ] Safari/device-specific and assistive-technology behavior; viewport automation does not establish these.
- [ ] Before wider public promotion, revisit CAPTCHA setup and the upstream development-tool fix.

No external invitations have been sent and no custom usage alerts have been created. Provider quota notifications and Dashboard review are documented; monitor usage during the invited pilot. Use the [playtest guide](playtest-guide.md) and [release runbook](release-runbook.md).
