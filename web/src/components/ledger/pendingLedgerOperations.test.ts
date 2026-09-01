import { describe, expect, it } from "vitest";
import {
  applyPendingLedgerOperations,
  mergePendingOperation,
  migrateLegacyPendingWrites,
  normalizePendingLedgerOperations,
  type PendingLedgerOperation,
} from "./pendingLedgerOperations";
import type { ParsedTransaction } from "@/lib/schemas";
import type { Txn } from "./types";

function txn(line: number, patch: Partial<Txn> = {}): Txn {
  return {
    date: "2026-05-20",
    payee: "Original",
    narration: "Lunch",
    metadata: {},
    tags: [],
    postings: [
      { account: "Expenses:Food", amount: 1200, currency: "CNY" },
      { account: "Assets:Cash", amount: -1200, currency: "CNY" },
    ],
    source: { file: "/ledger/2026.bean", line, hash: `hash-${line}` },
    ...patch,
  };
}

function entry(patch: Partial<ParsedTransaction> = {}): ParsedTransaction {
  return {
    kind: "transaction",
    date: "2026-05-20",
    payee: "Edited",
    narration: "Dinner",
    metadata: {},
    tags: [],
    confidence: 1,
    needsReview: false,
    questions: [],
    postings: [
      { account: "Expenses:Food", amount: "18.50", currency: "CNY" },
      { account: "Assets:Cash", amount: "-18.50", currency: "CNY" },
    ],
    ...patch,
  };
}

function updateOperation(id: string, source: Txn["source"], patch: Partial<ParsedTransaction> = {}): PendingLedgerOperation {
  return { id, createdAt: 1, kind: "update-transaction", source, entry: entry(patch) };
}

