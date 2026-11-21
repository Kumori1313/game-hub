# Counter-Attack Web

Game Hub opens a two-seat Counter-Attack Web lobby at `/game-hub/?game=cs-web`. Create a public or code-only lobby, wait for another guest, and start the match. Both players then choose **Open match**. The original owner’s site serves the game. [Counter-Attack Web on GitHub Pages](https://vortezler.github.io/Counter-Attack-Web/)

The creator plays CT and runs the simulation. The other player plays T. Eight bots fill the remaining slots on Dust2 at normal difficulty. Keep both the Game Hub lobby and game tabs open. Keep the host game visible because browsers throttle background simulation. The guest can refresh and rejoin the current match. Relaunching the host game starts a fresh match. A player can end the room with **Leave lobby**.

## Shared backend

Game Hub verifies its own guest session and owns room discovery, code admission, seat leases, host-only start, and cleanup. The external game exchanges signaling through a browser message port tied to the exact game origin, launched window, and launch identifier. The identifier lives in a URL fragment. The external site receives player display names and role information. The hub keeps its Supabase session and room code on its own origin.

Supabase stores the latest offer or answer from each active player in a private signaling slot. The RPC validates the caller’s session, live membership, game, room status, and signaling role. Removing a membership removes that player’s slot. Browsers send commands and match snapshots over WebRTC. The host validates input and owns game rules. Players should trust their host for this casual mode. Direct connections can fail on restrictive networks. The deployment uses STUN for discovery and has no TURN relay or dedicated game server.

## Run locally

1. Start local Supabase and apply all hub migrations. Set `VITE_ENABLE_CS_WEB=true` for the hub build or Vite server.
2. Run `npm ci` and `npm run build` in the Counter-Attack Web checkout. Start it with `npm run preview -- --port 5177 --strictPort`.
3. Build the hub and start `node scripts/serve-session-test.mjs`. Open `http://127.0.0.1:4175/game-hub/` in separate browser contexts to verify the two-origin launch.
4. Run `npm run test:cs-web` against local Supabase for room and signaling tests. Stop the manual hub server and run `TEST_CS_WEB=true npm run test:e2e -- tests/browser/cs-web.spec.js` for the browser flow.

## Deployment

Publish the compatible client through the game repository’s Pages workflow. Apply the hub migration and set the Game Hub repository’s `VITE_ENABLE_CS_WEB` Actions variable to `true`. Rebuild the hub. The external game can use its standalone mode without a Game Hub session.
