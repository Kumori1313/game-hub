# First Release: Tic-Tac-Toe

This specification completes Phase 1 of the [development roadmap](../multiplayer_game_hub_roadmap.md). Tic-tac-toe is the selected first game. The remaining decisions below are initial implementation defaults that can be revised before development.

## Release scope

Guests can enter a display name, choose tic-tac-toe, create or join a public lobby, play one match, and return to the hub. The hub and game use separate GitHub Pages repositories and share Supabase guest identity and Postgres lobby data.

The release includes two-player matches, live lobby updates, a host-controlled start button, connection feedback, and a shared final result. Private invitations, spectators, chat, scores, matchmaking, host transfer, computer opponents, and rematches are deferred. To play again, create or join a new lobby.

## Game rules

- Exactly two players play on an initially empty 3 × 3 board.
- The lobby creator is the host and plays X; the joining player plays O. X moves first.
- Players alternate placing their mark in one empty cell. Only the current player can move. Submitted moves wait for confirmation before another move is enabled.
- Three matching marks in a row, column, or diagonal win. Check for a win before declaring a draw when all nine cells are occupied.
- A win or draw ends the match and locks the board. Both players see the same result and winning line, if any.
- Leaving or losing a player during an active match aborts the match; it awards no win or loss.

## Guest journey

1. Enter a name on the hub. Trim surrounding whitespace; accept 1–24 Unicode code points of printable text, excluding control characters. Names need not be unique and are rendered as text.
2. Continue as an anonymous guest and choose the tic-tac-toe card. Returning guests can reuse or change their name before joining a lobby.
3. Browse public lobbies or select **Create lobby**. Generate a lobby label from the host's name; use a unique lobby ID internally.
4. Join a waiting lobby with an open seat. The room shows both players and identifies the host. Only the host can start, with two connected players present.
5. Starting locks membership and navigates both players to the game with the lobby ID. Verify membership on arrival; a missing identity or invalid lobby returns the guest to entry or discovery with an explanation.
6. Play to a win, draw, or interruption. Show the result and **Return to hub**. Finished lobbies accept no new players.

## Lobby and connection behavior

| Event | Required behavior |
| --- | --- |
| Second player joins | Show 2/2 and disable further joins; resolve competing joins atomically. |
| Lobby full or already started | Reject the join with an explanation and refresh the list. |
| Non-host leaves before start | Free the seat and disable Start until another guest joins. |
| Host leaves before start | Close the lobby and return the other guest to discovery. |
| Either player leaves during play | Abort the match and show the reason to the remaining player. |
| Connection is lost | Disable local actions and show reconnecting. Once a trusted backend operation confirms the player’s membership lease expired, close a waiting host's lobby, free a waiting guest's seat, or abort an active match. |
| Refresh or hub-to-game navigation | Reattach to the same membership if still valid. If disconnect cleanup already ended the session, explain the interruption; never recreate or resume a terminal match. |
| Match ends normally | Keep the final board visible to remaining members; hide the lobby from joinable discovery. Returning to the hub leaves membership without changing the recorded result. |

The first release has no guaranteed reconnection grace period. Realtime Presence provides connection indicators, not authoritative database cleanup. Authenticated heartbeats and server-side lease expiration checks determine durable departures; choose the timeout and cleanup executor in Phase 4. Connection cleanup must account for multiple connections belonging to the same guest: one connection closing must not mark a guest offline while another is attached. Stale lobbies must be excluded from joinable discovery; exact expiration and storage cleanup mechanisms will be specified with the shared data model in Phase 4.

## Screen sketches

These are layout sketches, not a final visual design. Bracketed labels represent controls.

```text
HUB / ENTRY
Game Hub
Display name: [____________]
[Continue]
After entry: Playing as Alex [Change name]
Tic-Tac-Toe · 2 players [Browse lobbies]

LOBBY LIST
Tic-Tac-Toe                    [Back to hub]
[Create lobby]
Alex's lobby     1/2 Waiting   [Join]
Sam's lobby      2/2 Full      [Join disabled]
No open lobbies? Create one.

WAITING ROOM
Alex's lobby · 2/2
Alex (you) · Host · X · Connected
Sam              · O · Connected
[Start game: host only]  [Leave lobby]
With one player: Waiting for another player…

GAME
Tic-Tac-Toe · You are X · Opponent: Sam (O)
Your turn / Waiting for Sam / Reconnecting…
          1   2   3
      1 [X] [ ] [O]
      2 [ ] [X] [ ]
      3 [ ] [ ] [ ]
[Leave match]
When finished: You won / Sam won / Draw / Match interrupted
[Return to hub]
```

All screens need loading, empty, and actionable error states where applicable. Confirm leaving an active match because it ends play for both guests.

## Accessibility and mobile goals

- Support keyboard-only entry, lobby actions, and moves with visible focus and a logical focus order. Use native labeled buttons and inputs.
- Label board cells with row, column, and content; announce turn changes, results, and connection changes to assistive technology.
- Distinguish players and states using text and X/O symbols as well as color. Keep text readable and controls comfortably sized, targeting at least 44 × 44 CSS pixels.
- Support a single-column layout at 320 CSS pixels without horizontal scrolling. Keep the entire board usable on a phone and support browser zoom.
- Keep validation errors beside the relevant input and preserve entered text when a request fails.

## First-session acceptance checklist

- [ ] Two independent browser sessions enter names and reach the same public lobby.
- [ ] The host can start only when both players are connected; a third guest cannot join.
- [ ] Both sessions agree on marks, turns, legal moves, and the final board for a win and a draw.
- [ ] Out-of-turn moves, occupied cells, duplicate submissions, and moves after completion are rejected.
- [ ] Leaving, connection loss, refresh, and a failed join follow the policies above with clear feedback.
- [ ] Both players can return to the hub and begin a new session.
- [ ] The complete flow works using a keyboard and on a narrow mobile viewport.

These checks define future implementation acceptance; they have not yet been executed against an application.
