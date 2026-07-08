import { afterEach, describe, expect, it, vi } from "vitest";
import { installApiEndpointFetchInterceptor, normalizeApiEndpointUrl, readApiEndpointSettings, writeApiEndpointSettings, type ApiEndpointSettings } from "./apiEndpoints";

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

function installMockWindow(fetchMock = vi.fn()) {
  vi.stubGlobal("window", {
    localStorage: memoryStorage(),
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
    endpoints: [
      { id: "same-origin", url: "", enabled: true },
      { id: "backup", url: "https://backup.example.com", enabled: true },
    ],
  };
}

describe("api endpoint settings", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("normalizes custom backends and rejects non-HTTPS URLs", () => {
    expect(normalizeApiEndpointUrl(" https://api.example.com/v1/ ")).toBe("https://api.example.com/v1");
    expect(() => normalizeApiEndpointUrl("http://api.example.com")).toThrow("HTTPS");
  });

  it("persists custom endpoints with same-origin as the built-in default", () => {
    installMockWindow();

    writeApiEndpointSettings(endpointSettings());

    expect(readApiEndpointSettings()).toMatchObject({
      activeId: "same-origin",
      endpoints: [
        { id: "same-origin", url: "", enabled: true },
        { id: "backup", url: "https://backup.example.com", enabled: true },
      ],
    });
  });

  it("falls back to the next backend for read requests", async () => {
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new TypeError("cold start"))
      .mockResolvedValueOnce(new Response(JSON.stringify({ version: "ok" }), { status: 200 }));
    installMockWindow(fetchMock);
    writeApiEndpointSettings(endpointSettings());
    installApiEndpointFetchInterceptor();

    const response = await window.fetch("/api/ledger/version");

    expect(response.ok).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[0][0]).toBe("/api/ledger/version");
    expect(fetchMock.mock.calls[1][0]).toBe("https://backup.example.com/api/ledger/version");
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
});
