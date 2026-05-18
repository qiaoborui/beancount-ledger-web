import path from "node:path";
import { fileURLToPath } from "node:url";
import type { NextConfig } from "next";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const nextConfig: NextConfig = {
  reactStrictMode: true,
  output: "standalone",
  outputFileTracingRoot: __dirname,
  // Fava uses trailing-slash routes. If Next.js strips those slashes on
  // /api/fava/*, the proxy can loop between Next's slash removal and Fava's
  // slash restoration redirects.
  skipTrailingSlashRedirect: true,
};

export default nextConfig;
