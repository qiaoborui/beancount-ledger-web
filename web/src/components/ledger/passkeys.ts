import { apiEndpointForResponse, apiFetch, currentApiEndpoint, readApiEndpointSettings, type ApiEndpoint } from "@/lib/apiEndpoints";
import { readJson } from "@/lib/clientFetch";

export type PasskeyCredentialSummary = {
  id: string;
  name: string;
  transports?: string[];
  backupEligible?: boolean;
  backupState?: boolean;
  createdAt?: string;
  lastUsedAt?: string;
};

export type PasskeyDeleteResult = {
  ok: boolean;
  remaining: number;
};

export type PasskeyCredentialList = {
  credentials: PasskeyCredentialSummary[];
  endpoint: ApiEndpoint;
};

export class PasskeyManagementUnsupportedError extends Error {
  constructor(public endpoint: ApiEndpoint) {
    super("当前后端版本不支持 Passkey 管理，请升级后端后重试");
  }
}

export async function listPasskeyCredentials(endpoint = currentApiEndpoint(readApiEndpointSettings())): Promise<PasskeyCredentialList> {
  if (endpoint.capabilities && !endpoint.capabilities.includes("passkey-management-v1")) {
    throw new PasskeyManagementUnsupportedError(endpoint);
  }
  const response = await apiFetch("/api/passkey/credentials", { method: "GET" }, { kind: "auth", endpoint });
  const responseEndpointId = apiEndpointForResponse(response);
  const responseEndpoint = readApiEndpointSettings().endpoints.find((candidate) => candidate.id === responseEndpointId) ?? endpoint;
  const data = await readJson<{ credentials?: PasskeyCredentialSummary[]; error?: string }>(response, {});
  if (response.status === 404 || response.status === 405) throw new PasskeyManagementUnsupportedError(responseEndpoint);
  if (!response.ok) throw new Error(data.error || `读取 Passkey 失败：${response.status}`);
  return { credentials: Array.isArray(data.credentials) ? data.credentials : [], endpoint: responseEndpoint };
}

export async function renamePasskeyCredential(endpoint: ApiEndpoint, id: string, name: string): Promise<PasskeyCredentialSummary> {
  const response = await apiFetch(`/api/passkey/credentials/${encodeURIComponent(id)}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name }),
  }, { kind: "auth", endpoint });
  const data = await readJson<PasskeyCredentialSummary & { error?: string }>(response);
  if (!response.ok) throw new Error(data.error || `重命名 Passkey 失败：${response.status}`);
  return data;
}

export async function deletePasskeyCredential(endpoint: ApiEndpoint, id: string, password: string): Promise<PasskeyDeleteResult> {
  const response = await apiFetch(`/api/passkey/credentials/${encodeURIComponent(id)}`, {
    method: "DELETE",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ password }),
  }, { kind: "auth", endpoint });
  const data = await readJson<PasskeyDeleteResult & { error?: string }>(response, { ok: false, remaining: 0 });
  if (!response.ok) throw new Error(response.status === 401 ? "主密码不正确" : data.error || `删除 Passkey 失败：${response.status}`);
  return data;
}

export function passkeyBackupPresentation(credential: PasskeyCredentialSummary) {
  if (credential.backupEligible == null) return { label: "状态未知", description: "此凭据注册时没有提供同步状态" };
  if (!credential.backupEligible) return { label: "设备绑定", description: "凭据保存在单一验证器中" };
  if (credential.backupState) return { label: "已同步", description: "凭据可通过密码管理器同步" };
  return { label: "可同步", description: "验证器支持备份，但当前未报告已同步" };
}