describe("pending ledger operations", () => {
  it("projects pending appended transactions into cached rows", () => {
    const rows = applyPendingLedgerOperations([txn(3)], [{ id: "append-1", createdAt: 1, kind: "append", entry: entry({ payee: "Local Cafe" }) }]);

    expect(rows).toHaveLength(2);
    expect(rows[0].payee).toBe("Local Cafe");
    expect(rows[0].source).toEqual({ file: "local://pending/append-1", line: 0, hash: "append-1" });
    expect(rows[0].pending).toEqual({ kind: "append", operationId: "append-1" });
  });

  it("keeps pending appends inside the selected time range", () => {
    const rows = applyPendingLedgerOperations(
      [txn(3)],
      [{ id: "append-1", createdAt: 1, kind: "append", entry: entry({ date: "2026-06-01" }) }],
      { start: "2026-05-01", end: "2026-06-01", preset: "month" },
    );

    expect(rows).toEqual([txn(3)]);
  });

  it("does not project pending balance assertions as transactions", () => {
    const rows = applyPendingLedgerOperations([txn(3)], [{ id: "balance-1", createdAt: 1, kind: "append", entry: { kind: "balance", date: "2026-05-20", account: "Assets:Cash", amount: "10.00", currency: "CNY" } }]);

    expect(rows).toEqual([txn(3)]);
  });

  it("projects pending transaction updates into cached rows", () => {
    const rows = applyPendingLedgerOperations([txn(3)], [updateOperation("op-1", txn(3).source)]);

    expect(rows).toHaveLength(1);
    expect(rows[0].payee).toBe("Edited");
    expect(rows[0].postings[0].amount).toBe(1850);
    expect(rows[0].pending).toEqual({ kind: "update-transaction", operationId: "op-1" });
  });

  it("hides pending deleted transactions", () => {
    const source = txn(3).source;
    const rows = applyPendingLedgerOperations([txn(3), txn(9)], [{ id: "op-1", createdAt: 1, kind: "delete-transaction", source, reason: "duplicate" }]);

    expect(rows.map((row) => row.source.line)).toEqual([9]);
  });

  it("projects one grouped tag operation across all selected transactions", () => {
    const first = txn(3, { tags: ["work"] });
    const second = txn(9);
    const rows = applyPendingLedgerOperations([first, second], [{
      id: "tags-1",
      createdAt: 1,
      kind: "add-transaction-tags",
      sources: [first.source, second.source],
      tags: ["travel", "trip-2026-hokkaido"],
    }]);

    expect(rows[0].tags).toEqual(["work", "travel", "trip-2026-hokkaido"]);
    expect(rows[1].tags).toEqual(["travel", "trip-2026-hokkaido"]);
    expect(rows[0].pending).toEqual({ kind: "add-transaction-tags", operationId: "tags-1" });
  });

  it("keeps line-distinct transactions with the same hash in one grouped tag operation", () => {
    const first = txn(3, { source: { file: "/ledger/2026.bean", line: 3, hash: "same-hash" } });
    const second = txn(9, { source: { file: "/ledger/2026.bean", line: 9, hash: "same-hash" } });
    const operations = mergePendingOperation([], {
      id: "tags-1",
      createdAt: 1,
      kind: "add-transaction-tags",
      sources: [first.source, second.source],
      tags: ["travel"],
    });
    const rows = applyPendingLedgerOperations([first, second], operations);

    expect(operations).toHaveLength(1);
    expect(operations[0]).toMatchObject({ kind: "add-transaction-tags", sources: [first.source, second.source] });
    expect(rows.map((row) => row.tags)).toEqual([["travel"], ["travel"]]);
  });

  it("folds pending batch tags into a later full transaction update", () => {
    const source = txn(3).source;
    const tagged = mergePendingOperation([], { id: "tags-1", createdAt: 1, kind: "add-transaction-tags", sources: [source], tags: ["travel"] });
    const merged = mergePendingOperation(tagged, updateOperation("update-1", source, { tags: ["food"] }));

    expect(merged).toHaveLength(1);
    expect(merged[0]).toMatchObject({ kind: "update-transaction", entry: { tags: ["food", "travel"] } });
  });

  it("folds a later tag batch into an existing pending update", () => {
    const source = txn(3).source;
    const updated = mergePendingOperation([], updateOperation("update-1", source, { tags: ["food"] }));
    const merged = mergePendingOperation(updated, { id: "tags-1", createdAt: 2, kind: "add-transaction-tags", sources: [source], tags: ["travel"] });

    expect(merged).toHaveLength(1);
    expect(merged[0]).toMatchObject({ kind: "update-transaction", entry: { tags: ["food", "travel"] } });
  });

  it("splits overlapping tag batches without applying new tags to unrelated rows", () => {
    const first = txn(3);
    const second = txn(9);
    const initial = mergePendingOperation([], { id: "tags-1", createdAt: 1, kind: "add-transaction-tags", sources: [first.source, second.source], tags: ["travel"] });
    const merged = mergePendingOperation(initial, { id: "tags-2", createdAt: 2, kind: "add-transaction-tags", sources: [first.source], tags: ["work"] });
    const rows = applyPendingLedgerOperations([first, second], merged);

    expect(rows[0].tags).toEqual(["travel", "work"]);
    expect(rows[1].tags).toEqual(["travel"]);
  });

  it("keeps only the latest operation for the same transaction", () => {
    const source = txn(3).source;
    const first = updateOperation("op-1", source, { narration: "First" });
    const second = updateOperation("op-2", source, { narration: "Second" });
    const merged = mergePendingOperation(mergePendingOperation([], first), second);
    const rows = applyPendingLedgerOperations([txn(3)], merged);

    expect(merged).toHaveLength(1);
    expect(rows[0].narration).toBe("Second");
  });

  it("lets delete replace a pending update for the same transaction", () => {
    const source = txn(3).source;
    const merged = mergePendingOperation(
      mergePendingOperation([], updateOperation("op-1", source)),
      { id: "op-2", createdAt: 2, kind: "delete-transaction", source, reason: "wrong" },
    );

    expect(merged).toHaveLength(1);
    expect(merged[0].kind).toBe("delete-transaction");
    expect(applyPendingLedgerOperations([txn(3)], merged)).toEqual([]);
  });

  it("removes an edited transaction when it moves outside the current range", () => {
    const rows = applyPendingLedgerOperations(
      [txn(3)],
      [updateOperation("op-1", txn(3).source, { date: "2026-06-01" })],
      { start: "2026-05-01", end: "2026-06-01", preset: "month" },
    );

    expect(rows).toEqual([]);
  });

  it("migrates legacy append-only pending writes", () => {
    const migrated = migrateLegacyPendingWrites([{ id: "old-1", createdAt: 123, entry: entry() }]);

    expect(migrated).toEqual([{ id: "old-1", createdAt: 123, kind: "append", entry: entry() }]);
  });

  it("normalizes interrupted syncing operations back to pending", () => {
    const normalized = normalizePendingLedgerOperations([{ id: "op-1", createdAt: 1, kind: "append", entry: entry(), status: "syncing" }]);

    expect(normalized).toEqual([{ id: "op-1", createdAt: 1, kind: "append", entry: entry(), status: "pending" }]);
  });
});
