import { defineConfig, loadEnv } from 'vite';
import { validateClientConfig, securityMeta } from './scripts/security-policy.mjs';

export default defineConfig(({ mode, command }) => {
  const env = loadEnv(mode, process.cwd(), 'VITE_');
  const backend = validateClientConfig(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_PUBLISHABLE_KEY);
  const local = backend?.hostname === '127.0.0.1' || backend?.hostname === 'localhost';
  const frames = env.VITE_ENABLE_CS_WEB === 'true'
    ? [local ? 'http://127.0.0.1:5177/cs-web/' : 'https://vortezler.github.io/Counter-Attack-Web/']
    : [];
  return {
    base: '/game-hub/',
    server: {
      host: '127.0.0.1', port: 5173, strictPort: true,
      proxy: env.VITE_ENABLE_RELAY_ROOM === 'true'
        ? {'/relay-room/': {target:'http://127.0.0.1:5176',ws:true}} : {},
    },
    plugins: [{
      name: 'browser-security-policy',
      transformIndexHtml: { order: 'post', handler: html => securityMeta(html, backend, command === 'serve' ? 5173 : null, frames) },
    }],
  };
});
