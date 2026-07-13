import { afterEach, describe, expect, it, vi } from "vitest";
import { enableQuickLedgerUnlock, getQuickLedgerUnlockMode, hasQuickLedgerUnlock, unlockWithQuickLedgerSecret } from "./quickUnlock";

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

function installEndpointSettings(storage: Storage, activeId: string) {
  storage.setItem("ledger_api_endpoints:v2", JSON.stringify({
    activeId,
    autoSelect: false,
    clusterId: "ledger-one",
    apiVersion: 1,
    endpoints: [
      { id: "primary", url: "https://primary.example.com", enabled: true, clusterId: "ledger-one", apiVersion: 1 },
      { id: "backup", url: "https://backup.example.com", enabled: true, clusterId: "ledger-one", apiVersion: 1 },
    ],
  }));
}

describe("quick ledger unlock", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("stores a device token encrypted by a numeric local secret", async () => {
    vi.stubGlobal("localStorage", memoryStorage());
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input) === "/api/quick-unlock/register") {
        expect(JSON.parse(String(init?.body))).toMatchObject({ mode: "numeric" });
        return new Response(JSON.stringify({ deviceId: "device-1", token: "server-token" }), { status: 200 });
      }
      if (String(input) === "/api/quick-unlock/verify") {
        expect(JSON.parse(String(init?.body))).toEqual({ deviceId: "device-1", token: "server-token" });
        return new Response(JSON.stringify({ ok: true }), { status: 200 });
      }
      return new Response(JSON.stringify({ error: "unexpected" }), { status: 404 });
    });
    vi.stubGlobal("fetch", fetchMock);

    await enableQuickLedgerUnlock("7", "numeric");

    expect(hasQuickLedgerUnlock()).toBe(true);
    expect(getQuickLedgerUnlockMode()).toBe("numeric");
    await expect(unlockWithQuickLedgerSecret("7")).resolves.toBeUndefined();
    await expect(unlockWithQuickLedgerSecret("8")).rejects.toThrow();
  });

  it("keeps quick unlock device tokens isolated by backend", async () => {
    const storage = memoryStorage();
    installEndpointSettings(storage, "primary");
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ deviceId: "device-primary", token: "server-token" }), { status: 200 }));
    vi.stubGlobal("localStorage", storage);
    vi.stubGlobal("window", { localStorage: storage, location: { origin: "https://app.example.com" }, fetch: fetchMock, dispatchEvent: vi.fn() } as unknown as Window & typeof globalThis);
    vi.stubGlobal("fetch", fetchMock);

    await enableQuickLedgerUnlock("7", "numeric");
    expect(hasQuickLedgerUnlock()).toBe(true);

    installEndpointSettings(storage, "backup");
    expect(hasQuickLedgerUnlock()).toBe(false);
  });
});
