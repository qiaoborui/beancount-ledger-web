import { apiEndpointForResponse, apiFetch, currentApiEndpoint, readApiEndpointSettings, type ApiEndpoint } from "@/lib/apiEndpoints";
import { readJson } from "@/lib/clientFetch";
import i18n from "@/i18n";

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
    super(i18n.t("passkeys.unsupportedError"));
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
  if (!response.ok) throw new Error(data.error || i18n.t("passkeys.readFailed", { status: response.status }));
  return { credentials: Array.isArray(data.credentials) ? data.credentials : [], endpoint: responseEndpoint };
}

export async function renamePasskeyCredential(endpoint: ApiEndpoint, id: string, name: string): Promise<PasskeyCredentialSummary> {
  const response = await apiFetch(`/api/passkey/credentials/${encodeURIComponent(id)}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name }),
  }, { kind: "auth", endpoint });
  const data = await readJson<PasskeyCredentialSummary & { error?: string }>(response);
  if (!response.ok) throw new Error(data.error || i18n.t("passkeys.renameFailed", { status: response.status }));
  return data;
}

export async function deletePasskeyCredential(endpoint: ApiEndpoint, id: string, password: string): Promise<PasskeyDeleteResult> {
  const response = await apiFetch(`/api/passkey/credentials/${encodeURIComponent(id)}`, {
    method: "DELETE",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ password }),
  }, { kind: "auth", endpoint });
  const data = await readJson<PasskeyDeleteResult & { error?: string }>(response, { ok: false, remaining: 0 });
  if (!response.ok) throw new Error(response.status === 401 ? i18n.t("passkeys.wrongPassword") : data.error || i18n.t("passkeys.deleteFailed", { status: response.status }));
  return data;
}

export function passkeyBackupPresentation(credential: PasskeyCredentialSummary) {
  if (credential.backupEligible == null) return { label: i18n.t("passkeys.backupUnknown"), description: i18n.t("passkeys.backupUnknownDesc") };
  if (!credential.backupEligible) return { label: i18n.t("passkeys.backupBound"), description: i18n.t("passkeys.backupBoundDesc") };
  if (credential.backupState) return { label: i18n.t("passkeys.backupSynced"), description: i18n.t("passkeys.backupSyncedDesc") };
  return { label: i18n.t("passkeys.backupSyncable"), description: i18n.t("passkeys.backupSyncableDesc") };
}
