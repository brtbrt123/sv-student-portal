import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'

// Unit tests: pure functions only, no database, no secret, no browser. Run with `npm test`.
export default defineConfig({
  resolve: { alias: { '@': fileURLToPath(new URL('.', import.meta.url)) } },
  test: { include: ['tests/unit/**/*.test.ts'], environment: 'node' },
})
