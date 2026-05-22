import { afterEach, describe, expect, it, vi } from "vitest";
import { syncOperation } from "./usePendingLedgerWrites";
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

  it("retries stale transaction updates by file and line when the source hash changed", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(response({ error: "找不到原交易，账本可能已被修改，请刷新后重试" }, false))
      .mockResolvedValueOnce(response({ ok: true }, true));
    vi.stubGlobal("fetch", fetchMock);

    const operation: PendingLedgerOperation = {
      id: "op-1",
      createdAt: 1,
      kind: "update-transaction",
      source: { file: "/ledger/transactions/2026/05.bean", line: 12, hash: "old-hash" },
      entry,
    };

    await syncOperation(operation);

    expect(fetchMock).toHaveBeenCalledTimes(2);
    const firstBody = JSON.parse(String(fetchMock.mock.calls[0][1]?.body));
    const retryBody = JSON.parse(String(fetchMock.mock.calls[1][1]?.body));
    expect(firstBody.source).toEqual({ file: "/ledger/transactions/2026/05.bean", line: 12, hash: "old-hash" });
    expect(retryBody.source).toEqual({ file: "/ledger/transactions/2026/05.bean", line: 12 });
  });

  it("retries stale transaction deletes by file and line when the source hash changed", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(response({ error: "找不到原交易，账本可能已被修改，请刷新后重试" }, false))
      .mockResolvedValueOnce(response({ ok: true }, true));
    vi.stubGlobal("fetch", fetchMock);

    const operation: PendingLedgerOperation = {
      id: "op-1",
      createdAt: 1,
      kind: "delete-transaction",
      source: { file: "/ledger/transactions/2026/05.bean", line: 12, hash: "old-hash" },
      reason: "duplicate",
    };

    await syncOperation(operation);

    expect(fetchMock).toHaveBeenCalledTimes(2);
    const firstBody = JSON.parse(String(fetchMock.mock.calls[0][1]?.body));
    const retryBody = JSON.parse(String(fetchMock.mock.calls[1][1]?.body));
    expect(firstBody.source).toEqual({ file: "/ledger/transactions/2026/05.bean", line: 12, hash: "old-hash" });
    expect(retryBody.source).toEqual({ file: "/ledger/transactions/2026/05.bean", line: 12 });
  });
});
