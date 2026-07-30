import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { normalizeBQLChartValue, restoreTimeline } from "./LedgerAgentWorkspace";

const source = readFileSync(new URL("./LedgerAgentWorkspace.tsx", import.meta.url), "utf8");

describe("LedgerAgentWorkspace", () => {
  it("supports docked and mobile full-screen layouts", () => {
    expect(source).toContain("ledger-agent-dock");
    expect(source).toContain("w-full min-w-0");
    expect(source).toContain("fixed inset-0");
    expect(source).toContain("createPortal(panel");
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

  it("restores messages, tool results, artifacts, and approval records", () => {
    const timeline = restoreTimeline([
      { kind: "message", id: "message-1", role: "user", content: "查询餐饮支出" },
      { kind: "tool", id: "tool-1", tool: { id: "tool-1", name: "run_bql", title: "运行 BQL", status: "completed", output: { rowCount: 3 } } },
      { kind: "artifact", id: "artifact-1", artifact: { id: "artifact-1", type: "table", title: "BQL 结果", data: { rows: [] } } },
      { kind: "approval", id: "approval-1", resolved: true, approval: { id: "approval-1", sessionId: "session-1", toolCallId: "call-1", toolName: "append_transactions", toolTitle: "写入账本", summary: "确认写入", createdAt: "2026-07-30T00:00:00Z", expiresAt: "2026-07-30T01:00:00Z" } },
    ]);

    expect(timeline).toHaveLength(4);
    expect(timeline[1]).toMatchObject({ kind: "tool", tool: { output: { rowCount: 3 } } });
    expect(timeline[2]).toMatchObject({ kind: "artifact", artifact: { type: "table" } });
    expect(timeline[3]).toMatchObject({ kind: "approval", resolved: true });
  });
});
