import { apiFetch, currentApiEndpoint, readApiEndpointSettings } from "@/lib/apiEndpoints";
import { readJson } from "@/lib/clientFetch";

export type AgentAccessTokenSummary = {
  id: string;
  name: string;
  createdAt: string;
  expiresAt: string;
  lastUsedAt?: string;
  revokedAt?: string;
};

export type CreatedAgentAccessToken = {
  token: string;
  credential: AgentAccessTokenSummary;
};

export class AgentAccessTokenManagementUnsupportedError extends Error {
  constructor() {
    super("当前后端版本不支持 Agent 访问令牌，请升级后端后重试");
  }
}

export async function listAgentAccessTokens(): Promise<AgentAccessTokenSummary[]> {
  const endpoint = currentApiEndpoint(readApiEndpointSettings());
  if (endpoint.capabilities && !endpoint.capabilities.includes("agent-access-tokens-v1")) {
    throw new AgentAccessTokenManagementUnsupportedError();
  }
  const response = await apiFetch("/api/agent/access-tokens", { method: "GET", cache: "no-store" }, { kind: "auth", endpoint });
  const data = await readJson<{ tokens?: AgentAccessTokenSummary[]; error?: string }>(response, {});
  if (response.status === 404 || response.status === 405) throw new AgentAccessTokenManagementUnsupportedError();
  if (!response.ok) throw new Error(data.error || `读取 Agent 访问令牌失败：${response.status}`);
  return Array.isArray(data.tokens) ? data.tokens : [];
}

export async function createAgentAccessToken(name: string): Promise<CreatedAgentAccessToken> {
  const response = await apiFetch("/api/agent/access-tokens", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name }),
  }, { kind: "auth" });
  const data = await readJson<CreatedAgentAccessToken & { error?: string }>(response);
  if (!response.ok) throw new Error(data.error || `创建 Agent 访问令牌失败：${response.status}`);
  return data;
}

export async function revokeAgentAccessToken(id: string): Promise<void> {
  const response = await apiFetch(`/api/agent/access-tokens/${encodeURIComponent(id)}`, {
    method: "DELETE",
  }, { kind: "auth" });
  if (response.ok) return;
  const data = await readJson<{ error?: string }>(response, {});
  throw new Error(data.error || `吊销 Agent 访问令牌失败：${response.status}`);
}
