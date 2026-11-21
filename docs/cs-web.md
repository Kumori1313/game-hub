# Counter-Attack Web

Game Hub opens a two-seat Counter-Attack Web lobby at `/game-hub/?game=cs-web`. Create a public or code-only lobby, wait for another guest, and start the match. Both players then choose **Open match**. The game runs in an embedded view served by the original owner’s site. The lobby stays active in the same tab. [Counter-Attack Web on GitHub Pages](https://vortezler.github.io/Counter-Attack-Web/)

The creator plays CT and runs the simulation. The other player plays T. Eight bots fill the remaining slots on Dust2 at normal difficulty. Keep the host tab open. The match clock runs separately from rendering, although mobile browsers can suspend a background tab. Touch devices have movement and action buttons and support dragging the view to aim. The guest can reopen the game from the same active lobby and recover the current match. Relaunching the host game starts a fresh match. A player can end the room with **Leave lobby**.

## Shared backend

Game Hub verifies its own guest session and owns room discovery, code admission, seat leases, host-only start, and cleanup. The external game exchanges connection messages through a browser message port bound to the approved game origin, frame, and launch identifier. The identifier lives in a URL fragment. The external site receives player display names and role information. The hub keeps its Supabase session and room code on its own origin.

Supabase stores the latest offer or answer from each active player in a private signaling slot. The RPC validates the caller’s session, live membership, game, room status, and signaling role. Removing a membership removes that player’s slot. Browsers prefer a direct WebRTC connection. If it fails, the hub uses two private Supabase Realtime Broadcast lanes. Room membership and the host or peer role govern access. The fallback sends roughly eight snapshots and ten input updates per second. It shares the existing Supabase Free quota and can have more latency. The creator’s browser runs the same match simulation over either connection.

## Run locally

1. Start local Supabase and apply all hub migrations. Set `VITE_ENABLE_CS_WEB=true` for the hub build or Vite server.
2. Run `npm ci` and `npm run build` in the Counter-Attack Web checkout. Start it with `npm run preview -- --port 5177 --strictPort`.
3. Build the hub and start `node scripts/serve-session-test.mjs`. Open `http://127.0.0.1:4175/game-hub/` in separate browser contexts to verify the two-origin launch.
4. Run `npm run test:cs-web` against local Supabase for room and signaling tests. Stop the manual hub server and run `TEST_CS_WEB=true npm run test:e2e -- tests/browser/cs-web.spec.js` for the direct and forced-relay browser flows. The relay case disables WebRTC and uses a touch-enabled host context.

## Deployment

Publish the compatible client through the game repository’s Pages workflow. Apply the hub migration and set the Game Hub repository’s `VITE_ENABLE_CS_WEB` Actions variable to `true`. Rebuild the hub. The external game can use its standalone mode without a Game Hub session.
