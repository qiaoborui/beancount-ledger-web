import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { activeTurnTools, agentToolNeedsSensitiveUnlock, fetchAgentTimelinePage, normalizeAgentTimelinePage, normalizeBQLChartValue, reconcileAgentTimeline, shouldHydrateAgentTimeline, timelineNeedsServerRefresh } from "./LedgerAgentWorkspace";
import { restoreSessions, restoreTimeline } from "./ledgerAgentStorage";

const source = readFileSync(new URL("./LedgerAgentWorkspace.tsx", import.meta.url), "utf8");
const storageSource = readFileSync(new URL("./ledgerAgentStorage.ts", import.meta.url), "utf8");
const importPageSource = readFileSync(new URL("./ImportPage.tsx", import.meta.url), "utf8");

describe("LedgerAgentWorkspace", () => {
  it("supports docked and mobile full-screen layouts", () => {
    expect(source).toContain("ledger-agent-dock");
    expect(source).toContain('presentation = "dock"');
    expect(source).toContain('presentation === "page"');
    expect(source).toContain("agentWorkspace.agentWorkspaceLabel");
    expect(source).toContain("min-h-0 w-72");
    expect(source).toContain("w-full min-w-0");
    expect(source).toContain("fixed inset-0");
    expect(source).toContain("createPortal(panel");
    expect(source).toContain("const desktopViewport = useDesktopViewport();");
    expect(source).toContain('desktopViewport ? "h-dvh" : "fixed inset-0 z-40 h-dvh"');
    expect(source).toContain("desktopViewport ? pageWorkspace : createPortal(pageWorkspace, document.body)");
    expect(source).toContain("pt-[calc(env(safe-area-inset-top)+0.75rem)]");
    expect(source).toContain("h-9 w-9");
  });

  it("renders mobile session history from page presentation", () => {
    const pageBranchStart = source.indexOf('if (presentation === "page")');
    const dockBranchStart = source.indexOf('return <>\n    <aside className={`ledger-agent-dock', pageBranchStart);
    const pageBranch = source.slice(pageBranchStart, dockBranchStart);

    expect(pageBranch).toContain("mobileSessionListOpen && mobileSessionList");
    expect(source).toContain("open && mobileSessionListOpen && mobileSessionList");
  });

  it("uses typed artifact events", () => {
    expect(source).toContain('artifact.type === "bql_query"');
    expect(source).toContain('artifact.type === "transaction_draft"');
    expect(source).toContain('artifact.type === "transaction_change"');
    expect(source).toContain("agentWorkspace.originalBeancount");
    expect(source).toContain('artifact.type === "chart"');
    expect(source).toContain("AgentMessageBubble");
    expect(source).toContain("agentWorkspace.fullscreenView");
    expect(source).toContain("agentWorkspace.sessionHistory");
    expect(source).toContain("agentWorkspace.mobileSessionHistory");
    expect(source).toContain("agentWorkspace.viewSessionHistory");
  });

  it("keeps the composer compact and exposes safe Agent starters", () => {
    expect(source).toContain("min-h-14");
    expect(source).not.toContain("本次请求已完成 8 轮工具处理");
    expect(source).not.toContain("canContinue");
    expect(source).toContain("agentWorkspace.starterExpenseAnalysis");
    expect(source).toContain("agentWorkspace.starterDraft");
    expect(source).toContain("agentWorkspace.starterReconcile");
    expect(source).toContain("agentWorkspace.starterAccounts");
    expect(source).toContain("agentWorkspace.starterImports");
  });

  it("keeps live status, tool progress, and streaming text in one main-flow work region", () => {
    const timeline = restoreTimeline([
      { kind: "tool", id: "old-tool", tool: { id: "old-tool", name: "old", title: "旧工具", status: "completed" } },
      { kind: "message", id: "user", role: "user", content: "分析本月支出" },
      { kind: "tool", id: "current-1", tool: { id: "current-1", name: "get_accounts", title: "读取账户", status: "completed" } },
      { kind: "tool", id: "current-2", tool: { id: "current-2", name: "run_bql", title: "运行 BQL", status: "running" } },
    ]);

    expect(activeTurnTools(timeline).map((item) => item.id)).toEqual(["current-1", "current-2"]);
    expect(source).toContain("AgentWorkStatus");
    expect(source).toContain('aria-live="polite"');
    expect(source).toContain("agentWorkspace.agentWorking");
    expect(source).not.toContain("{busy && streamingText && <MessageBubble");
  });

  it("turns sensitive tool failures into an in-workspace unlock request", () => {
    expect(agentToolNeedsSensitiveUnlock("请先解锁敏感数据后再使用这个工具")).toBe(true);
    expect(agentToolNeedsSensitiveUnlock("Sensitive data is locked")).toBe(true);
    expect(agentToolNeedsSensitiveUnlock("BQL syntax error")).toBe(false);
    expect(source).toContain("apiSensitiveDataLockedEvent");
    expect(source).toContain("解锁敏感数据");
  });

  it("keeps locked Gmail pending items visible and makes Review unlock-aware", () => {
    const loadGmailStart = importPageSource.indexOf("async function loadGmailAutomation");
    const connectGmailStart = importPageSource.indexOf("async function connectGmail", loadGmailStart);
    expect(importPageSource.slice(loadGmailStart, connectGmailStart)).not.toContain("setPendingImports([]);");
    expect(importPageSource).toContain("importPage.pendingBillReceived");
    const openPendingStart = importPageSource.indexOf("async function openPendingImport");
    const dismissPendingStart = importPageSource.indexOf("async function dismissPendingImport", openPendingStart);
    expect(importPageSource.slice(openPendingStart, dismissPendingStart)).toContain('{ kind: "write" }');
  });

  it("converts BQL money values from minor units before charting", () => {
    expect(normalizeBQLChartValue(63070, { name: "total", type: "money" })).toBe(630.7);
    expect(normalizeBQLChartValue(12, { name: "count", type: "number" })).toBe(12);
  });

  it("restores messages, tool results, and artifacts while ignoring legacy approval records", () => {
    const timeline = restoreTimeline([
      { kind: "message", id: "message-1", role: "user", content: "查询餐饮支出" },
      { kind: "tool", id: "tool-1", tool: { id: "tool-1", name: "run_bql", title: "运行 BQL", status: "completed", output: { rowCount: 3 } } },
      { kind: "artifact", id: "artifact-1", artifact: { id: "artifact-1", type: "table", title: "BQL 结果", data: { rows: [] } } },
      { kind: "approval", id: "approval-1", resolved: true, approval: { id: "approval-1", sessionId: "session-1", toolCallId: "call-1", toolName: "append_transactions", toolTitle: "写入账本", summary: "确认写入", createdAt: "2026-07-30T00:00:00Z", expiresAt: "2026-07-30T01:00:00Z" } },
    ]);

    expect(timeline).toHaveLength(3);
    expect(timeline[1]).toMatchObject({ kind: "tool", tool: { output: { rowCount: 3 } } });
    expect(timeline[2]).toMatchObject({ kind: "artifact", artifact: { type: "table" } });
  });

  it("does not discard persisted timeline items by count", () => {
    const timeline = restoreTimeline(Array.from({ length: 81 }, (_, index) => ({ kind: "message", id: `message-${index}`, role: "user", content: `第 ${index} 条` })));
    expect(timeline).toHaveLength(81);
    expect(source).not.toContain("MAX_STORED_TIMELINE_ITEMS");
    expect(source).toContain("AGENT_TIMELINE_PAGE_SIZE");
  });

  it("keeps refreshing a restored timeline until the final assistant response arrives", () => {
    expect(timelineNeedsServerRefresh([{ kind: "message", id: "user", role: "user", content: "查看持仓" }])).toBe(true);
    expect(timelineNeedsServerRefresh([{ kind: "tool", id: "tool", tool: { id: "tool", name: "get_accounts", title: "读取账户表", status: "completed" } }])).toBe(true);
    expect(timelineNeedsServerRefresh([{ kind: "message", id: "assistant", role: "assistant", content: "已完成" }])).toBe(false);
  });

  it("normalizes a null timeline response instead of crashing the workspace", () => {
    expect(normalizeAgentTimelinePage({ items: null, nextBefore: null })).toEqual({ items: [], nextBefore: null });
  });

  it("keeps rendered message identities stable when the durable timeline arrives", () => {
    const current = restoreTimeline([
      { kind: "message", id: "local-user", role: "user", content: "分析上周支出" },
      { kind: "tool", id: "tool-1", tool: { id: "tool-1", name: "run_bql", title: "运行 BQL", status: "running" } },
      { kind: "message", id: "local-assistant", role: "assistant", content: "已完成分析" },
    ]);
    const server = restoreTimeline([
      { kind: "message", id: "server-user", role: "user", content: "分析上周支出" },
      { kind: "tool", id: "tool-1", tool: { id: "tool-1", name: "run_bql", title: "运行 BQL", status: "completed", output: { rowCount: 7 } } },
      { kind: "message", id: "server-assistant", role: "assistant", content: "已完成分析" },
    ]);

    const reconciled = reconcileAgentTimeline(server, current);

    expect(reconciled.map((item) => item.id)).toEqual(["local-user", "tool-1", "local-assistant"]);
    expect(reconciled[1]).toMatchObject({ kind: "tool", tool: { status: "completed", output: { rowCount: 7 } } });
  });

  it("preserves newer local items when remote recovery arrives", () => {
    const current = restoreTimeline([
      { kind: "message", id: "local-user", role: "user", content: "分析上周支出" },
      { kind: "message", id: "local-new", role: "assistant", content: "本地新增结果" },
    ]);
    const server = restoreTimeline([
      { kind: "message", id: "server-user", role: "user", content: "分析上周支出" },
    ]);

    expect(reconcileAgentTimeline(server, current).map((item) => item.id)).toEqual(["local-user", "local-new"]);
  });

  it("treats locked and offline remote history as an unavailable fallback", async () => {
    const locked = await fetchAgentTimelinePage(async () => new Response(JSON.stringify({ error: "Sensitive data is locked" }), { status: 423 }));
    const offline = await fetchAgentTimelinePage(async () => {
      throw new TypeError("Failed to fetch");
    });

    expect(locked).toBeNull();
    expect(offline).toBeNull();
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

  it("marks legacy metadata-only timelines as missing remote-recovery candidates", () => {
    const sessions = restoreSessions([{ id: "session-title", serverSessionId: "server-title", title: "分析本月支出", createdAt: 1, updatedAt: 2, timeline: [] }]);
    expect(sessions[0]).toMatchObject({ title: "分析本月支出", timelineState: "missing", timeline: [] });
    expect(shouldHydrateAgentTimeline(sessions[0], false)).toBe(false);
    expect(shouldHydrateAgentTimeline(sessions[0], true)).toBe(true);
  });

  it("does not hydrate a deliberately empty new local session", () => {
    const sessions = restoreSessions([{ id: "session-new", serverSessionId: "server-new", title: "", archived: false, createdAt: 1, updatedAt: 2, timelineState: "available", timeline: [] }]);
    expect(shouldHydrateAgentTimeline(sessions[0], true)).toBe(false);
  });

  it("does not persist or request remote fallback before IndexedDB hydration finishes", () => {
    expect(source).toContain("if (!localHydrationReady) return;\n    void writeStoredAgent");
    expect(source).toContain("if (!shouldHydrateAgentTimeline(activeSession, localHydrationReady)) return;");
    expect(source.indexOf("void readStoredAgent(ledgerScope)")).toBeLessThan(source.indexOf("if (!localHydrationReady) return;\n    void writeStoredAgent"));
  });

  it("never persists the new-session placeholder as a title", () => {
    expect(storageSource).toContain("title: session.title || timelineTitle(session.timeline)");
    expect(storageSource).not.toContain("title: sessionLabel(session), archived");
  });
});
