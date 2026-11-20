# Relay Room local integration

The game ID is `relay-room`, the launch path is `/relay-room/`, and the prototype supports exactly two guests. A host can start once both seats have live leases. Private rooms use the existing code-entry flow. Leaving an active round closes the room and releases both memberships. Use a new room for another run. The game checkout provides its own original scene and the trusted Node WebSocket runtime. Both projects use the MIT license.

## Set up and run

1. Start local Supabase following the hub setup guide and run `npx --no-install supabase migration up --local`. The new catalog row starts with gameplay disabled. In the **local** database, run `update public.game_catalog set playable=true where id='relay-room';`.
2. Set `VITE_ENABLE_RELAY_ROOM=true` in the hub's ignored `.env.local`. Provide the same local `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` in both checkouts. Use Node 22.13 or newer for the shared test runtime.
3. In the game checkout, run `npm ci` and `npm run build`. In the hub checkout, run `npm ci`, `npm run build`, then `npm run dev:relay`. Set `RELAY_SITE_DIR` if the game is located outside `../Horror-Friendslop`.
4. Open http://127.0.0.1:4175/game-hub/ in two browser profiles. The built sites share a guest session within each profile. For an SSH client, forward ports 4175 and 54321 to the corresponding loopback ports on the project computer.
5. Stop the manual server and run `npm run test:relay` for private admission, live state, refresh, departure, and a fresh public run. The full release suite accepts `RELAY_SITE_DIR` alongside the other game paths.

## Publication

The catalog build flag controls the hub link. The database flag controls whether the host can start a game. Enable production only after the compatible client is available under the approved path and its trusted WSS runtime is reachable. The game README describes the runtime command, TLS proxy, and client origin settings.

For hot reload, run `npm run dev:hub` in the game checkout and `npm run dev` in the hub checkout. Enter through `http://127.0.0.1:5173/game-hub/`. The hub proxies the game route and its WebSocket on the same origin.
