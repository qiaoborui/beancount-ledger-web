export type ApiEndpoint = {
  id: string;
  url: string;
  enabled: boolean;
  label?: string;
  clusterId?: string;
  apiVersion?: number;
  ledgerVersion?: string;
};

export type ApiEndpointSettings = {
  activeId: string;
  autoSelect: boolean;
  clusterId?: string;
  apiVersion?: number;
  endpoints: ApiEndpoint[];
};

export type ApiEndpointProbeResult = {
  id: string;
  ok: boolean;
  latencyMs?: number;
  error?: string;
  clusterId?: string;
  apiVersion?: number;
  ledgerVersion?: string;
  capabilities?: string[];
};

export type ApiEndpointRuntimeStatus = {
  id: string;
  reachable?: boolean;
  latencyMs?: number;
  consecutiveFailures: number;
  lastSuccessAt?: number;
  lastFailureAt?: number;
  cooldownUntil?: number;
  lastError?: string;
};

export type ApiRequestKind = "read" | "auth" | "write" | "health";

const storageKey = "ledger_api_endpoints:v2";
const legacyStorageKey = "ledger_api_endpoints:v1";
const endpointChangeEvent = "ledger-api-endpoints-change";
const endpointHealthChangeEvent = "ledger-api-endpoint-health-change";
const sameOriginEndpointId = "same-origin";
const sessionAuthedKey = "ledger_authed";
const knownAuthKey = "ledger_auth_known";
const supportedApiVersion = 1;
const fallbackStatusCodes = new Set([408, 425, 429, 500, 502, 503, 504, 520, 522, 524]);
const safeMethodTimeoutMs = 4500;
const cooldownBaseMs = 15000;
const cooldownMaxMs = 5 * 60 * 1000;
const stickyReadDurationMs = 30000;
let generatedEndpointId = 0;
let stickyReadEndpointId = "";
let stickyReadUntil = 0;
let volatileSettings: ApiEndpointSettings | null = null;
let volatileSettingsOnly = false;
const runtimeStatuses = new Map<string, ApiEndpointRuntimeStatus>();
const responseEndpointIds = new WeakMap<Response, string>();

type LedgerWindow = Window & {
  __ledgerApiFetchInstalled?: boolean;
  __ledgerOriginalFetch?: typeof fetch;
};

export const sameOriginApiEndpoint: ApiEndpoint = { id: sameOriginEndpointId, url: "", enabled: true, label: "当前站点" };
export const apiEndpointSettingsChangeEvent = endpointChangeEvent;
export const apiEndpointHealthChangeEvent = endpointHealthChangeEvent;

export function isSameOriginApiEndpoint(endpoint: ApiEndpoint) {
  return endpoint.id === sameOriginEndpointId || endpoint.url === "";
}

export function displayApiEndpointUrl(endpoint: ApiEndpoint) {
  if (!isSameOriginApiEndpoint(endpoint)) return endpoint.url;
  if (typeof window === "undefined") return "当前站点";
  return window.location.origin;
}

export function apiEndpointLabel(endpoint: ApiEndpoint) {
  return endpoint.label?.trim() || (isSameOriginApiEndpoint(endpoint) ? "当前站点" : endpoint.url);
}

export function normalizeApiEndpointUrl(raw: string): string {
  const value = raw.trim();
  if (!value) throw new Error("请输入后端地址");
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error("请输入完整的 HTTPS 地址");
  }
  if (url.protocol !== "https:") throw new Error("自定义后端必须使用 HTTPS");
  if (url.username || url.password) throw new Error("后端地址不能包含用户名或密码");
  url.hash = "";
  url.search = "";
  url.pathname = url.pathname.replace(/\/+$/, "");
  return url.toString().replace(/\/+$/, "");
}

export function createApiEndpointId() {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) return `endpoint-${crypto.randomUUID()}`;
  generatedEndpointId += 1;
  return `endpoint-${Date.now()}-${generatedEndpointId}`;
}

export function readApiEndpointSettings(): ApiEndpointSettings {
  if (typeof window === "undefined") return defaultApiEndpointSettings();
  if (volatileSettingsOnly && volatileSettings) return volatileSettings;
  try {
    const raw = window.localStorage.getItem(storageKey) ?? window.localStorage.getItem(legacyStorageKey);
    if (!raw) return volatileSettings ?? defaultApiEndpointSettings();
    const settings = sanitizeApiEndpointSettings(JSON.parse(raw) as Partial<ApiEndpointSettings>);
    volatileSettings = settings;
    return settings;
  } catch {
    return volatileSettings ?? defaultApiEndpointSettings();
  }
}

