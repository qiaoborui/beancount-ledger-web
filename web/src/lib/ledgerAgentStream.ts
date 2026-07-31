import { readJson } from "./clientFetch";

export type AgentToolState = "running" | "completed" | "error";

export type AgentToolEvent = {
  id: string;
  name: string;
  title: string;
  status: AgentToolState;
  input?: unknown;
  output?: unknown;
  error?: string;
};

export type AgentArtifactType = "bql_query" | "transaction_draft" | "account_draft" | "memory_draft" | "table" | "chart" | "navigation";

export type AgentArtifact = {
  id: string;
  type: AgentArtifactType;
  title: string;
  data: unknown;
};

export type AgentApproval = {
  id: string;
  sessionId: string;
  toolCallId: string;
  toolName: string;
  toolTitle: string;
  summary: string;
  createdAt: string;
  expiresAt: string;
};

export type AgentFinal = {
  sessionId: string;
  message: string;
  pendingApprovalId?: string;
  refreshLedger?: boolean;
};

type AgentStreamError = { error?: string };

export async function readLedgerAgentStream(
  response: Response,
  options: {
    onMessageDelta: (text: string) => void;
    onStatus?: (text: string) => void;
    onTool?: (tool: AgentToolEvent) => void;
    onArtifact?: (artifact: AgentArtifact) => void;
    onApproval?: (approval: AgentApproval) => void;
  }
): Promise<AgentFinal> {
  if (!response.ok || !response.body) {
    const data = await readJson<AgentStreamError>(response, {});
    throw new Error(data.error || "Agent 请求失败");
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let final: AgentFinal | null = null;

  while (true) {
    const { done, value } = await reader.read();
    if (value) {
      buffer += decoder.decode(value, { stream: !done });
      let separator = buffer.indexOf("\n\n");
      while (separator >= 0) {
        const chunk = buffer.slice(0, separator);
        buffer = buffer.slice(separator + 2);
        const event = parseSSEChunk(chunk);
        if (event) {
          const payload = JSON.parse(event.data) as unknown;
          if (event.type === "message_delta") {
            const message = payload as { text?: string };
            if (typeof message.text === "string") options.onMessageDelta(message.text);
          } else if (event.type === "status") {
            const status = payload as { text?: string };
            if (typeof status.text === "string") options.onStatus?.(status.text);
          } else if (event.type === "tool_call" || event.type === "tool_result") {
            const tool = payload as AgentToolEvent;
            if (tool.id && tool.name && tool.title && tool.status) options.onTool?.(tool);
          } else if (event.type === "artifact") {
            const artifact = payload as AgentArtifact;
            if (artifact.id && artifact.type && artifact.title) options.onArtifact?.(artifact);
          } else if (event.type === "approval_required") {
            const approval = payload as AgentApproval;
            if (approval.id && approval.sessionId && approval.toolName) options.onApproval?.(approval);
          } else if (event.type === "final") {
            final = payload as AgentFinal;
          } else if (event.type === "error") {
            const error = payload as AgentStreamError;
            throw new Error(error.error || "Agent 请求失败");
          }
        }
        separator = buffer.indexOf("\n\n");
      }
    }
    if (done) break;
  }

  if (!final) throw new Error("Agent 流式响应未返回最终结果");
  return final;
}

function parseSSEChunk(chunk: string): { type: string; data: string } | null {
  let type = "message";
  const data: string[] = [];
  for (const line of chunk.split(/\r?\n/)) {
    if (line.startsWith("event:")) type = line.slice(6).trim();
    if (line.startsWith("data:")) data.push(line.slice(5).trimStart());
  }
  if (!data.length) return null;
  return { type, data: data.join("\n") };
}
