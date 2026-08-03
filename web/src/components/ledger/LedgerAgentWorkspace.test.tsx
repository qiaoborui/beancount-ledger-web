import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { normalizeBQLChartValue, restoreSessions, restoreTimeline } from "./LedgerAgentWorkspace";

const source = readFileSync(new URL("./LedgerAgentWorkspace.tsx", import.meta.url), "utf8");

describe("LedgerAgentWorkspace", () => {
  it("supports docked and mobile full-screen layouts", () => {
    expect(source).toContain("ledger-agent-dock");
    expect(source).toContain('presentation = "dock"');
    expect(source).toContain('presentation === "page"');
    expect(source).toContain("账本 Agent 工作区");
    expect(source).toContain("w-full min-w-0");
    expect(source).toContain("fixed inset-0");
    expect(source).toContain("createPortal(panel");
  });

  it("uses approval and typed artifact events", () => {
    expect(source).toContain("onApproval");
    expect(source).toContain('artifact.type === "bql_query"');
    expect(source).toContain('artifact.type === "transaction_draft"');
    expect(source).toContain('artifact.type === "transaction_change"');
    expect(source).toContain("原始 Beancount");
    expect(source).toContain('artifact.type === "chart"');
    expect(source).toContain("MessageResponse");
    expect(source).toContain('approvalPolicy === "always"');
    expect(source).toContain("全屏查看会话");
    expect(source).toContain("会话历史");
    expect(source).toContain("移动端会话历史");
    expect(source).toContain("查看会话历史");
  });

  it("keeps the composer compact and exposes safe Agent starters", () => {
    expect(source).toContain("min-h-14");
    expect(source).toContain("DropdownMenuRadioGroup");
    expect(source).toContain("写入时确认");
    expect(source).toContain("支出分析");
    expect(source).toContain("生成记账草稿");
    expect(source).toContain("对账检查");
    expect(source).toContain("账户维护");
    expect(source).toContain("导入整理");
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

  it("restores independently switchable Agent sessions", () => {
    const sessions = restoreSessions([
      { id: "session-1", serverSessionId: "server-1", createdAt: 1, updatedAt: 2, timeline: [{ kind: "message", id: "message-1", role: "user", content: "第一段对话" }] },
      { id: "session-2", serverSessionId: "server-2", createdAt: 3, updatedAt: 4, timeline: [{ kind: "tool", id: "tool-1", tool: { id: "tool-1", name: "run_bql", title: "运行 BQL", status: "completed", output: { rowCount: 2 } } }] },
    ]);

    expect(sessions).toHaveLength(2);
    expect(sessions[0]).toMatchObject({ id: "session-1", serverSessionId: "server-1", timeline: [{ kind: "message" }] });
    expect(sessions[1]).toMatchObject({ id: "session-2", serverSessionId: "server-2", timeline: [{ kind: "tool" }] });
  });
});
