import './style.css';
import { supabase } from './supabase.js';

document.querySelector('#app').innerHTML = `<header><strong>Game Hub</strong><span class="eyebrow">Coming together</span></header>
<section class="intro"><p class="eyebrow">A little friendly competition</p><h1>Good games.<br />Better company.</h1><p>A home for small multiplayer games. Pick a favorite, bring a friend, and make your next move.</p></section>
<section class="card" aria-labelledby="game-title"><p class="eyebrow">Our first game · 2 players</p><h2 id="game-title">Tic-Tac-Toe</h2><p>Nine squares. Two rivals. A classic worth another round. Online lobbies and guest play are coming next.</p><a class="button" id="game-link" href="https://kumori1313.github.io/tic-tac-toe/">Visit Tic-Tac-Toe →</a></section>
<footer><p>Guest entry and multiplayer are under development.</p></footer>`;

if (import.meta.env.DEV) {
  document.querySelector('#game-link').href = 'http://127.0.0.1:5174/tic-tac-toe/';
}

// Initialize the shared client without signing visitors in before guest entry exists.
void supabase;