export function writeApiEndpointSettings(settings: ApiEndpointSettings) {
  if (typeof window === "undefined") return;
  const next = sanitizeApiEndpointSettings(settings);
  volatileSettings = next;
  try {
    const serialized = JSON.stringify({
      activeId: next.activeId,
      autoSelect: next.autoSelect,
      clusterId: next.clusterId,
      apiVersion: next.apiVersion,
      endpoints: next.endpoints,
    });
    window.localStorage.setItem(storageKey, serialized);
    volatileSettingsOnly = window.localStorage.getItem(storageKey) !== serialized;
    window.localStorage.removeItem(legacyStorageKey);
  } catch {
    volatileSettingsOnly = true;
  }
  window.dispatchEvent(new Event(endpointChangeEvent));
}

export function apiEndpointLedgerScope(settings = readApiEndpointSettings()) {
  const clusterId = settings.clusterId?.trim();
  if (clusterId) return `cluster:${encodeURIComponent(clusterId)}`;
  const active = settings.endpoints.find((endpoint) => endpoint.id === settings.activeId) ?? sameOriginApiEndpoint;
  return `endpoint:${encodeURIComponent(active.id)}`;
}

export function apiEndpointPreviousLedgerScope(settings = readApiEndpointSettings()) {
  const clusterId = settings.clusterId?.trim();
  const sameOrigin = settings.endpoints.find((endpoint) => endpoint.id === sameOriginEndpointId);
  if (clusterId && settings.activeId === sameOriginEndpointId && sameOrigin?.clusterId === clusterId && sameOrigin.apiVersion === supportedApiVersion) {
    return `endpoint:${sameOriginEndpointId}`;
  }
  return undefined;
}

export function apiEndpointAuthScope(settings = readApiEndpointSettings()) {
  return settings.activeId || sameOriginEndpointId;
}

export function apiEndpointAuthStorageKey(key: string, endpointId = apiEndpointAuthScope()) {
  return `${key}:${endpointId}`;
}

export function hasKnownApiEndpointAuthentication(endpointId: string) {
  if (typeof window === "undefined") return false;
  try {
    return window.sessionStorage?.getItem(apiEndpointAuthStorageKey(sessionAuthedKey, endpointId)) === "1"
      || window.localStorage?.getItem(apiEndpointAuthStorageKey(knownAuthKey, endpointId)) === "1"
      || (endpointId === sameOriginEndpointId && (window.sessionStorage?.getItem(sessionAuthedKey) === "1" || window.localStorage?.getItem(knownAuthKey) === "1"));
  } catch {
    return false;
  }
}

export function apiEndpointScopedStorageKey(key: string, settings = readApiEndpointSettings()) {
  return apiEndpointStorageKeyForLedgerScope(key, apiEndpointLedgerScope(settings));
}

export function apiEndpointStorageKeyForLedgerScope(key: string, ledgerScope: string) {
  return `${key}:${ledgerScope}`;
}

export function buildApiEndpointRequestUrl(endpoint: ApiEndpoint, pathWithSearch: string) {
  if (isSameOriginApiEndpoint(endpoint)) return pathWithSearch;
  return `${endpoint.url}${pathWithSearch.startsWith("/") ? pathWithSearch : `/${pathWithSearch}`}`;
}

export function activeApiEndpointRequestUrl(pathWithSearch: string, settings = readApiEndpointSettings()) {
  return buildApiEndpointRequestUrl(activeApiEndpoint(settings), pathWithSearch);
}

