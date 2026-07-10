import { afterEach, describe, expect, it, vi } from "vitest";
import { discardPendingLedgerOperation, hasPendingOperationsToSync, isPendingLedgerConflict, syncOperation } from "./usePendingLedgerWrites";
import type { PendingLedgerOperation } from "../pendingLedgerOperations";

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
