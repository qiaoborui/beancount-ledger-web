import { afterEach, describe, expect, it, vi } from "vitest";
import type { LedgerCache, TimeRange, Txn } from "./types";

const indexedCache = vi.hoisted(() => ({
  read: vi.fn<(key: string) => Promise<unknown | null>>(),
  write: vi.fn<(key: string, value: unknown) => Promise<boolean>>(),
}));

vi.mock("@/lib/indexedLedgerCache", () => ({
  readIndexedCache: indexedCache.read,
  writeIndexedCache: indexedCache.write,
}));

import { readLedgerCacheAsync, writeLedgerCache } from "./storage";

const range: TimeRange = { start: "2026-08-01", end: "2026-09-01", preset: "month" };

function transaction(account: string): Txn {
  return {
    date: "2026-08-01",
    payee: "Test",
    narration: account,
    postings: [{ account, amount: 100, currency: "CNY" }],
    source: { file: "transactions.bean", line: 1 },
  };
}

function sensitiveCache(): LedgerCache {
  return {
    summary: { income: 100, expense: 20, net: 80, days: {}, categories: {} },
    balances: { "Assets:Cash": 1_000 },
    accountBalances: [{ account: "Assets:Cash", currency: "CNY", amount: 1_000, valuationCurrency: "CNY", valuation: 1_000 }],
    txns: [transaction("Income:Salary"), transaction("Expenses:Food")],
    netWorthRows: [{ date: "2026-08-01", assets: 1_000, liabilities: 0, netWorth: 1_000 }],
    reconciliationRows: [],
    accounts: [],
    prices: [],
    incomeStatement: {
      income: [{ account: "Income:Salary", label: "Salary", amount: 100, children: [], depth: 0, txCount: 1 }],
      expense: [],
      totalIncome: 100,
      totalExpense: 20,
      netIncome: 80,
      valuationCurrency: "CNY",
    },
    accountStatuses: [{ account: "Assets:Cash", status: "green", lastEntryDate: "2026-08-01", lastEntryType: "transaction", assertionAmount: null, computedBalance: 1_000 }],
    savedAt: 1,
    sensitiveCached: true,
  };
}

function memoryStorage() {
  const values = new Map<string, string>();
  const storage = {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
    clear: () => values.clear(),
    key: (index: number) => Array.from(values.keys())[index] ?? null,
    get length() { return values.size; },
  } satisfies Storage;
  vi.stubGlobal("localStorage", storage);
  vi.stubGlobal("window", { localStorage: storage, setTimeout } as unknown as Window & typeof globalThis);
}

describe("ledger cache storage boundary", () => {
  afterEach(() => {
    vi.clearAllMocks();
    vi.unstubAllGlobals();
  });

  it("masks sensitive fields before writing to durable storage", () => {
    memoryStorage();
    indexedCache.write.mockResolvedValue(true);

    writeLedgerCache(range, sensitiveCache(), "CNY", "cluster:test");

    const persisted = indexedCache.write.mock.calls[0]?.[1] as LedgerCache;
    expect(persisted.balances).toEqual({});
    expect(persisted.accountBalances).toEqual([]);
    expect(persisted.netWorthRows).toEqual([]);
    expect(persisted.txns.map((txn) => txn.postings[0].account)).toEqual(["Expenses:Food"]);
    expect(persisted.incomeStatement).toMatchObject({ income: [], totalIncome: 0, totalExpense: 20, netIncome: 0 });
    expect(persisted.accountStatuses).toEqual([]);
    expect(persisted.sensitiveCached).toBe(false);
  });

  it("masks and rewrites legacy sensitive records when reading", async () => {
    memoryStorage();
    indexedCache.read.mockResolvedValueOnce(sensitiveCache());
    indexedCache.write.mockResolvedValue(true);

    const restored = await readLedgerCacheAsync(range);

    expect(restored?.balances).toEqual({});
    expect(restored?.txns.map((txn) => txn.postings[0].account)).toEqual(["Expenses:Food"]);
    expect(restored?.sensitiveCached).toBe(false);
    expect(indexedCache.write).toHaveBeenCalledWith(expect.any(String), expect.objectContaining({
      balances: {},
      sensitiveCached: false,
    }));
  });
});
