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
});
