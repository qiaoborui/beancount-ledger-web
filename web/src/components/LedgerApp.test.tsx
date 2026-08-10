import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { pageFromPathname } from "./ledger/routes";

const source = readFileSync(new URL("./LedgerApp.tsx", import.meta.url), "utf8");

describe("LedgerApp routes", () => {
  it("calls every LedgerApp hook before any authentication or setup early return", () => {
    const firstEarlyReturn = source.indexOf('if (instanceSetup === "checking")');
    const componentEnd = source.indexOf("function PullRefreshIndicator", firstEarlyReturn);
    const postReturnHooks = source
      .slice(firstEarlyReturn, componentEnd)
      .match(/\buse(?:Callback|Effect|Memo|Ref|State|Transition)\s*\(/g);

    expect(firstEarlyReturn).toBeGreaterThan(-1);
    expect(componentEnd).toBeGreaterThan(firstEarlyReturn);
    expect(postReturnHooks).toBeNull();
  });

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
    expect(source).toContain("const desktopViewport = useDesktopViewport();");
    expect(source).toContain('desktopViewport ? "h-dvh" : "fixed inset-0 z-40 h-dvh"');
    expect(source).toContain("return desktopViewport ? loading : createPortal(loading, document.body);");
    expect(source).toContain('request={null}');
  });
});
