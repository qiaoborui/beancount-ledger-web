import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const source = readFileSync(new URL("./AppShell.tsx", import.meta.url), "utf8");

describe("AppShell Agent route", () => {
  it("uses an uninterrupted workspace for the Agent route", () => {
    expect(source).toContain('const isAgentRoute = isActivePath(pathname, "/agent");');
    expect(source).toContain('isAgentRoute ? "p-0" : "px-3 py-4"');
    expect(source).toContain("!isAgentRoute && <button");
    expect(source).not.toContain('isAgentRoute ? "hidden md:inline-flex" : "inline-flex"');
    expect(source).toContain("!isAgentRoute && <nav");
  });
});
