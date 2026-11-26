import './style.css';
import { supabase } from './supabase.js';
import { mountGuestEntry } from './guest-ui.js';
import { mountTheme } from './theme.js';
import { mountCsWebRoom } from './cs-web-room.js';
import { mountGameCatalog } from './game-catalog.js';

document.querySelector('#app').innerHTML = `<a class="skip-link" href="#guest-entry">Skip to guest entry</a><header class="site-header"><nav class="nav-inner" aria-label="Main navigation"><a class="brand" href="/game-hub/" aria-label="Game Hub home"><svg class="brand-mark" viewBox="0 0 40 40" aria-hidden="true"><path d="M8 3h24l5 5v24l-5 5H8l-5-5V8Z" fill="none" stroke="currentColor"/><path d="M15 8v24M25 8v24M8 15h24M8 25h24" fill="none" stroke="currentColor" opacity=".5"/><path d="m8 8 4 4m0-4-4 4m20 20 4 4m0-4-4 4" stroke="currentColor" stroke-width="2"/><circle cx="20" cy="20" r="3" fill="currentColor"/></svg><span>GAME<span class="brand-dot">/</span>HUB</span></a><div class="nav-links"><button id="theme-toggle" type="button" class="theme-toggle" aria-label="Switch to light mode">◑ Light mode</button></div></nav></header><section class="hero" aria-labelledby="mission"><div class="hero-inner"><div class="hero-copy"><h1 id="mission">Game Hub</h1></div><div class="hero-art" aria-hidden="true"></div></div></section><main class="content-layout"><div class="main-column"><section class="entry-panel" id="guest-entry" aria-labelledby="entry-title">

<h2 id="entry-title">Checking your guest session…</h2>
<p id="guest-status" role="status" aria-live="polite"></p>
<div id="identity" hidden><p><strong id="guest-name"></strong></p><button type="button" class="secondary" id="change-name">Change name <span aria-hidden="true">↗</span></button></div>
<form id="guest-form" novalidate hidden>
<label for="display-name">Display name</label>
<div class="input-line"><input id="display-name" name="display-name" type="text" autocomplete="nickname" aria-describedby="name-hint guest-error" disabled /><button id="save-name" class="button" type="submit" disabled>Continue <span aria-hidden="true">→</span></button></div>
<p id="name-hint" class="hint">1–24 characters.</p>
<button id="cancel-name" class="secondary" type="button" hidden>Cancel</button>
</form>
<p id="guest-error" class="error" role="alert"></p>
<button id="retry" type="button" class="secondary" hidden>Retry connection</button>
</section><section id="selection" hidden></section></div></main><footer class="site-footer"><details class="privacy-note"><summary>About guest identities</summary><p>Names are not unique. Your guest identity is saved in this browser; clearing browser data or switching devices can lose it.</p></details></footer>`;

const selection = document.querySelector('#selection');
if (supabase && import.meta.env.VITE_ENABLE_CS_WEB === 'true'
  && new URLSearchParams(location.search).get('game') === 'cs-web') {
  selection.className = 'game-card';
  mountCsWebRoom(selection, supabase);
} else {
  mountGameCatalog(selection, { dev: import.meta.env.DEV });
}

mountTheme();
mountGuestEntry({ client: supabase, gamePage: false });
