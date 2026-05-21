import { mergeConfig } from "vite";
import { defineConfig } from "vitest/config";
import viteConfig from "./vite.config";

export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      environment: "node",
      include: ["src/**/*.test.{ts,tsx}"],
      exclude: ["src/lib/auth.test.ts", "src/lib/rateLimit.test.ts", "node_modules/**", "dist/**"],
      restoreMocks: true,
    },
  }),
);
