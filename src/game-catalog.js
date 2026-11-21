// Reviewed launch entries. The backend catalog separately controls room admission.
const games = [
  {
    slug: 'tic-tac-toe',
    title: 'Tic-Tac-Toe',
    titleId: 'game-title',
    linkId: 'game-link',
    linkLabel: 'Open game',
    details: ['2 players'],
    devPort: 5174,
    glyph: ['×', '○'],
  },
  {
    slug: 'poker',
    title: 'Poker',
    titleId: 'poker-title',
    linkId: 'poker-link',
    linkLabel: 'Open poker lobby',
    details: ['2–6 players', 'No-Limit Hold’em'],
    devPort: 5175,
  },
  {
    slug: 'relay-room',
    title: 'Relay Room',
    titleId: 'relay-room-title',
    linkId: 'relay-room-link',
    linkLabel: 'Open Relay Room',
    details: ['1–2 players', 'Solo or co-op horror'],
    devPort: 5176,
  },
  {
    slug: 'cs-web',
    title: 'Counter-Attack Web',
    titleId: 'cs-web-title',
    linkId: 'cs-web-link',
    linkLabel: 'Open Counter-Attack Web lobbies',
    details: ['2 players', 'Hosted by a player', 'Vortezler'],
    launchPath: '/game-hub/?game=cs-web',
  },
];

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text) node.textContent = text;
  return node;
}

export function mountGameCatalog(container, { dev = false } = {}) {
  for (const [index, game] of games.entries()) {
    if (game.slug === 'relay-room' && import.meta.env.VITE_ENABLE_RELAY_ROOM !== 'true') continue;
    if (game.slug === 'cs-web' && import.meta.env.VITE_ENABLE_CS_WEB !== 'true') continue;
    const first = index === 0;
    const card = first ? container : element('div', 'catalog-extra');
    const title = element('h2', '', game.title);
    title.id = game.titleId;

    if (game.glyph) {
      const summary = element('div', 'game-summary');
      const glyph = element('span', 'game-glyph', game.glyph[0]);
      glyph.setAttribute('aria-hidden', 'true');
      glyph.append(element('span', '', game.glyph[1]));
      const heading = element('div');
      heading.append(title);
      summary.append(glyph, heading);
      card.append(summary);
    } else {
      card.append(title);
    }

    const details = element('div', 'game-meta');
    details.append(...game.details.map(detail => element('span', '', detail)));
    const link = element('a', 'button', game.linkLabel + ' ');
    const path = '/' + game.slug + '/';
    link.href = game.launchPath ?? (dev && game.slug !== 'relay-room' ? 'http://127.0.0.1:' + game.devPort + path : path);
    link.id = game.linkId;
    const arrow = element('span', '', '→');
    arrow.setAttribute('aria-hidden', 'true');
    link.append(arrow);
    card.append(details, link);

    if (first) {
      container.setAttribute('aria-labelledby', title.id);
      card.append(element('p', 'hint availability'));
    } else {
      container.append(card);
    }
  }
}
