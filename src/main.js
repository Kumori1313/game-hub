import './style.css';
import { supabase } from './supabase.js';
import { mountGuestEntry } from './guest-ui.js';

document.querySelector('#app').innerHTML = `<header><strong>Game Hub</strong><span class="eyebrow">Play together</span></header>
<section class="intro"><p class="eyebrow">A little friendly competition</p><h1>Good games.<br />Better company.</h1><p>Pick a name, choose a favorite, and make your next move.</p></section><section class="card" aria-labelledby="entry-title">
<h2 id="entry-title">Checking your guest session…</h2>
<p id="guest-status" role="status" aria-live="polite"></p>
<p id="identity" hidden>Playing as <strong id="guest-name"></strong> <button type="button" class="secondary" id="change-name">Change name</button></p>
<form id="guest-form" novalidate hidden>
<label for="display-name">Display name</label>
<input id="display-name" name="display-name" type="text" autocomplete="nickname" aria-describedby="name-hint guest-error" disabled />
<p id="name-hint" class="hint">1–24 characters. Names aren’t reserved and may be shared by other guests.</p>
<div class="actions"><button id="save-name" class="button" type="submit" disabled>Continue</button><button id="cancel-name" class="secondary" type="button" hidden>Cancel</button></div>
</form>
<p id="guest-error" class="error" role="alert"></p>
<button id="retry" type="button" class="secondary" hidden>Retry connection</button>
</section>
<section id="selection" class="card" aria-labelledby="game-title" hidden><p class="eyebrow">2 players · Turn-based</p><h2 id="game-title">Tic-Tac-Toe</h2><p>Nine squares. Two rivals. A classic worth another round.</p><a class="button" id="game-link" href="/tic-tac-toe/">Choose Tic-Tac-Toe →</a><p class="hint">Guest entry is ready. Public lobbies and matches are coming next.</p></section><footer><p class="hint">Guest identities are saved in this browser. Clearing browser data, signing out, or switching devices can lose your identity. Your display name is only a label.</p></footer>`;

if (import.meta.env.DEV) document.querySelector('#game-link').href = 'http://127.0.0.1:5174/tic-tac-toe/';

mountGuestEntry({ client: supabase, gamePage: false });