export function orderedApiEndpoints(settings = readApiEndpointSettings(), method = "GET", now = Date.now()) {
  const enabled = settings.endpoints.filter((endpoint) => endpoint.enabled);
  const active = enabled.find((endpoint) => endpoint.id === settings.activeId) ?? enabled[0] ?? sameOriginApiEndpoint;
  if (!isSafeMethod(method)) return [active];

  if (!endpointMatchesLedger(settings, active)) return [active];

  const compatible = enabled.filter((endpoint) => endpointMatchesLedger(settings, endpoint) && (endpoint.id === active.id || hasKnownApiEndpointAuthentication(endpoint.id)));
  const available = compatible.filter((endpoint) => !endpointCoolingDown(endpoint.id, now));
  const candidates = available.length ? available : compatible;
  if (stickyReadUntil <= now) {
    stickyReadEndpointId = "";
    stickyReadUntil = 0;
  }
  const sticky = candidates.find((endpoint) => endpoint.id === stickyReadEndpointId);
  const rest = candidates.filter((endpoint) => endpoint.id !== sticky?.id && endpoint.id !== active.id);
  rest.sort(compareEndpointRuntimeStatus);
  if (sticky) return [sticky, ...(active.id === sticky.id || !candidates.includes(active) ? [] : [active]), ...rest];
  return [active, ...rest.filter((endpoint) => endpoint.id !== active.id)];
}

export function activeApiEndpoint(settings = readApiEndpointSettings()) {
  const enabled = settings.endpoints.filter((endpoint) => endpoint.enabled);
  return enabled.find((endpoint) => endpoint.id === settings.activeId) ?? enabled[0] ?? sameOriginApiEndpoint;
}

export function withActiveApiEndpoint(settings: ApiEndpointSettings, activeId: string) {
  const active = settings.endpoints.find((endpoint) => endpoint.id === activeId && endpoint.enabled && endpointMatchesLedger(settings, endpoint));
  return active ? { ...settings, activeId: active.id } : settings;
}

export function applyApiEndpointProbe(settings: ApiEndpointSettings, endpointId: string, result: ApiEndpointProbeResult) {
  if (!result.ok) throw new Error(result.error || "后端不可用");
  if (result.apiVersion === undefined) throw new Error("后端未提供 API 版本，请先升级后端");
  if (result.apiVersion !== supportedApiVersion) {
    throw new Error(`后端 API 版本不兼容：${result.apiVersion}`);
  }
  const resultClusterId = result.clusterId?.trim();
  if (!resultClusterId) throw new Error("后端未提供账本标识，请配置 LEDGER_CLUSTER_ID 或升级后端");
  if (settings.clusterId && settings.clusterId !== resultClusterId) {
    throw new Error("这个后端连接的是另一个账本，不能加入当前后端组");
  }
  const clusterId = settings.clusterId || resultClusterId;
  const apiVersion = settings.apiVersion || result.apiVersion;
  return {
    ...settings,
    clusterId,
    apiVersion,
    endpoints: settings.endpoints.map((endpoint) => endpoint.id === endpointId ? {
      ...endpoint,
      clusterId: resultClusterId,
      apiVersion: result.apiVersion,
      ledgerVersion: result.ledgerVersion,
    } : endpoint),
  };
}

export function apiEndpointRuntimeStatus(id: string) {
  return runtimeStatuses.get(id) ?? { id, consecutiveFailures: 0 };
}

export function apiEndpointRuntimeStatuses() {
  return Array.from(runtimeStatuses.values());
}

export function apiEndpointForResponse(response: Response) {
  return responseEndpointIds.get(response);
}

export function resetApiEndpointRuntimeState() {
  runtimeStatuses.clear();
  stickyReadEndpointId = "";
  stickyReadUntil = 0;
  volatileSettings = null;
  volatileSettingsOnly = false;
}

