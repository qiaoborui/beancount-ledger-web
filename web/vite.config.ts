import path from "node:path";
import { fileURLToPath } from "node:url";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vitest/config";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [tailwindcss()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "src"),
    },
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    rolldownOptions: {
      output: {
        codeSplitting: {
          groups: [
            {
              name: "react-vendor",
              test: /node_modules[\\/](react|react-dom|scheduler|use-sync-external-store)[\\/]/,
              priority: 30,
            },
            {
              name: "chart-vendor",
              test: /node_modules[\\/](recharts|victory-vendor|d3-|react-smooth|react-transition-group)[\\/]/,
              priority: 20,
            },
            {
              name: "markdown-vendor",
              test: /node_modules[\\/](@streamdown|streamdown|hast|mdast|micromark|remark|rehype|unified|unist|vfile|marked|mermaid|@mermaid-js)[\\/]/,
              priority: 10,
            },
            {
              name: "ai-vendor",
              test: /node_modules[\\/](@ai-sdk|ai)[\\/]/,
              priority: 10,
            },
          ],
        },
      },
    },
  },
});
