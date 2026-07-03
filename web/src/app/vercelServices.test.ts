import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const rootConfig = JSON.parse(readFileSync(new URL("../../../vercel.json", import.meta.url), "utf8")) as {
  services?: Record<string, Record<string, unknown>>;
  rewrites?: Array<Record<string, unknown>>;
};
const webConfig = JSON.parse(readFileSync(new URL("../../vercel.json", import.meta.url), "utf8")) as {
  rewrites?: Array<Record<string, unknown>>;
};

describe("Vercel services routing", () => {
  it("routes API traffic to the backend service in the same deployment", () => {
    expect(rootConfig.services?.frontend).toEqual(expect.objectContaining({ root: "web/" }));
    expect(rootConfig.services?.backend).toEqual(
      expect.objectContaining({ root: ".", entrypoint: "Dockerfile.vercel" }),
    );
    expect(rootConfig.rewrites).toEqual(
      expect.arrayContaining([
        { source: "/.well-known/webauthn", destination: { service: "backend" } },
        { source: "/api/(.*)", destination: { service: "backend" } },
        { source: "/(.*)", destination: { service: "frontend" } },
      ]),
    );
  });

  it("does not keep the standalone frontend pointed at production APIs", () => {
    expect(JSON.stringify(webConfig)).not.toContain("beancount-ledger-web.vercel.app/api");
  });
});
