import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { pageFromPathname } from "./ledger/routes";

const source = readFileSync(new URL("./LedgerApp.tsx", import.meta.url), "utf8");

describe("LedgerApp routes", () => {
  it("uses Agent for the root path and its dedicated route", () => {
    expect(pageFromPathname("/")).toBe("agent");
    expect(pageFromPathname("/agent")).toBe("agent");
  });

  it("honors the selected homepage for the root path", () => {
    expect(pageFromPathname("/", "overview")).toBe("home");
  });

  it("keeps the financial overview available at /home", () => {
    expect(pageFromPathname("/home")).toBe("home");
  });

  it("keeps Agent route loading visible and does not replay route requests in the dock", () => {
    expect(source).toContain('fallback={props.presentation === "page" ? <AgentPageLoading /> : null}');
    expect(source).toContain("ledger-agent-page flex h-[calc(100dvh-3.5rem-env(safe-area-inset-top))]");
    expect(source).toContain('request={null}');
  });
});
