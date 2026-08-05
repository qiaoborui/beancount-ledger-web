import { describe, expect, it, vi } from "vitest";
import { readLedgerAgentStream } from "./ledgerAgentStream";

describe("readLedgerAgentStream", () => {
  it("dispatches status, tool, artifact, message and final events", async () => {
    const body = [
      'event: status\ndata: {"text":"working"}\n\n',
      'event: tool_call\ndata: {"id":"call-1","name":"run_bql","title":"运行 BQL","status":"running","input":{"query":"SELECT 1"}}\n\n',
      'event: artifact\ndata: {"id":"artifact-1","type":"bql_query","title":"BQL 查询","data":{"query":"SELECT 1"}}\n\n',
      'event: message_delta\ndata: {"text":"查询完成"}\n\n',
      'event: final\ndata: {"sessionId":"session-1","message":"查询完成","status":"completed"}\n\n',
    ].join("");
    const status = vi.fn();
    const tool = vi.fn();
    const artifact = vi.fn();
    const message = vi.fn();

    const final = await readLedgerAgentStream(new Response(body, { status: 200, headers: { "Content-Type": "text/event-stream" } }), {
      onMessageDelta: message,
      onStatus: status,
      onTool: tool,
      onArtifact: artifact,
    });

    expect(status).toHaveBeenCalledWith("working");
    expect(tool).toHaveBeenCalledWith(expect.objectContaining({ name: "run_bql", status: "running" }));
    expect(artifact).toHaveBeenCalledWith(expect.objectContaining({ type: "bql_query" }));
    expect(message).toHaveBeenCalledWith("查询完成");
    expect(final).toEqual(expect.objectContaining({ sessionId: "session-1", message: "查询完成", status: "completed" }));
  });
});
