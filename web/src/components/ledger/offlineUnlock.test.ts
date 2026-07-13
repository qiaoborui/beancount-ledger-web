import { afterEach, describe, expect, it, vi } from "vitest";
import { enableOfflineLedgerUnlock, hasOfflineLedgerUnlock, verifyOfflineLedgerUnlock } from "./offlineUnlock";

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

function installLedgerSettings(storage: Storage, clusterId: string) {
  storage.setItem("ledger_api_endpoints:v2", JSON.stringify({
    activeId: "same-origin",
    autoSelect: false,
    clusterId,
    apiVersion: 1,
    endpoints: [{ id: "same-origin", url: "", enabled: true, clusterId, apiVersion: 1 }],
  }));
}

describe("offline ledger unlock", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("enables and verifies a local offline unlock secret", async () => {
    vi.stubGlobal("localStorage", memoryStorage());

    await enableOfflineLedgerUnlock("123456");

    expect(hasOfflineLedgerUnlock()).toBe(true);
    await expect(verifyOfflineLedgerUnlock("123456")).resolves.toBeUndefined();
    await expect(verifyOfflineLedgerUnlock("000000")).rejects.toThrow();
  });

  it("keeps offline unlock configuration isolated by ledger", async () => {
    const storage = memoryStorage();
    installLedgerSettings(storage, "ledger-one");
    vi.stubGlobal("localStorage", storage);
    vi.stubGlobal("window", { localStorage: storage, location: { origin: "https://app.example.com" } } as unknown as Window & typeof globalThis);

    await enableOfflineLedgerUnlock("123456");
    expect(hasOfflineLedgerUnlock()).toBe(true);

    installLedgerSettings(storage, "ledger-two");
    expect(hasOfflineLedgerUnlock()).toBe(false);
  });
});
