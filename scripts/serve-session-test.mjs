import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, extname, sep } from 'node:path';

const roots = {
  'game-hub': resolve('dist'),
  'tic-tac-toe': resolve(process.env.GAME_SITE_DIR ?? '../tic-tac-toe', 'dist'),
};
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };
createServer(async (request, response) => {
  try {
    const [slug, ...parts] = new URL(request.url, 'http://127.0.0.1').pathname.slice(1).split('/');
    const root = roots[slug];
    if (!root) throw new Error('Missing site');
    const path = resolve(root, decodeURIComponent(parts.join('/') || 'index.html'));
    if (!path.startsWith(root + sep)) throw new Error('Invalid path');
    const body = await readFile(path);
    response.writeHead(200, { 'Content-Type': types[extname(path)] ?? 'application/octet-stream' });
    response.end(body);
  } catch { response.writeHead(404); response.end('Not found'); }
}).listen(4175, '127.0.0.1');
