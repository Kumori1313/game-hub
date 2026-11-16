import { defineConfig } from 'vite';

export default defineConfig({
  base: '/game-hub/',
  server: { host: '127.0.0.1', port: 5173, strictPort: true },
});
