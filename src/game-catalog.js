// Reviewed launch entries. The backend catalog separately controls room admission.
// Cards show only the supported player range and, for games from other owners, the provider.
const games = [
  {
    slug: 'tic-tac-toe',
    title: 'Tic-Tac-Toe',
    titleId: 'game-title',
    linkId: 'game-link',
    linkLabel: 'Open game',
    players: '2 players',
    devPort: 5174,
  },
  {
    slug: 'poker',
    title: 'Poker',
    titleId: 'poker-title',
    linkId: 'poker-link',
    linkLabel: 'Open poker lobby',
    players: '2–6 players',
    devPort: 5175,
  },
  {
    slug: 'relay-room',
    title: 'Relay Room',
    titleId: 'relay-room-title',
    linkId: 'relay-room-link',
    linkLabel: 'Open Relay Room',
    players: '1–2 players',
    devPort: 5176,
  },
  {
    slug: 'cs-web',
    title: 'Counter-Attack Web',
    titleId: 'cs-web-title',
    linkId: 'cs-web-link',
    linkLabel: 'Open Counter-Attack Web lobbies',
    players: '2 players',
    provider: 'Vortezler',
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
  container.className = 'game-grid';
  container.setAttribute('aria-labelledby', 'entry-title');
  const list = element('ul', 'game-grid-list');
  for (const game of games) {
    if (game.slug === 'relay-room' && import.meta.env.VITE_ENABLE_RELAY_ROOM !== 'true') continue;
    if (game.slug === 'cs-web' && import.meta.env.VITE_ENABLE_CS_WEB !== 'true') continue;
    const card = element('li', 'game-card');
    const title = element('h3', '', game.title);
    title.id = game.titleId;

    const details = element('p', 'game-meta');
    details.append(element('span', '', game.players));
    if (game.provider) details.append(element('span', '', 'By ' + game.provider));

    const link = element('a', 'button', game.linkLabel + ' ');
    const path = '/' + game.slug + '/';
    link.href = game.launchPath ?? (dev && game.slug !== 'relay-room' ? 'http://127.0.0.1:' + game.devPort + path : path);
    link.id = game.linkId;
    link.setAttribute('aria-describedby', title.id);
    const arrow = element('span', '', '→');
    arrow.setAttribute('aria-hidden', 'true');
    link.append(arrow);

    card.append(title, details, link);
    list.append(card);
  }
  container.append(list);
}
