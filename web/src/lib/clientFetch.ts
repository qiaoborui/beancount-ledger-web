import { apiEndpointForResponse, apiFetch, type ApiRequestKind } from "./apiEndpoints";

export class ApiResponseError extends Error {
  status: number;
  endpointId?: string;
  kind: ApiRequestKind;

  constructor(message: string, response: Response, kind: ApiRequestKind) {
    super(message);
    this.name = "ApiResponseError";
    this.status = response.status;
    this.endpointId = apiEndpointForResponse(response);
    this.kind = kind;
  }
}

export async function readJson<T>(response: Response, fallback?: T): Promise<T> {
  const text = await response.text();
  if (!text.trim()) {
    if (fallback !== undefined) return fallback;
    throw new Error(response.ok ? "服务端返回了空响应，请稍后重试" : `请求失败：${response.status}`);
  }
  try {
    return JSON.parse(text) as T;
  } catch {
    if (!response.ok) throw new Error(text || `请求失败：${response.status}`);
    throw new Error("服务端返回了无法解析的数据，请稍后重试");
  }
}

export async function fetchJson<T>(input: RequestInfo | URL, init?: RequestInit, fallback?: T, options: { kind?: ApiRequestKind } = {}): Promise<T> {
  const kind = options.kind ?? inferRequestKind(input, init);
  const response = await apiFetch(input, init, { kind });
  let data: T & { error?: string };
  try {
    data = await readJson<T & { error?: string }>(response, fallback as (T & { error?: string }) | undefined);
  } catch (error) {
    if (!response.ok) throw new ApiResponseError(error instanceof Error ? error.message : `请求失败：${response.status}`, response, kind);
    throw error;
  }
  if (!response.ok) throw new ApiResponseError(data?.error || `请求失败：${response.status}`, response, kind);
  return data as T;
}

function inferRequestKind(input: RequestInfo | URL, init?: RequestInit): ApiRequestKind {
  const value = input instanceof Request ? input.url : String(input);
  const method = (init?.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase();
  if (value.includes("/api/auth/") || value.includes("/api/passkey/") || value.includes("/api/quick-unlock/")) return "auth";
  return method === "GET" || method === "HEAD" || method === "OPTIONS" ? "read" : "write";
}
