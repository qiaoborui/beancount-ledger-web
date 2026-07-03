import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const globalsCss = readFileSync(new URL("./globals.css", import.meta.url), "utf8");

describe("mobile browser chrome colors", () => {
  it("keeps the root canvas aligned with the fixed app header", () => {
    const htmlRule = globalsCss.match(/html\s*\{[^}]*\}/)?.[0] ?? "";

    expect(htmlRule).toContain("background: var(--ivory);");
    expect(htmlRule).not.toContain("background: var(--brand);");
  });
});
