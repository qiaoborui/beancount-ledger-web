import type { BalanceAssertion, ParsedTransaction } from "@/lib/schemas";
import type { TimeRange, Txn } from "./types";

export type PendingEntry = ParsedTransaction | BalanceAssertion;

export type PendingAppendOperation = {
  id: string;
  createdAt: number;
  kind: "append";
  entry: PendingEntry;
};

export type PendingUpdateTransactionOperation = {
  id: string;
  createdAt: number;
  kind: "update-transaction";
  source: Txn["source"];
  entry: ParsedTransaction;
};

export type PendingDeleteTransactionOperation = {
  id: string;
  createdAt: number;
  kind: "delete-transaction";
  source: Txn["source"];
  reason: string;
};

export type PendingLedgerOperation =
  | PendingAppendOperation
  | PendingUpdateTransactionOperation
  | PendingDeleteTransactionOperation;

type LegacyPendingWrite = {
  id: string;
  createdAt: number;
  entry: PendingEntry;
};

export function sourceKey(source: Txn["source"]) {
  return source.hash ? `${source.file}#${source.hash}` : `${source.file}:${source.line}`;
}

function isTransactionOperation(operation: PendingLedgerOperation): operation is PendingUpdateTransactionOperation | PendingDeleteTransactionOperation {
  return operation.kind === "update-transaction" || operation.kind === "delete-transaction";
}

export function mergePendingOperation(operations: PendingLedgerOperation[], operation: PendingLedgerOperation) {
  if (!isTransactionOperation(operation)) return [...operations, operation];
  const key = sourceKey(operation.source);
  return [...operations.filter((item) => !isTransactionOperation(item) || sourceKey(item.source) !== key), operation];
}

export function migrateLegacyPendingWrites(writes: unknown): PendingLedgerOperation[] {
  if (!Array.isArray(writes)) return [];
  return writes.flatMap((item) => {
    const write = item as Partial<LegacyPendingWrite>;
    if (!write?.id || !write.entry) return [];
    return [{
      id: String(write.id),
      createdAt: typeof write.createdAt === "number" ? write.createdAt : Date.now(),
      kind: "append" as const,
      entry: write.entry,
    }];
  });
}

function amountToCents(value: string) {
  return Math.round(Number(value) * 100);
}

function entryToPendingTxn(source: Txn["source"], entry: ParsedTransaction, operationId: string): Txn {
  return {
    date: entry.date,
    payee: entry.payee,
    narration: entry.narration,
    metadata: entry.metadata,
    tags: entry.tags,
    postings: entry.postings.map((posting) => ({
      account: posting.account,
      amount: amountToCents(posting.amount),
      currency: posting.currency,
    })),
    source,
    pending: { kind: "update-transaction", operationId },
  };
}

function inRange(txn: Txn, range?: TimeRange) {
  return !range || (txn.date >= range.start && txn.date < range.end);
}

export function applyPendingLedgerOperations(txns: Txn[], operations: PendingLedgerOperation[], range?: TimeRange): Txn[] {
  let rows = [...txns];

  for (const operation of operations) {
    if (!isTransactionOperation(operation)) continue;
    const key = sourceKey(operation.source);
    const index = rows.findIndex((txn) => sourceKey(txn.source) === key);
    if (index < 0) continue;

    if (operation.kind === "delete-transaction") {
      rows = rows.filter((_, rowIndex) => rowIndex !== index);
      continue;
    }

    const next = entryToPendingTxn(operation.source, operation.entry, operation.id);
    rows = inRange(next, range)
      ? rows.map((txn, rowIndex) => (rowIndex === index ? next : txn))
      : rows.filter((_, rowIndex) => rowIndex !== index);
  }

  return rows;
}
