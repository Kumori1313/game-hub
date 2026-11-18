import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { parseEnv } from 'node:util';
import { validateClientConfig } from './security-policy.mjs';

const hub = process.cwd();
const game = resolve(process.env.GAME_SITE_DIR ?? '../tic-tac-toe');
if (process.env.E2E_BASE_URL) throw new Error('This full release check is local only. Run published browser smoke tests separately.');
if (game === hub || !existsSync(resolve(game,'src/board.js'))) throw new Error('Set GAME_SITE_DIR to the tic-tac-toe checkout.');
const poker = resolve(process.env.POKER_SITE_DIR ?? '../poker');
if (poker === hub || poker === game || !existsSync(resolve(poker,'src/lobbies.js'))) throw new Error('Set POKER_SITE_DIR to the poker checkout.');
const directories = [hub,game,poker];
const configs = directories.map(directory => parseEnv(readFileSync(resolve(directory,'.env.local'),'utf8')));
for (const config of configs) {
  const backend = validateClientConfig(config.VITE_SUPABASE_URL,config.VITE_SUPABASE_PUBLISHABLE_KEY);
  if (!backend || !['127.0.0.1','localhost'].includes(backend.hostname)) throw new Error('Release integration checks require local Supabase settings in both repositories.');
}
if (configs.some(config => config.VITE_SUPABASE_URL !== configs[0].VITE_SUPABASE_URL || config.VITE_SUPABASE_PUBLISHABLE_KEY !== configs[0].VITE_SUPABASE_PUBLISHABLE_KEY)) throw new Error('Both repositories must target the same local backend.');
function run(directory, script) {
  console.log(`Checking ${directory === hub ? 'hub' : 'game'}: ${script}`);
  const result = spawnSync('npm',['run',script],{ cwd: directory, stdio: 'inherit', env: { ...process.env, GAME_SITE_DIR: game, POKER_SITE_DIR: poker } });
  if (result.error || result.status !== 0) process.exit(result.status || 1);
}
// Complete builds before serving either dist directory to the browser suite.
for (const directory of directories) { run(directory,'test'); run(directory,'build'); }
run(hub,'test:lobbies');
run(hub,'test:security');
run(hub,'test:rooms');
run(hub,'test:poker');
run(hub,'test:upgrade');
run(hub,'test:e2e');
console.log('Local release checks passed. Record the browser engine and exact commits in the release report.');
