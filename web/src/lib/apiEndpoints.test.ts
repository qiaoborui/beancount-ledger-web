import { afterEach, describe, expect, it, vi } from "vitest";
import {
  activeApiEndpointRequestUrl,
  apiEndpointScopedStorageKey,
  apiEndpointAuthStorageKey,
  applyApiEndpointProbe,
  installApiEndpointFetchInterceptor,
  normalizeApiEndpointUrl,
  orderedApiEndpoints,
  readApiEndpointSettings,
  resetApiEndpointRuntimeState,
  withActiveApiEndpoint,
  writeApiEndpointSettings,
  type ApiEndpointSettings,
} from "./apiEndpoints";

function memoryStorage() {
  const values = new Map<string, string>();
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
    clear: () => values.clear(),
    key: (index: number) => Array.from(values.keys())[index] ?? null,
    get length() {
      return values.size;
    },
  } satisfies Storage;
}

function installMockWindow(fetchMock = vi.fn(), localStorage = memoryStorage()) {
  vi.stubGlobal("window", {
    localStorage,
    location: { origin: "https://app.example.com" },
    fetch: fetchMock,
    setTimeout,
    clearTimeout,
    dispatchEvent: vi.fn(),
  } as unknown as Window & typeof globalThis);
}

function endpointSettings(): ApiEndpointSettings {
  return {
    activeId: "same-origin",
    autoSelect: false,
    clusterId: "ledger-one",
    apiVersion: 1,
    endpoints: [
      { id: "same-origin", url: "", enabled: true, clusterId: "ledger-one", apiVersion: 1 },
      { id: "backup", url: "https://backup.example.com", enabled: true, clusterId: "ledger-one", apiVersion: 1 },
    ],
  };
}

function rememberBackupAuthentication() {
  window.localStorage.setItem(apiEndpointAuthStorageKey("ledger_auth_known", "backup"), "1");
}

