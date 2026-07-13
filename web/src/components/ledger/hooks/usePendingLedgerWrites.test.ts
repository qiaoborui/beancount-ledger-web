import { afterEach, describe, expect, it, vi } from "vitest";

const indexedCacheState = vi.hoisted(() => ({
  values: new Map<string, unknown>(),
  failedWrites: new Set<string>(),
  failedDeletes: new Set<string>(),
}));

vi.mock("@/lib/indexedLedgerCache", () => ({
  readIndexedCache: vi.fn(async (key: string) => indexedCacheState.values.get(key) ?? null),
  writeIndexedCache: vi.fn(async (key: string, value: unknown) => {
    if (indexedCacheState.failedWrites.has(key)) return false;
    indexedCacheState.values.set(key, value);
    return true;
  }),
  deleteIndexedCache: vi.fn(async (key: string) => {
    if (indexedCacheState.failedDeletes.has(key)) return false;
    indexedCacheState.values.delete(key);
    return true;
  }),
}));

import { discardPendingLedgerOperation, hasPendingOperationsToSync, isPendingLedgerConflict, readPendingLedgerOperations, syncOperation } from "./usePendingLedgerWrites";
import type { PendingLedgerOperation } from "../pendingLedgerOperations";

const pendingOperationsKey = "ledger_pending_operations";
const indexedPendingOperationsKey = "ledger_pending_operations:v2";
const pendingOperationsMigrationKey = "ledger_pending_operations:migrated:v3";

function memoryStorage(initial: Record<string, string> = {}, options: { failSet?: (key: string) => boolean; failRemove?: (key: string) => boolean } = {}) {
  const values = new Map(Object.entries(initial));
  const storage = {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => {
      if (options.failSet?.(key)) throw new Error("storage write failed");
      values.set(key, value);
    },
    removeItem: (key: string) => {
      if (options.failRemove?.(key)) throw new Error("storage remove failed");
      values.delete(key);
    },
    clear: () => values.clear(),
    key: (index: number) => Array.from(values.keys())[index] ?? null,
    get length() {
      return values.size;
    },
  } satisfies Storage;
  return { storage, values };
}

function installBackendStorage(clusterId: string, storage = memoryStorage()) {
  storage.values.set("ledger_api_endpoints:v2", JSON.stringify({
    activeId: "same-origin",
    autoSelect: false,
    clusterId,
    apiVersion: 1,
    endpoints: [{ id: "same-origin", url: "", enabled: true, clusterId, apiVersion: 1 }],
  }));
  vi.stubGlobal("localStorage", storage.storage);
  vi.stubGlobal("window", {
    localStorage: storage.storage,
    location: { origin: "https://app.example.com" },
    dispatchEvent: vi.fn(),
  } as unknown as Window & typeof globalThis);
  return storage;
}

function scopedLocalKey(clusterId: string) {
  return `${pendingOperationsKey}:cluster:${clusterId}`;
}

function scopedIndexedKey(clusterId: string) {
  return `${indexedPendingOperationsKey}:cluster:${clusterId}`;
}

function response(body: unknown, ok: boolean) {
  return {
    ok,
    text: async () => JSON.stringify(body),
  } as Response;
}

const entry = {
  kind: "transaction" as const,
  date: "2026-05-20",
  payee: "Cafe",
  narration: "Lunch",
  metadata: {},
  tags: [],
  confidence: 1,
  needsReview: false,
  questions: [],
  postings: [
    { account: "Expenses:Food", amount: "12.00", currency: "CNY" as const },
    { account: "Assets:Cash", amount: "-12.00", currency: "CNY" as const },
  ],
};

