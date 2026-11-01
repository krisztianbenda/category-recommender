import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["tests/{unit,contract,integration}/**/*.test.ts"],
    testTimeout: 20000,
    hookTimeout: 30000,
    pool: "forks",
  },
});
