import { apiFetch, currentApiEndpoint, readApiEndpointSettings } from "@/lib/apiEndpoints";
import { readJson } from "@/lib/clientFetch";
import i18n from "@/i18n";

export type AgentAccessTokenSummary = {
  id: string;
  name: string;
  createdAt: string;
  expiresAt: string;
  lastUsedAt?: string;
  revokedAt?: string;
  scopes: string[];
  legacy?: boolean;
};

export type CreatedAgentAccessToken = {
  token: string;
  credential: AgentAccessTokenSummary;
};

export class AgentAccessTokenManagementUnsupportedError extends Error {
  constructor() {
    super(i18n.t("agentTokens.unsupportedError"));
  }
}

export async function listAgentAccessTokens(): Promise<AgentAccessTokenSummary[]> {
  const endpoint = currentApiEndpoint(readApiEndpointSettings());
  if (endpoint.capabilities && !endpoint.capabilities.includes("agent-access-tokens-v2")) {
    throw new AgentAccessTokenManagementUnsupportedError();
  }
  const response = await apiFetch("/api/agent/access-tokens", { method: "GET", cache: "no-store" }, { kind: "auth", endpoint });
  const data = await readJson<{ tokens?: AgentAccessTokenSummary[]; error?: string }>(response, {});
  if (response.status === 404 || response.status === 405) throw new AgentAccessTokenManagementUnsupportedError();
  if (!response.ok) throw new Error(data.error || i18n.t("agentTokens.readFailed", { status: response.status }));
  return Array.isArray(data.tokens) ? data.tokens : [];
}

export async function createAgentAccessToken(name: string, scopes: string[] = ["read"]): Promise<CreatedAgentAccessToken> {
  const response = await apiFetch("/api/agent/access-tokens", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, scopes }),
  }, { kind: "auth" });
  const data = await readJson<CreatedAgentAccessToken & { error?: string }>(response);
  if (!response.ok) throw new Error(data.error || i18n.t("agentTokens.createFailed", { status: response.status }));
  return data;
}

export async function revokeAgentAccessToken(id: string): Promise<void> {
  const response = await apiFetch(`/api/agent/access-tokens/${encodeURIComponent(id)}`, {
    method: "DELETE",
  }, { kind: "auth" });
  if (response.ok) return;
  const data = await readJson<{ error?: string }>(response, {});
  throw new Error(data.error || i18n.t("agentTokens.revokeFailed", { status: response.status }));
}
