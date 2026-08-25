import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const source = readFileSync(new URL("./AppShell.tsx", import.meta.url), "utf8");
const styles = readFileSync(new URL("../app/globals.css", import.meta.url), "utf8");

describe("AppShell Agent route", () => {
  it("uses an uninterrupted workspace for the Agent route", () => {
    expect(source).toContain('const isAgentRoute = isActivePath(pathname, "/agent");');
    expect(source).toContain('isAgentRoute ? "p-0" : "px-3 py-4"');
    expect(source).toContain("!isAgentRoute && <button");
    expect(source).not.toContain('isAgentRoute ? "hidden md:inline-flex" : "inline-flex"');
    expect(source).toContain("!isAgentRoute && <nav");
  });
});

describe("AppShell mobile safe area", () => {
  it("adds standalone breathing room through one shared top inset", () => {
    expect(styles).toContain("--app-safe-area-top: env(safe-area-inset-top, 0px);");
    expect(styles).toContain("@media (display-mode: standalone)");
    expect(styles).toContain("--app-safe-area-top: calc(env(safe-area-inset-top, 0px) + 0.5rem);");
    expect(source).toContain("pt-[calc(3.5rem+var(--app-safe-area-top))]");
    expect(source).toContain("top-[var(--app-safe-area-top)]");
    expect(source).toContain("pt-[var(--app-safe-area-top)]");
  });
});
