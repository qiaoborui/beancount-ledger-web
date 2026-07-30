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
});
