import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globals: true,
    testTimeout: 60_000,
    hookTimeout: 120_000,
    // Integration tests handle their own Anvil lifecycle in test hooks.
    // Keep this explicit so there is only one setup strategy.
    globalSetup: [],
  },
});
