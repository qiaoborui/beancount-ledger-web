import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const source = readFileSync(new URL("./BQLQueryPage.tsx", import.meta.url), "utf8");

describe("BQLQueryPage", () => {
  it("uses the app code theme instead of CodeMirror's default light theme", () => {
    expect(source).toContain("theme={bqlEditorTheme}");
    expect(source).toContain("var(--ledger-code-bg)");
    expect(source).toContain("var(--ledger-code-fg)");
    expect(source).toContain("var(--ledger-code-gutter-bg)");
    expect(source).not.toContain("dark: false");
    expect(source).not.toContain('theme="light"');
  });

  it("connects the editor to the global Agent", () => {
    expect(source).toContain("onOpenAgent");
    expect(source).toContain("agentQuery");
    expect(source).toContain("AI 生成");
  });

  it("syncs successful queries as named history instead of browser recents", () => {
    expect(source).toContain('"/api/ledger/bql-history"');
    expect(source).toContain("rememberSuccessfulQuery");
    expect(source).toContain("if (completed) void rememberSuccessfulQuery(historyText)");
    expect(source).toContain("查询历史");
    expect(source).not.toContain("ledger.bql.recents.v1");
  });
});