export async function apiFetch(input: RequestInfo | URL, init?: RequestInit, options: { kind?: ApiRequestKind; endpoint?: ApiEndpoint } = {}): Promise<Response> {
  const target = apiFetchTarget(input, init);
  if (!target) return originalFetch()(input, init);

  const kind = options.kind ?? requestKind(target.pathWithSearch, target.method);
  const settings = readApiEndpointSettings();
  const active = activeApiEndpoint(settings);
  const attempts = options.endpoint
    ? [options.endpoint]
    : kind === "read"
      ? orderedApiEndpoints(settings, target.method)
      : [activeApiEndpoint(settings)];
  if (!attempts.length) return originalFetch()(input, init);

  const fetcher = originalFetch();
  let lastError: unknown;
  let lastResponse: Response | null = null;
  for (let index = 0; index < attempts.length; index += 1) {
    const endpoint = attempts[index];
    const url = buildApiEndpointRequestUrl(endpoint, target.pathWithSearch);
    const canRetry = kind === "read" && index < attempts.length - 1;
    const attempt = requestInitForEndpoint(input, init, endpoint, target.method, canRetry);
    const startedAt = performanceNow();
    try {
      const response = await fetcher(url, attempt.init);
      responseEndpointIds.set(response, endpoint.id);
      const latencyMs = Math.max(1, Math.round(performanceNow() - startedAt));
      if (kind === "read" && endpoint.id !== active.id && (response.status === 401 || response.status === 403)) {
        forgetKnownApiEndpointAuthentication(endpoint.id);
        lastError = new Error("备用后端登录已失效，请先切换到该后端重新登录");
        if (canRetry) continue;
        break;
      }
      if (canRetry && fallbackStatusCodes.has(response.status)) {
        recordEndpointFailure(endpoint.id, `HTTP ${response.status}`);
        lastResponse = response;
        continue;
      }
      recordEndpointSuccess(endpoint.id, latencyMs);
      if (kind === "read") {
        if (endpoint.id === active.id) {
          stickyReadEndpointId = "";
          stickyReadUntil = 0;
        } else if (stickyReadEndpointId !== endpoint.id) {
          stickyReadEndpointId = endpoint.id;
          stickyReadUntil = Date.now() + stickyReadDurationMs;
        }
      }
      return response;
    } catch (error) {
      lastError = error;
      recordEndpointFailure(endpoint.id, error instanceof Error ? error.message : "请求失败");
      if (!canRetry || isAbortFromCaller(error, init)) throw error;
    } finally {
      if (attempt.timeoutId !== undefined) window.clearTimeout(attempt.timeoutId);
    }
  }

  if (lastResponse) return lastResponse;
  throw lastError instanceof Error ? lastError : new Error("请求失败，请稍后重试");
}

export function installApiEndpointFetchInterceptor() {
  if (typeof window === "undefined") return;
  const ledgerWindow = window as LedgerWindow;
  if (ledgerWindow.__ledgerApiFetchInstalled) return;
  ledgerWindow.__ledgerOriginalFetch = window.fetch.bind(window);
  ledgerWindow.__ledgerApiFetchInstalled = true;
  window.fetch = (input: RequestInfo | URL, init?: RequestInit) => apiFetch(input, init);
}

export async function probeApiEndpoint(endpoint: ApiEndpoint, timeoutMs = 8000): Promise<ApiEndpointProbeResult> {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), timeoutMs);
  const startedAt = performanceNow();
  try {
    const response = await apiFetch("/api/health", {
      method: "GET",
      cache: "no-store",
      credentials: isSameOriginApiEndpoint(endpoint) ? "same-origin" : "include",
      signal: controller.signal,
    }, { kind: "health", endpoint });
    const latencyMs = Math.max(1, Math.round(performanceNow() - startedAt));
    const data = await response.clone().json().catch(() => ({})) as {
      clusterId?: string;
      apiVersion?: number;
      ledgerVersion?: string;
      capabilities?: string[];
      error?: string;
    };
    if (!response.ok) return { id: endpoint.id, ok: false, latencyMs, error: data.error || `HTTP ${response.status}`, ...healthMetadata(data) };
    return { id: endpoint.id, ok: true, latencyMs, ...healthMetadata(data) };
  } catch (error) {
    return { id: endpoint.id, ok: false, error: error instanceof Error ? error.message : "测速失败" };
  } finally {
    window.clearTimeout(timeout);
  }
}

function defaultApiEndpointSettings(): ApiEndpointSettings {
  return { activeId: sameOriginEndpointId, autoSelect: false, endpoints: [sameOriginApiEndpoint] };
}

