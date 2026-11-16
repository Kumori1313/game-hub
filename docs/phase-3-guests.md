# Phase 3: Guest Entry

## Behavior

The hub prompts for a display name before showing its tic-tac-toe card. Existing guests restore their session and can keep or change their name. Tic-tac-toe restores the same identity and also offers guest entry when opened directly without a session. Lobby discovery and matches are deferred to Phase 4 and Phase 6.

Names are trimmed and limited to 1–24 Unicode code points. Control characters, unpaired surrogates, line separators, and invisible directional formatting are rejected. Emoji and non-Latin names are supported. Names need not be unique and are inserted into the page with `textContent`, never HTML.

## Shared session contract

- Both repositories connect to the same Supabase project.
- Both use `game-hub-auth` as their Auth storage key.
- Supabase Auth provides the user UUID; `user_metadata.display_name` stores the display label. User metadata is editable and must never authorize lobby membership, host privileges, or moves.
- Production links navigate between `/game-hub/` and `/tic-tac-toe/` on the same origin. Tokens and names are never passed in URLs.
- A name change uses `auth.updateUser` and preserves the guest UUID.
- Saved sessions are checked with `auth.getUser` before exposing the ready state. Invalid identities return to entry; network failures retain the stored identity for retry.
- Clearing browser data, signing out, or switching browsers/devices can lose the guest identity. Both pages explain this limitation.

The matching `src/guest.js` and `src/guest-ui.js` modules live in both repositories for now. Keep their behavior aligned until shared code is extracted in a later phase. The two local Vite development ports have different origins; use the browser-test server to test shared-origin handoff locally.

## Failure and accessibility behavior

Forms expose loading state and disable duplicate submissions. Errors preserve the entered name and provide retry or resubmission. Going offline hides game selection; reconnecting checks the saved session again. Returning through the browser’s back/forward cache also rechecks the session.

Inputs have labels and associated hints/errors. Status updates use a live region. Successful entry moves keyboard focus to the game choice or ready-state heading. Controls have visible focus, and the layout works at 320px without horizontal scrolling.

## Verification

Both repositories pass `npm test` and production builds. Their Pages workflows run unit checks before building.

Four Playwright scenarios passed against both local production builds and the published GitHub Pages sites:

1. Safe name rendering, shared guest UUID, refresh, name change, and return to the hub.
2. Empty/long names, failed signup, retry without losing input, offline recovery, and entry after clearing storage.
3. Independent browser contexts using the same name with different UUIDs.
4. Keyboard-only entry and navigation at a 320px viewport.

See the hub README for local and published browser-test commands. Tests create anonymous users in their target backend; use the local backend for routine runs.

The hosted security advisor reports [leaked password protection disabled](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection). This flow uses anonymous guests without passwords; revisit that setting before adding password-based accounts.
