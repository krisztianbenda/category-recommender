import { defineConfig } from "vitest/config";

// End-to-end tests run the built service (npm run test:e2e builds first).
export default defineConfig({
  test: {
    include: ["tests/e2e/**/*.test.ts"],
    testTimeout: 30000,
    hookTimeout: 60000,
    pool: "forks",
  },
});
