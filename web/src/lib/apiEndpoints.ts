export type ApiEndpoint = {
  id: string;
  url: string;
  enabled: boolean;
};

export type ApiEndpointSettings = {
  activeId: string;
  autoSelect: boolean;
  endpoints: ApiEndpoint[];
};

export type ApiEndpointProbeResult = {
  id: string;
  ok: boolean;
  latencyMs?: number;
  error?: string;
};

const storageKey = "ledger_api_endpoints:v1";
const endpointChangeEvent = "ledger-api-endpoints-change";
const sameOriginEndpointId = "same-origin";
const fallbackStatusCodes = new Set([408, 425, 429, 500, 502, 503, 504, 520, 522, 524]);
const safeMethodTimeoutMs = 4500;
let generatedEndpointId = 0;

type LedgerWindow = Window & {
  __ledgerApiFetchInstalled?: boolean;
  __ledgerOriginalFetch?: typeof fetch;
};

export const sameOriginApiEndpoint: ApiEndpoint = { id: sameOriginEndpointId, url: "", enabled: true };
export const apiEndpointSettingsChangeEvent = endpointChangeEvent;

export function isSameOriginApiEndpoint(endpoint: ApiEndpoint) {
  return endpoint.id === sameOriginEndpointId || endpoint.url === "";
}

export function displayApiEndpointUrl(endpoint: ApiEndpoint) {
  if (!isSameOriginApiEndpoint(endpoint)) return endpoint.url;
  if (typeof window === "undefined") return "当前站点";
  return window.location.origin;
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

export function readApiEndpointSettings(): ApiEndpointSettings {
  if (typeof window === "undefined") return defaultApiEndpointSettings();
  try {
    const raw = window.localStorage.getItem(storageKey);
    if (!raw) return defaultApiEndpointSettings();
    return sanitizeApiEndpointSettings(JSON.parse(raw) as Partial<ApiEndpointSettings>);
  } catch {
    return defaultApiEndpointSettings();
  }
}

export function writeApiEndpointSettings(settings: ApiEndpointSettings) {
  if (typeof window === "undefined") return;
  const next = sanitizeApiEndpointSettings(settings);
  try {
    window.localStorage.setItem(storageKey, JSON.stringify({
      activeId: next.activeId,
      autoSelect: next.autoSelect,
      endpoints: next.endpoints.filter((endpoint) => !isSameOriginApiEndpoint(endpoint)),
    }));
  } catch {
    // The in-memory settings in React state still apply until the page is reloaded.
  }
  window.dispatchEvent(new Event(endpointChangeEvent));
}

export function buildApiEndpointRequestUrl(endpoint: ApiEndpoint, pathWithSearch: string) {
  if (isSameOriginApiEndpoint(endpoint)) return pathWithSearch;
  return `${endpoint.url}${pathWithSearch.startsWith("/") ? pathWithSearch : `/${pathWithSearch}`}`;
}

export function orderedApiEndpoints(settings = readApiEndpointSettings(), method = "GET") {
  const enabled = settings.endpoints.filter((endpoint) => endpoint.enabled);
  const active = enabled.find((endpoint) => endpoint.id === settings.activeId) ?? enabled[0] ?? sameOriginApiEndpoint;
  if (!isSafeMethod(method)) return [active];
  const rest = enabled.filter((endpoint) => endpoint.id !== active.id);
  return [active, ...rest];
}

export function installApiEndpointFetchInterceptor() {
  if (typeof window === "undefined") return;
  const ledgerWindow = window as LedgerWindow;
  if (ledgerWindow.__ledgerApiFetchInstalled) return;
  const originalFetch = window.fetch.bind(window);
  ledgerWindow.__ledgerOriginalFetch = originalFetch;
  ledgerWindow.__ledgerApiFetchInstalled = true;

  window.fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const target = apiFetchTarget(input, init);
    if (!target) return originalFetch(input, init);

    const attempts = orderedApiEndpoints(readApiEndpointSettings(), target.method);
    if (!attempts.length) return originalFetch(input, init);

    let lastError: unknown;
    let lastResponse: Response | null = null;
    for (let index = 0; index < attempts.length; index += 1) {
      const endpoint = attempts[index];
      const url = buildApiEndpointRequestUrl(endpoint, target.pathWithSearch);
      const canRetry = isSafeMethod(target.method) && index < attempts.length - 1;
      const attempt = requestInitForEndpoint(input, init, endpoint, target.method, canRetry);
      try {
        const response = await originalFetch(url, attempt.init);
        if (canRetry && fallbackStatusCodes.has(response.status)) {
          lastResponse = response;
          continue;
        }
        return response;
      } catch (error) {
        lastError = error;
        if (!canRetry || isAbortFromCaller(error, init)) throw error;
      } finally {
        if (attempt.timeoutId !== undefined) window.clearTimeout(attempt.timeoutId);
      }
    }

    if (lastResponse) return lastResponse;
    throw lastError instanceof Error ? lastError : new Error("请求失败，请稍后重试");
  };
}

export async function probeApiEndpoint(endpoint: ApiEndpoint, timeoutMs = 8000): Promise<ApiEndpointProbeResult> {
  const fetcher = originalFetch();
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), timeoutMs);
  const startedAt = performance.now();
  try {
    const response = await fetcher(buildApiEndpointRequestUrl(endpoint, "/api/health"), {
      method: "GET",
      cache: "no-store",
      credentials: isSameOriginApiEndpoint(endpoint) ? "same-origin" : "include",
      signal: controller.signal,
    });
    const latencyMs = Math.max(1, Math.round(performance.now() - startedAt));
    if (!response.ok) return { id: endpoint.id, ok: false, latencyMs, error: `HTTP ${response.status}` };
    return { id: endpoint.id, ok: true, latencyMs };
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
  const customEndpoints = Array.isArray(raw.endpoints) ? raw.endpoints : [];
  const endpoints = [sameOriginApiEndpoint];
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
    endpoints.push({
      id: typeof endpoint.id === "string" && endpoint.id ? endpoint.id : nextEndpointId(),
      url,
      enabled: endpoint.enabled !== false,
    });
  }
  const activeId = typeof raw.activeId === "string" && endpoints.some((endpoint) => endpoint.id === raw.activeId)
    ? raw.activeId
    : sameOriginEndpointId;
  return { activeId, autoSelect: Boolean(raw.autoSelect), endpoints };
}

function nextEndpointId() {
  generatedEndpointId += 1;
  return `endpoint-${Date.now()}-${generatedEndpointId}`;
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

function isAbortFromCaller(error: unknown, init?: RequestInit) {
  return error instanceof DOMException && error.name === "AbortError" && Boolean(init?.signal?.aborted);
}

function originalFetch() {
  if (typeof window === "undefined") return fetch;
  return ((window as LedgerWindow).__ledgerOriginalFetch ?? window.fetch).bind(window);
}
