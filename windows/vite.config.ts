import react from '@vitejs/plugin-react';
import { defineConfig } from 'vitest/config';

// Tauri loads the dev server from http://localhost:1420 and the build from ../dist (see src-tauri/tauri.conf.json).
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: { outDir: 'dist', target: 'es2022' },
  test: { include: ['src/**/*.test.ts'] },
});
