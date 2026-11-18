# Tic-tac-toe gameplay (Phase 6)

## Player flow

Enter a guest name, open tic-tac-toe, then create or join a public lobby. The host plays X, the guest plays O, and only the host starts. X goes first. Select an empty cell on your turn; the board locks until the server confirms the move. Names identify players visually; their stored guest UUIDs authorize actions.

Three matching marks in a row, column, or diagonal win. The final board highlights the three winning cells. A full board without a winner is a draw; a ninth-move win takes priority. Both players see the same board and result. Completed matches cannot restart. Use **Back to lobbies** or **Back to Game Hub**, then create/join another room for a fresh game.

Leaving during play requires confirmation and interrupts the match for both players, without a winner. Closing a tab or losing the network uses the existing 90-second connection lease and scheduled cleanup. A different connected tab can keep a player's seat alive. Finished results remain unchanged when someone leaves and are retained for seven days, then deleted with their lobby. See the [lobby contract](lobby-contract.md).

## State and synchronization

The game calls `play_move(p_lobby, p_cell, p_revision)`: a lobby UUID, zero-based cell (0–8), and expected board revision. The server owns marks, turns, board contents, win/draw detection, and timestamps. Transactions lock the room and match. The server rejects nonmembers, stale revisions, occupied cells, out-of-turn actions, and terminal matches. No private match tables are exposed to clients.

The interface renders confirmed snapshots, never speculative marks. One pending move blocks further clicks. RPC requests time out after 12 seconds. A lost reply triggers a state check instead of an automatic resend: the original move may have committed. A delayed move reply or snapshot cannot overwrite a newer revision or regress a terminal lifecycle. Errors leave the last confirmed board visible; actions resume after a successful connection check.

Visible active matches poll guarded snapshots once per second; waiting rooms and hidden tabs poll every four seconds. Each tab renews its lease every 15 seconds. Presence is advisory and public-summary changes also trigger refreshes. Finished/interrupted rooms stop regular polling and heartbeats. Their URL retains the room ID, so refresh can show the final board while membership remains. No new Realtime broadcast policy, database migration, service, or paid resource is required.

## Presentation and access

The playable board takes the main column during matches; the decorative preview is hidden. X/O symbols and text distinguish marks in dark and light themes. Native buttons support Tab and Enter/Space, visible focus, and row/column/content labels. Turn and connection messages use live status regions without replacing unchanged text. Winning cells have a border and an accessible label as well as color. The board remains usable at 320 CSS pixels with controls at least 44 pixels wide/high.

## Verification

Build both sites before running the shared browser suite:

```bash
npm test
npm run build
npm run test:security
GAME_SITE_DIR=/absolute/path/to/tic-tac-toe npm run test:e2e
```

Run the game's `npm test` and `npm run build` in its repository too. Never rebuild while the test server serves `dist/`. Backend integration tests refuse hosted URLs. They cover all eight winning lines, O wins, draws, ninth-move wins, invalid/duplicate/concurrent actions, session revocation, and immutable results. Browser tests exercise both players through X/O wins and a draw, keyboard entry, refresh, final-result retention, a fresh match, narrow/light layouts, pending double clicks, late/lost replies, offline recovery, and interrupted play.

For a deployment, publish reviewed game code and run the same browser suite with `E2E_BASE_URL=https://kumori1313.github.io`. This creates anonymous test identities and rooms on the hosted project; keep runs below Auth rate limits. Rooms follow normal cleanup/retention; test identities remain until an operator removes them.

## Completion record

Both repositories pass unit checks and builds. Local server authorization, game-rule, and concurrency tests pass. All 15 browser scenarios pass locally and on the published sites, including complete keyboard-operated draw/O-win games and 12-second request timeout recovery. Desktop dark and 320-pixel light screenshots were reviewed. The game deployment succeeded at commit `34729da`. No database migration or paid resource was added. Physical-device testing and small-group feedback remain part of Phase 7.

## Milestone 8.1 changes

New rooms randomly assign X independently of the host. After completion, both connected players can accept an in-room rematch; the next round swaps marks and preserves the room. Finished rooms continue heartbeats/polling while players decide. Moves now use `submit_move` with the current match UUID; delayed requests and snapshots cannot affect a subsequent round. Prior one-match-only behavior above describes Phase 6. See the [version 2 contract](shared-room-contract.md).
