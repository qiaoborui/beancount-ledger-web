import { describe, expect, it } from "vitest";
import { pageFromPathname } from "./ledger/routes";

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
});
