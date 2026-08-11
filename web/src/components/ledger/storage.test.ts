import { afterEach, describe, expect, it, vi } from "vitest";
import { timeRangeCacheKey } from "@/lib/timeRange";
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
    summary: {
      currency: "CNY",
      income: 100,
      expense: 20,
      net: 80,
      days: { "2026-08-01": { income: 100, expense: 20 } },
      categories: { "Expenses:Food": 20 },
    },
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

function legacyCacheWithSensitiveSummaryOnly(): LedgerCache {
  const cache = sensitiveCache();
  return {
    ...cache,
    balances: {},
    accountBalances: [],
    txns: [transaction("Expenses:Food")],
    netWorthRows: [],
    reconciliationRows: [],
    incomeStatement: cache.incomeStatement ? {
      ...cache.incomeStatement,
      income: [],
      totalIncome: 0,
      netIncome: 0,
    } : null,
    accountStatuses: [],
    sensitiveCached: false,
  };
}

function memoryStorage(initial: Record<string, string> = {}) {
  const values = new Map(Object.entries(initial));
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
  return values;
}

describe("ledger cache storage boundary", () => {
  afterEach(() => {
    vi.clearAllMocks();
    vi.unstubAllGlobals();
  });

  it("masks sensitive fields before writing to durable storage", async () => {
    const local = memoryStorage();
    indexedCache.write.mockResolvedValue(true);

    writeLedgerCache(range, sensitiveCache(), "CNY", "cluster:test");

    const persisted = indexedCache.write.mock.calls[0]?.[1] as LedgerCache;
    expect(persisted.summary).toEqual({
      currency: "CNY",
      income: 0,
      expense: 20,
      net: 0,
      days: { "2026-08-01": { income: 0, expense: 20 } },
      categories: { "Expenses:Food": 20 },
    });
    expect(persisted.balances).toEqual({});
    expect(persisted.accountBalances).toEqual([]);
    expect(persisted.netWorthRows).toEqual([]);
    expect(persisted.txns.map((txn) => txn.postings[0].account)).toEqual(["Expenses:Food"]);
    expect(persisted.incomeStatement).toMatchObject({ income: [], totalIncome: 0, totalExpense: 20, netIncome: 0 });
    expect(persisted.accountStatuses).toEqual([]);
    expect(persisted.sensitiveCached).toBe(false);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(JSON.parse(local.get(indexedCache.write.mock.calls[0][0]) ?? "null")).toEqual(persisted);
  });

  it("masks and rewrites legacy sensitive records when reading", async () => {
    memoryStorage();
    indexedCache.read.mockResolvedValueOnce(legacyCacheWithSensitiveSummaryOnly());
    indexedCache.write.mockResolvedValue(true);

    const restored = await readLedgerCacheAsync(range);

    expect(restored?.summary).toEqual({
      currency: "CNY",
      income: 0,
      expense: 20,
      net: 0,
      days: { "2026-08-01": { income: 0, expense: 20 } },
      categories: { "Expenses:Food": 20 },
    });
    expect(restored?.balances).toEqual({});
    expect(restored?.txns.map((txn) => txn.postings[0].account)).toEqual(["Expenses:Food"]);
    expect(restored?.sensitiveCached).toBe(false);
    expect(indexedCache.write).toHaveBeenCalledWith(expect.any(String), expect.objectContaining({
      balances: {},
      summary: {
        currency: "CNY",
        income: 0,
        expense: 20,
        net: 0,
        days: { "2026-08-01": { income: 0, expense: 20 } },
        categories: { "Expenses:Food": 20 },
      },
      sensitiveCached: false,
    }));
  });

  it.each([
    ["total income", 100, 0, 0],
    ["net income", 0, 80, 0],
    ["daily income", 0, 0, 100],
  ])("rewrites a legacy record when only %s remains sensitive", async (_label, income, net, dailyIncome) => {
    memoryStorage();
    const legacy = legacyCacheWithSensitiveSummaryOnly();
    legacy.summary = legacy.summary ? {
      ...legacy.summary,
      income,
      net,
      days: { "2026-08-01": { income: dailyIncome, expense: 20 } },
    } : null;
    indexedCache.read.mockResolvedValueOnce(legacy);
    indexedCache.write.mockResolvedValue(true);

    await readLedgerCacheAsync(range);

    expect(indexedCache.write).toHaveBeenCalledTimes(1);
  });

  it("sanitizes the unscoped source record while migrating it to the current scope", async () => {
    const sourceKey = timeRangeCacheKey(range);
    const local = memoryStorage({ [sourceKey]: JSON.stringify(legacyCacheWithSensitiveSummaryOnly()) });
    indexedCache.read.mockResolvedValue(null);
    indexedCache.write.mockResolvedValue(true);

    const restored = await readLedgerCacheAsync(range);

    expect(restored?.summary).toMatchObject({ income: 0, expense: 20, net: 0 });
    const writes = indexedCache.write.mock.calls as [string, LedgerCache][];
    expect(writes).toHaveLength(2);
    expect(new Set(writes.map(([key]) => key)).size).toBe(2);
    for (const [, persisted] of writes) {
      expect(persisted.summary).toEqual({
        currency: "CNY",
        income: 0,
        expense: 20,
        net: 0,
        days: { "2026-08-01": { income: 0, expense: 20 } },
        categories: { "Expenses:Food": 20 },
      });
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
    const targetKey = writes.find(([key]) => key !== sourceKey)?.[0];
    expect(targetKey).toBeTruthy();
    expect(JSON.parse(local.get(sourceKey) ?? "null").summary).toEqual(writes[0][1].summary);
    expect(JSON.parse(local.get(targetKey ?? "") ?? "null").summary).toEqual(writes[0][1].summary);
  });
});