describe("syncOperation", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("sends a transaction update when an unrelated ledger revision completed", async () => {
    const fetchMock = vi.fn().mockResolvedValueOnce(response({ ok: true }, true));
    vi.stubGlobal("fetch", fetchMock);

    const operation: PendingLedgerOperation = {
      id: "op-1",
      createdAt: 1,
      kind: "update-transaction",
      source: { file: "/ledger/transactions/2026/05.bean", line: 12, hash: "old-hash" },
      entry,
      baseLedgerVersion: { version: "old-version", fileCount: 2, latestMtimeMs: 1 },
    };

    await syncOperation(operation);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe("/api/ledger/transactions");
    const body = JSON.parse(String(fetchMock.mock.calls[0][1]?.body));
    expect(body.source).toEqual({ file: "/ledger/transactions/2026/05.bean", line: 12, hash: "old-hash" });
  });

  it("keeps the transaction hash when a delete needs confirmation", async () => {
    const fetchMock = vi.fn().mockResolvedValueOnce(response({ error: "找不到原交易，账本可能已被修改，请刷新后重试" }, false));
    vi.stubGlobal("fetch", fetchMock);

    const operation: PendingLedgerOperation = {
      id: "op-1",
      createdAt: 1,
      kind: "delete-transaction",
      source: { file: "/ledger/transactions/2026/05.bean", line: 12, hash: "old-hash" },
      reason: "duplicate",
    };

    await expect(syncOperation(operation)).rejects.toThrow("找不到原交易");

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const body = JSON.parse(String(fetchMock.mock.calls[0][1]?.body));
    expect(body.source).toEqual({ file: "/ledger/transactions/2026/05.bean", line: 12, hash: "old-hash" });
  });

  it("classifies a changed transaction source as a conflict", () => {
    expect(isPendingLedgerConflict("找不到原交易，账本可能已被修改，请刷新后重试")).toBe(true);
    expect(isPendingLedgerConflict("交易来源不唯一，账本可能已被修改，请刷新后重试")).toBe(true);
    expect(isPendingLedgerConflict("连接超时")).toBe(false);
  });

  it("rejects pending writes that belong to another ledger", async () => {
    installBackendStorage("ledger-two");
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    await expect(syncOperation({
      id: "cross-ledger",
      createdAt: 1,
      kind: "append",
      entry,
      ledgerScope: "cluster:ledger-one",
    })).rejects.toThrow("另一个账本");

    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("pending operation storage migration", () => {
  afterEach(() => {
    indexedCacheState.values.clear();
    indexedCacheState.failedWrites.clear();
    indexedCacheState.failedDeletes.clear();
    vi.clearAllMocks();
    vi.unstubAllGlobals();
  });

  it("imports the legacy queue into only the first ledger scope", async () => {
    const legacyOperation: PendingLedgerOperation = { id: "legacy-1", createdAt: 1, kind: "append", entry };
    const storage = installBackendStorage("ledger-one", memoryStorage({
      [pendingOperationsKey]: JSON.stringify([legacyOperation]),
    }));

    const first = await readPendingLedgerOperations();
    storage.values.set("ledger_api_endpoints:v2", JSON.stringify({
      activeId: "same-origin",
      autoSelect: false,
      clusterId: "ledger-two",
      apiVersion: 1,
      endpoints: [{ id: "same-origin", url: "", enabled: true, clusterId: "ledger-two", apiVersion: 1 }],
    }));
    const second = await readPendingLedgerOperations();

    expect(first).toEqual([{ ...legacyOperation, ledgerScope: "cluster:ledger-one" }]);
    expect(second).toEqual([]);
    expect(storage.values.get(pendingOperationsMigrationKey)).toBe("1");
    expect(storage.values.has(pendingOperationsKey)).toBe(false);
  });

  it("moves pending writes from the provisional same-origin scope into the verified ledger scope", async () => {
    const provisionalOperation: PendingLedgerOperation = {
      id: "provisional-1",
      createdAt: 1,
      kind: "append",
      entry,
      ledgerScope: "endpoint:same-origin",
    };
    const provisionalKey = `${pendingOperationsKey}:endpoint:same-origin`;
    const storage = installBackendStorage("ledger-one", memoryStorage({
      [provisionalKey]: JSON.stringify([provisionalOperation]),
    }));

    const migrated = await readPendingLedgerOperations();

    expect(migrated).toEqual([{ ...provisionalOperation, ledgerScope: "cluster:ledger-one" }]);
    expect(storage.values.has(provisionalKey)).toBe(false);
    expect(JSON.parse(storage.values.get(scopedLocalKey("ledger-one")) ?? "[]")).toEqual(migrated);
  });

  it("keeps legacy data when both target stores fail", async () => {
    const legacyOperation: PendingLedgerOperation = { id: "legacy-1", createdAt: 1, kind: "append", entry };
    const targetLocal = scopedLocalKey("ledger-one");
    const storage = installBackendStorage("ledger-one", memoryStorage({
      [pendingOperationsKey]: JSON.stringify([legacyOperation]),
    }, {
      failSet: (key) => key === targetLocal || key === pendingOperationsMigrationKey,
    }));
    indexedCacheState.failedWrites.add(scopedIndexedKey("ledger-one"));
    indexedCacheState.failedWrites.add(pendingOperationsMigrationKey);

    const migrated = await readPendingLedgerOperations();

    expect(migrated).toEqual([{ ...legacyOperation, ledgerScope: "cluster:ledger-one" }]);
    expect(storage.values.has(pendingOperationsKey)).toBe(true);
    expect(storage.values.has(pendingOperationsMigrationKey)).toBe(false);
    expect(indexedCacheState.values.has(scopedIndexedKey("ledger-one"))).toBe(false);
  });

  it("finishes migration when localStorage succeeds and IndexedDB fails", async () => {
    const legacyOperation: PendingLedgerOperation = { id: "legacy-local", createdAt: 1, kind: "append", entry };
    const storage = installBackendStorage("ledger-one", memoryStorage({
      [pendingOperationsKey]: JSON.stringify([legacyOperation]),
    }));
    indexedCacheState.failedWrites.add(scopedIndexedKey("ledger-one"));
    indexedCacheState.failedWrites.add(pendingOperationsMigrationKey);

    await readPendingLedgerOperations();

    expect(JSON.parse(storage.values.get(scopedLocalKey("ledger-one")) ?? "[]")).toEqual([{ ...legacyOperation, ledgerScope: "cluster:ledger-one" }]);
    expect(storage.values.get(pendingOperationsMigrationKey)).toBe("1");
    expect(storage.values.has(pendingOperationsKey)).toBe(false);
  });

  it("finishes migration when IndexedDB succeeds and localStorage fails", async () => {
    const legacyOperation: PendingLedgerOperation = { id: "legacy-indexed", createdAt: 1, kind: "append", entry };
    const targetLocal = scopedLocalKey("ledger-one");
    const storage = installBackendStorage("ledger-one", memoryStorage({
      [pendingOperationsKey]: JSON.stringify([legacyOperation]),
    }, {
      failSet: (key) => key === targetLocal || key === pendingOperationsMigrationKey,
    }));

    await readPendingLedgerOperations();

    expect(indexedCacheState.values.get(scopedIndexedKey("ledger-one"))).toEqual([{ ...legacyOperation, ledgerScope: "cluster:ledger-one" }]);
    expect(indexedCacheState.values.get(pendingOperationsMigrationKey)).toBe(true);
    expect(storage.values.has(pendingOperationsKey)).toBe(false);
  });

  it("does not duplicate imports when markers fail but legacy sources were cleaned", async () => {
    const legacyOperation: PendingLedgerOperation = { id: "legacy-cleaned", createdAt: 1, kind: "append", entry };
    const storage = installBackendStorage("ledger-one", memoryStorage({
      [pendingOperationsKey]: JSON.stringify([legacyOperation]),
    }, {
      failSet: (key) => key === pendingOperationsMigrationKey,
    }));
    indexedCacheState.failedWrites.add(pendingOperationsMigrationKey);

    await readPendingLedgerOperations();
    storage.values.set("ledger_api_endpoints:v2", JSON.stringify({
      activeId: "same-origin",
      autoSelect: false,
      clusterId: "ledger-two",
      apiVersion: 1,
      endpoints: [{ id: "same-origin", url: "", enabled: true, clusterId: "ledger-two", apiVersion: 1 }],
    }));

    expect(await readPendingLedgerOperations()).toEqual([]);
    expect(storage.values.has(pendingOperationsKey)).toBe(false);
  });
});

describe("pending write conflicts", () => {
  const conflictOperation: PendingLedgerOperation = {
    id: "conflict-op",
    createdAt: 1,
    kind: "update-transaction",
    source: { file: "/ledger/transactions/2026/05.bean", line: 12, hash: "old-hash" },
    entry,
    status: "conflict",
    lastError: "账本已更新，这条本地修改需要确认后再同步",
  };

  it("keeps conflict-only queues out of automatic retries", () => {
    expect(hasPendingOperationsToSync([conflictOperation])).toBe(false);
    expect(hasPendingOperationsToSync([conflictOperation, { ...conflictOperation, id: "pending-op", status: "pending" }])).toBe(true);
  });

  it("discards only the selected local conflict", () => {
    const remaining = discardPendingLedgerOperation([
      conflictOperation,
      { ...conflictOperation, id: "other-op", status: "pending" },
    ], conflictOperation.id);

    expect(remaining).toEqual([{ ...conflictOperation, id: "other-op", status: "pending" }]);
  });
});
