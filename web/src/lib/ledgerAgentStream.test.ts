import { describe, expect, it, vi } from "vitest";
import { readLedgerAgentStream } from "./ledgerAgentStream";

describe("readLedgerAgentStream", () => {
  it("dispatches tool, artifact, approval, message and final events", async () => {
    const body = [
      'event: status\ndata: {"text":"working"}\n\n',
      'event: tool_call\ndata: {"id":"call-1","name":"run_bql","title":"运行 BQL","status":"running","input":{"query":"SELECT 1"}}\n\n',
      'event: artifact\ndata: {"id":"artifact-1","type":"bql_query","title":"BQL 查询","data":{"query":"SELECT 1"}}\n\n',
      'event: approval_required\ndata: {"id":"approval-1","sessionId":"session-1","toolCallId":"call-2","toolName":"append_transactions","toolTitle":"写入账本","summary":"写入 1 条账本记录","createdAt":"2026-07-30T00:00:00Z","expiresAt":"2026-07-30T00:30:00Z"}\n\n',
      'event: message_delta\ndata: {"text":"需要确认"}\n\n',
      'event: final\ndata: {"sessionId":"session-1","message":"需要确认","pendingApprovalId":"approval-1"}\n\n',
    ].join("");
    const status = vi.fn();
    const tool = vi.fn();
    const artifact = vi.fn();
    const approval = vi.fn();
    const message = vi.fn();

    const final = await readLedgerAgentStream(new Response(body, { status: 200, headers: { "Content-Type": "text/event-stream" } }), {
      onMessageDelta: message,
      onStatus: status,
      onTool: tool,
      onArtifact: artifact,
      onApproval: approval,
    });

    expect(status).toHaveBeenCalledWith("working");
    expect(tool).toHaveBeenCalledWith(expect.objectContaining({ name: "run_bql", status: "running" }));
    expect(artifact).toHaveBeenCalledWith(expect.objectContaining({ type: "bql_query" }));
    expect(approval).toHaveBeenCalledWith(expect.objectContaining({ toolName: "append_transactions" }));
    expect(message).toHaveBeenCalledWith("需要确认");
    expect(final).toEqual(expect.objectContaining({ sessionId: "session-1", pendingApprovalId: "approval-1" }));
  });
});
