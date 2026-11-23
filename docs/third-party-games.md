# Third-Party Game Integration

## Goal and scope

Allow the hub to include games maintained in repositories owned by other users or organizations. Repository ownership does not determine integration compatibility; hosting origin, identity handling, and the shared game contract do.

This is planned platform-expansion work. The first release continues to use the hub and tic-tac-toe sites on the same origin.

## Integration levels

| Level | Hub behavior | Game requirements |
| --- | --- | --- |
| External link | Display a catalog entry that opens the game's website. | A reviewed launch URL and catalog information. The game manages its own identity and multiplayer system. |
| Shared platform | Launch the game with the hub's guest identity and lobby membership. | Cooperation from the game maintainer and compatibility with a versioned identity, lobby, and match contract. |

External links must make it clear when a game uses a separate guest or account system. Do not imply that listing a game provides shared lobby support.

## Hosting and identity

The current session handoff relies on both sites sharing `https://kumori1313.github.io`. Another owner's GitHub Pages site has a different origin and cannot read that saved session. Matching session storage keys alone does not solve this.

Before adding a fully integrated game on another origin, choose and review an authentication handoff design. It must verify the destination, bind the handoff to the intended game and session, expire promptly, and prevent replay. Never place access or refresh tokens in launch URLs. A lobby ID identifies a room; it does not authenticate a player.

Hosting the game beneath the hub's origin is another option when its license and maintainer permit it. Treat any game hosted there as trusted code: same-origin code can access the hub's browser storage. Repository ownership can remain separate from deployment ownership.

## Shared contract to define before the second game

- Catalog fields: stable game ID, maintainer, source repository, approved launch and return URLs, player limits, integration level, and supported contract version.
- Identity: stable player ID, display-name handling, session verification, missing-session behavior, and the chosen handoff mechanism.
- Lobby lifecycle: creation, atomic joins, host privileges, start conditions, departures, presence, and cleanup.
- Match lifecycle: initialization, validated actions, synchronization, completion, interruption, and return to the hub.
- Authorization: isolate each game's data and operations, verify membership server-side, and restrict privileged credentials to trusted services. A publishable client key is not a game-specific permission boundary.
- Compatibility: version negotiation, supported client versions, migration policy, and behavior when a game is unavailable or incompatible.

## Expansion acceptance checks

- [ ] Register and launch a game whose repository belongs to another owner.
- [ ] Confirm external-link entries accurately describe their separate identity flow.
- [ ] For shared integration, verify the same player identity and authorized lobby membership through launch, refresh, and return.
- [ ] Reject expired, replayed, wrong-destination, and unauthorized handoffs.
- [ ] Verify one game cannot access another game's restricted data or actions.
- [ ] Exercise unavailable games, blocked browser storage, incompatible versions, and recovery messages.
- [ ] Document maintainer responsibilities and verify permission before redistributing code or assets.
