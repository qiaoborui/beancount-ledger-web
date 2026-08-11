import { describe, expect, it, vi } from "vitest";
import { purgeLegacySensitiveCacheStorage } from "./legacySensitiveCacheCleanup";

function memoryStorage(initial: Record<string, string>) {
  const values = new Map(Object.entries(initial));
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
    key: (index: number) => Array.from(values.keys())[index] ?? null,
    get length() { return values.size; },
  } satisfies Pick<Storage, "getItem" | "setItem" | "removeItem" | "key" | "length">;
}

describe("legacy sensitive cache cleanup", () => {
  it("removes legacy local and IndexedDB records before recording completion", async () => {
    const storage = memoryStorage({
      ledger_offline_unlock_config: "verifier",
      "ledger_offline_unlock_config:cluster:one": "scoped-verifier",
      "ledger_encrypted_cache:month=CURRENT": "legacy-cache",
      "ledger_encrypted_cache_legacy_scope:v1": "cluster:one",
      keep_me: "safe",
    });
    const deleteIndexed = vi.fn(async () => true);

    await expect(purgeLegacySensitiveCacheStorage(storage, deleteIndexed)).resolves.toBe(true);

    expect(deleteIndexed).toHaveBeenCalledWith(["ledger_encrypted_cache:"]);
    expect(storage.getItem("ledger_offline_unlock_config")).toBeNull();
    expect(storage.getItem("ledger_offline_unlock_config:cluster:one")).toBeNull();
    expect(storage.getItem("ledger_encrypted_cache:month=CURRENT")).toBeNull();
    expect(storage.getItem("ledger_encrypted_cache_legacy_scope:v1")).toBeNull();
    expect(storage.getItem("keep_me")).toBe("safe");
    expect(storage.getItem("ledger_legacy_sensitive_cache_cleanup:v1")).toBe("1");
  });

  it("retries IndexedDB cleanup after a partial failure", async () => {
    const storage = memoryStorage({ ledger_offline_unlock_config: "verifier" });

    await expect(purgeLegacySensitiveCacheStorage(storage, async () => false)).resolves.toBe(false);
    expect(storage.getItem("ledger_legacy_sensitive_cache_cleanup:v1")).toBeNull();
    await expect(purgeLegacySensitiveCacheStorage(storage, async () => true)).resolves.toBe(true);
  });
});