function sanitizeApiEndpointSettings(raw: Partial<ApiEndpointSettings>): ApiEndpointSettings {
  const seen = new Set<string>();
  const seenIds = new Set<string>([sameOriginEndpointId]);
  const customEndpoints = Array.isArray(raw.endpoints) ? raw.endpoints : [];
  const rawSameOrigin = customEndpoints.find((endpoint) => endpoint?.id === sameOriginEndpointId);
  const endpoints: ApiEndpoint[] = [{
    ...sameOriginApiEndpoint,
    clusterId: typeof rawSameOrigin?.clusterId === "string" ? rawSameOrigin.clusterId : undefined,
    apiVersion: typeof rawSameOrigin?.apiVersion === "number" ? rawSameOrigin.apiVersion : undefined,
    ledgerVersion: typeof rawSameOrigin?.ledgerVersion === "string" ? rawSameOrigin.ledgerVersion : undefined,
  }];
  for (const endpoint of customEndpoints) {
    if (!endpoint || typeof endpoint !== "object") continue;
    if (endpoint.id === sameOriginEndpointId) continue;
    if (typeof endpoint.url !== "string") continue;
    let url: string;
    try {
      url = normalizeApiEndpointUrl(endpoint.url);
    } catch {
      continue;
    }
    if (seen.has(url)) continue;
    seen.add(url);
    const requestedId = typeof endpoint.id === "string" && endpoint.id ? endpoint.id : "";
    const id = requestedId && !seenIds.has(requestedId) ? requestedId : createApiEndpointId();
    seenIds.add(id);
    endpoints.push({
      id,
      url,
      enabled: endpoint.enabled !== false,
      label: typeof endpoint.label === "string" ? endpoint.label.trim() : undefined,
      clusterId: typeof endpoint.clusterId === "string" ? endpoint.clusterId : undefined,
      apiVersion: typeof endpoint.apiVersion === "number" ? endpoint.apiVersion : undefined,
      ledgerVersion: typeof endpoint.ledgerVersion === "string" ? endpoint.ledgerVersion : undefined,
    });
  }
  const activeId = typeof raw.activeId === "string" && endpoints.some((endpoint) => endpoint.id === raw.activeId)
    ? raw.activeId
    : sameOriginEndpointId;
  return {
    activeId,
    autoSelect: Boolean(raw.autoSelect),
    clusterId: typeof raw.clusterId === "string" && raw.clusterId.trim() ? raw.clusterId.trim() : undefined,
    apiVersion: typeof raw.apiVersion === "number" ? raw.apiVersion : undefined,
    endpoints,
  };
}

