import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { normalizeBQLChartValue } from "./LedgerAgentWorkspace";

const source = readFileSync(new URL("./LedgerAgentWorkspace.tsx", import.meta.url), "utf8");

describe("LedgerAgentWorkspace", () => {
  it("supports dock, collapsible and mobile full-screen layouts", () => {
    expect(source).toContain("fixed inset-y-0 right-0");
    expect(source).toContain("md:w-[430px]");
    expect(source).toContain("dockCollapsed");
    expect(source).toContain("fixed inset-0");
  });

  it("uses approval and typed artifact events", () => {
    expect(source).toContain("onApproval");
    expect(source).toContain('artifact.type === "bql_query"');
    expect(source).toContain('artifact.type === "transaction_draft"');
    expect(source).toContain('artifact.type === "chart"');
    expect(source).toContain("MessageResponse");
    expect(source).toContain('approvalPolicy === "always"');
  });

  it("converts BQL money values from minor units before charting", () => {
    expect(normalizeBQLChartValue(63070, { name: "total", type: "money" })).toBe(630.7);
    expect(normalizeBQLChartValue(12, { name: "count", type: "number" })).toBe(12);
  });
});
