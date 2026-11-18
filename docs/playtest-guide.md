# Small-group playtest

The automated checks cover rules and races; this pilot checks real devices, networks, and usability. The owner has already reported successful self-play in two different browsers and rejection from full lobbies. That result is recorded separately from multi-person/device feedback.

## Suggested session

Share https://kumori1313.github.io/game-hub/ with two or three people you know. Use at least one phone and one desktop on separate devices; include Safari if available. Start with a small invited group while CAPTCHA and the development-only dependency advisory remain open. No invitations have been sent automatically.

1. Each person enters a name. One hosts; another joins. Confirm the same two names and X/O marks appear.
2. Play one win and one draw. Confirm both players see the same turn, marks, winning cells, and result. Return to the hub, then create/join a fresh room.
3. A third person tries joining the full room. They should remain outside it. The automated simultaneous-join test separately holds two contenders' join requests, releases them together, and verifies exactly one gets the host's remaining seat.
4. During another game, refresh one browser. Confirm the board is restored. Briefly disconnect/reconnect its network. It should recover without duplicating a move.
5. Leave an active match and accept the confirmation. The remaining player should see an interrupted match without a winner. For a timeout test, close every tab for one player and wait roughly 90 seconds plus up to one cleanup minute.
6. On the phone, try both themes, portrait/landscape, and normal browser zoom controls. On desktop, try Tab and Enter/Space. Note cramped controls, hard-to-read text, confusing focus, or unclear messages.

Do not clear browser data unless intentionally testing loss of the saved guest identity. Switching devices does not carry a guest session to that device.

## Record feedback

Use [Playtest feedback](https://github.com/Kumori1313/game-hub/issues/new?template=playtest.yml) or send the same details to the project owner:

- Browser/version, device/OS, and whether players used different networks.
- What each player did, expected behavior, actual behavior, and visible error text.
- Whether both boards and results agreed; screenshots if useful.
- Severity: unable to finish, wrong state/result, layout/accessibility, or successful test.

Never include Auth tokens, private keys, or browser storage exports. Display names and room links are optional; reproduction steps are more useful.

## Completion gate

Record at least one successful complete session between different people/devices, any reported problems, and the fixes/rechecks in the release report. Wrong results, extra seats, unauthorized actions, or inability to finish block wider release. Review lesser issues explicitly rather than assuming silence means success. Revisit CAPTCHA and upstream build-tool fixes before a wider public invitation.