function apiFetchTarget(input: RequestInfo | URL, init?: RequestInit): { pathWithSearch: string; method: string } | null {
  const method = (init?.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase();
  if (typeof input === "string" && input.startsWith("/api/")) return { pathWithSearch: input, method };
  if (input instanceof URL) return sameOriginApiPath(input, method);
  if (input instanceof Request) {
    const requestUrl = requestUrlFromString(input.url);
    return requestUrl ? sameOriginApiPath(requestUrl, method) : null;
  }
  const requestUrl = requestUrlFromString(String(input));
  return requestUrl ? sameOriginApiPath(requestUrl, method) : null;
}

function sameOriginApiPath(url: URL, method: string) {
  if (typeof window === "undefined") return null;
  if (url.origin !== window.location.origin) return null;
  if (!url.pathname.startsWith("/api/")) return null;
  return { pathWithSearch: `${url.pathname}${url.search}`, method };
}

function requestUrlFromString(value: string) {
  if (typeof window === "undefined") return null;
  try {
    return new URL(value, window.location.origin);
  } catch {
    return null;
  }
}

function requestInitForEndpoint(input: RequestInfo | URL, init: RequestInit | undefined, endpoint: ApiEndpoint, method: string, timeout: boolean): { init: RequestInit | undefined; timeoutId?: number } {
  const next: RequestInit = { ...(init ?? {}) };
  if (input instanceof Request) {
    next.method = init?.method ?? input.method;
    next.headers = init?.headers ?? input.headers;
    next.body = init?.body ?? requestBodyForClone(input, method);
    next.cache = init?.cache ?? input.cache;
    next.redirect = init?.redirect ?? input.redirect;
    next.referrer = init?.referrer ?? input.referrer;
    next.referrerPolicy = init?.referrerPolicy ?? input.referrerPolicy;
    next.integrity = init?.integrity ?? input.integrity;
    next.keepalive = init?.keepalive ?? input.keepalive;
  }
  next.credentials = isSameOriginApiEndpoint(endpoint) ? (next.credentials ?? "same-origin") : "include";
  if (timeout && !next.signal) {
    const controller = new AbortController();
    const timeoutId = window.setTimeout(() => controller.abort(), safeMethodTimeoutMs);
    next.signal = controller.signal;
    return { init: next, timeoutId };
  }
  return { init: next };
}

function requestBodyForClone(input: Request, method: string) {
  if (isSafeMethod(method)) return undefined;
  return input.clone().body;
}

function isSafeMethod(method: string) {
  return method === "GET" || method === "HEAD" || method === "OPTIONS";
}

function requestKind(pathWithSearch: string, method: string): ApiRequestKind {
  if (pathWithSearch === "/api/health") return "health";
  if (pathWithSearch.startsWith("/api/auth/") || pathWithSearch.startsWith("/api/passkey/") || pathWithSearch.startsWith("/api/quick-unlock/")) return "auth";
  return isSafeMethod(method) ? "read" : "write";
}

function isAbortFromCaller(error: unknown, init?: RequestInit) {
  return error instanceof DOMException && error.name === "AbortError" && Boolean(init?.signal?.aborted);
}

function originalFetch() {
  if (typeof window === "undefined") return fetch;
  return ((window as LedgerWindow).__ledgerOriginalFetch ?? window.fetch).bind(window);
}

function endpointCoolingDown(id: string, now: number) {
  return (runtimeStatuses.get(id)?.cooldownUntil ?? 0) > now;
}

function endpointMatchesLedger(settings: ApiEndpointSettings, endpoint: ApiEndpoint) {
  const clusterId = settings.clusterId?.trim();
  if (!clusterId) return endpoint.id === settings.activeId;
  return endpoint.clusterId === clusterId && endpoint.apiVersion === supportedApiVersion;
}

function forgetKnownApiEndpointAuthentication(endpointId: string) {
  if (typeof window === "undefined") return;
  try {
    window.sessionStorage?.removeItem(apiEndpointAuthStorageKey(sessionAuthedKey, endpointId));
    window.localStorage?.removeItem(apiEndpointAuthStorageKey(knownAuthKey, endpointId));
  } catch {
    // Storage may be unavailable in private mode.
  }
}

function compareEndpointRuntimeStatus(left: ApiEndpoint, right: ApiEndpoint) {
  const leftStatus = apiEndpointRuntimeStatus(left.id);
  const rightStatus = apiEndpointRuntimeStatus(right.id);
  if (Boolean(leftStatus.reachable) !== Boolean(rightStatus.reachable)) return leftStatus.reachable ? -1 : 1;
  if ((leftStatus.lastSuccessAt ?? 0) !== (rightStatus.lastSuccessAt ?? 0)) return (rightStatus.lastSuccessAt ?? 0) - (leftStatus.lastSuccessAt ?? 0);
  return (leftStatus.latencyMs ?? Infinity) - (rightStatus.latencyMs ?? Infinity);
}

function recordEndpointSuccess(id: string, latencyMs: number) {
  runtimeStatuses.set(id, { id, reachable: true, latencyMs, consecutiveFailures: 0, lastSuccessAt: Date.now() });
  dispatchEndpointHealthChange();
}

function recordEndpointFailure(id: string, error: string) {
  const current = apiEndpointRuntimeStatus(id);
  const consecutiveFailures = current.consecutiveFailures + 1;
  const cooldownMs = Math.min(cooldownMaxMs, cooldownBaseMs * 2 ** Math.max(0, consecutiveFailures - 1));
  runtimeStatuses.set(id, {
    ...current,
    id,
    reachable: false,
    consecutiveFailures,
    lastFailureAt: Date.now(),
    cooldownUntil: Date.now() + cooldownMs,
    lastError: error,
  });
  if (stickyReadEndpointId === id) stickyReadEndpointId = "";
  if (!stickyReadEndpointId) stickyReadUntil = 0;
  dispatchEndpointHealthChange();
}

function dispatchEndpointHealthChange() {
  if (typeof window !== "undefined") window.dispatchEvent(new Event(endpointHealthChangeEvent));
}

function performanceNow() {
  return typeof performance === "undefined" ? Date.now() : performance.now();
}

function healthMetadata(data: { clusterId?: string; apiVersion?: number; ledgerVersion?: string; capabilities?: string[] }) {
  return {
    clusterId: typeof data.clusterId === "string" && data.clusterId ? data.clusterId : undefined,
    apiVersion: typeof data.apiVersion === "number" ? data.apiVersion : undefined,
    ledgerVersion: typeof data.ledgerVersion === "string" ? data.ledgerVersion : undefined,
    capabilities: Array.isArray(data.capabilities) ? data.capabilities.filter((value): value is string => typeof value === "string") : undefined,
  };
}