describe("api endpoint settings", () => {
  afterEach(() => {
    resetApiEndpointRuntimeState();
    vi.unstubAllGlobals();
  });

  it("normalizes custom backends and rejects non-HTTPS URLs", () => {
    expect(normalizeApiEndpointUrl(" https://api.example.com/v1/ ")).toBe("https://api.example.com/v1");
    expect(() => normalizeApiEndpointUrl("http://api.example.com")).toThrow("HTTPS");
  });

  it("persists backend identity metadata including same-origin", () => {
    installMockWindow();

    writeApiEndpointSettings(endpointSettings());

    expect(readApiEndpointSettings()).toMatchObject(endpointSettings());
  });

  it("keeps backend switches effective in memory when browser storage is unavailable", () => {
    const storage = memoryStorage();
    installMockWindow(vi.fn(), {
      ...storage,
      setItem: () => {
        throw new Error("storage unavailable");
      },
    });

    writeApiEndpointSettings({ ...endpointSettings(), activeId: "backup" });

    expect(readApiEndpointSettings().activeId).toBe("backup");
  });

  it("only activates configured enabled compatible backends", () => {
    const settings = endpointSettings();
    expect(withActiveApiEndpoint(settings, "backup").activeId).toBe("backup");
    expect(withActiveApiEndpoint(settings, "missing")).toBe(settings);
    expect(withActiveApiEndpoint({
      ...settings,
      endpoints: settings.endpoints.map((endpoint) => endpoint.id === "backup" ? { ...endpoint, clusterId: "other-ledger" } : endpoint),
    }, "backup").activeId).toBe("same-origin");
  });

  it("rejects backends without identity or with incompatible identity", () => {
    const settings = endpointSettings();
    expect(() => applyApiEndpointProbe(settings, "backup", { id: "backup", ok: true, clusterId: "ledger-one" })).toThrow("API 版本");
    expect(() => applyApiEndpointProbe(settings, "backup", { id: "backup", ok: true, apiVersion: 1 })).toThrow("账本标识");
    expect(() => applyApiEndpointProbe(settings, "backup", { id: "backup", ok: true, apiVersion: 2, clusterId: "ledger-one" })).toThrow("不兼容");
    expect(() => applyApiEndpointProbe(settings, "backup", { id: "backup", ok: true, apiVersion: 1, clusterId: "other-ledger" })).toThrow("另一个账本");
  });

  it("uses different storage keys for different ledgers", () => {
    expect(apiEndpointScopedStorageKey("cache", endpointSettings())).not.toBe(apiEndpointScopedStorageKey("cache", {
      ...endpointSettings(),
      clusterId: "ledger-two",
    }));
  });

  it("builds download URLs against the active backend", () => {
    expect(activeApiEndpointRequestUrl("/api/ledger/imports/documents/file?path=x", {
      ...endpointSettings(),
      activeId: "backup",
    })).toBe("https://backup.example.com/api/ledger/imports/documents/file?path=x");
  });

  it("does not fall back through unverified backends", async () => {
    const fetchMock = vi.fn().mockRejectedValueOnce(new TypeError("cold start"));
    installMockWindow(fetchMock);
    const settings = endpointSettings();
    writeApiEndpointSettings({
      ...settings,
      endpoints: settings.endpoints.map((endpoint) => endpoint.id === "backup" ? { id: endpoint.id, url: endpoint.url, enabled: true } : endpoint),
    });
    installApiEndpointFetchInterceptor();

    await expect(window.fetch("/api/ledger/version")).rejects.toThrow("cold start");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("does not fall back through a verified backend that has never logged in", async () => {
    const fetchMock = vi.fn().mockRejectedValueOnce(new TypeError("cold start"));
    installMockWindow(fetchMock);
    writeApiEndpointSettings(endpointSettings());
    installApiEndpointFetchInterceptor();

    await expect(window.fetch("/api/ledger/version")).rejects.toThrow("cold start");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("falls back to the next verified backend for read requests", async () => {
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new TypeError("cold start"))
      .mockResolvedValueOnce(new Response(JSON.stringify({ version: "ok" }), { status: 200 }));
    installMockWindow(fetchMock);
    writeApiEndpointSettings(endpointSettings());
    rememberBackupAuthentication();
    installApiEndpointFetchInterceptor();

    const response = await window.fetch("/api/ledger/version");

    expect(response.ok).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[0][0]).toBe("/api/ledger/version");
    expect(fetchMock.mock.calls[1][0]).toBe("https://backup.example.com/api/ledger/version");
  });

  it("skips a failed primary backend while it is cooling down", async () => {
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new TypeError("cold start"))
      .mockResolvedValueOnce(new Response("{}", { status: 200 }))
      .mockResolvedValueOnce(new Response("{}", { status: 200 }));
    installMockWindow(fetchMock);
    writeApiEndpointSettings(endpointSettings());
    rememberBackupAuthentication();
    installApiEndpointFetchInterceptor();

    await window.fetch("/api/ledger/version");
    await window.fetch("/api/ledger/summary");

    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(fetchMock.mock.calls[2][0]).toBe("https://backup.example.com/api/ledger/summary");
  });

  it("returns to the active backend after the fallback stickiness window expires", async () => {
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new TypeError("cold start"))
      .mockResolvedValueOnce(new Response("{}", { status: 200 }));
    installMockWindow(fetchMock);
    writeApiEndpointSettings(endpointSettings());
    rememberBackupAuthentication();
    installApiEndpointFetchInterceptor();

    await window.fetch("/api/ledger/version");

    expect(orderedApiEndpoints(endpointSettings(), "GET", Date.now() + 31000)[0].id).toBe("same-origin");
  });

  it("does not automatically fall back for mutating requests", async () => {
    const fetchMock = vi.fn().mockRejectedValueOnce(new TypeError("network failed"));
    installMockWindow(fetchMock);
    writeApiEndpointSettings(endpointSettings());
    installApiEndpointFetchInterceptor();

    await expect(window.fetch("/api/ledger/append", { method: "POST", body: "{}" })).rejects.toThrow("network failed");

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe("/api/ledger/append");
  });

  it("does not fall back authentication state requests to another backend", async () => {
    const fetchMock = vi.fn().mockRejectedValueOnce(new TypeError("backend unavailable"));
    installMockWindow(fetchMock);
    writeApiEndpointSettings(endpointSettings());
    installApiEndpointFetchInterceptor();

    await expect(window.fetch("/api/auth/me")).rejects.toThrow("backend unavailable");

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe("/api/auth/me");
  });

  it("keeps authentication on the active backend after read fallback becomes sticky", async () => {
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new TypeError("primary unavailable"))
      .mockResolvedValueOnce(new Response("{}", { status: 200 }))
      .mockResolvedValueOnce(new Response("{}", { status: 200 }));
    installMockWindow(fetchMock);
    writeApiEndpointSettings(endpointSettings());
    rememberBackupAuthentication();
    installApiEndpointFetchInterceptor();

    await window.fetch("/api/ledger/version");
    await window.fetch("/api/auth/me");

    expect(fetchMock.mock.calls[2][0]).toBe("/api/auth/me");
  });

  it("returns post-login reads to the active backend after fallback stickiness", async () => {
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new TypeError("primary unavailable"))
      .mockResolvedValueOnce(new Response("{}", { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true }), { status: 200 }))
      .mockResolvedValueOnce(new Response("{}", { status: 200 }));
    installMockWindow(fetchMock);
    writeApiEndpointSettings(endpointSettings());
    rememberBackupAuthentication();
    installApiEndpointFetchInterceptor();

    await window.fetch("/api/ledger/version");
    await window.fetch("/api/auth/login", { method: "POST", body: "{}" });
    await window.fetch("/api/ledger/summary");

    expect(fetchMock.mock.calls[3][0]).toBe("/api/ledger/summary");
  });

  it("does not turn an unauthorized backup response into an active-backend logout", async () => {
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new TypeError("primary unavailable"))
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 }));
    installMockWindow(fetchMock);
    writeApiEndpointSettings(endpointSettings());
    rememberBackupAuthentication();
    installApiEndpointFetchInterceptor();

    await expect(window.fetch("/api/ledger/version")).rejects.toThrow("备用后端登录已失效");
    expect(window.localStorage.getItem(apiEndpointAuthStorageKey("ledger_auth_known", "backup"))).toBeNull();
  });
});
