import { describe, expect, it } from "vitest";
import { buildLedgerCacheFromBootstrap, maskSensitiveLedgerCache, type LedgerBootstrapResponse } from "./useLedgerData";
import type { LedgerVersion, Txn } from "../types";

const version: LedgerVersion = { version: "v1", fileCount: 1, latestMtimeMs: 123 };

function txn(account: string): Txn {
  return {
    date: "2026-06-01",
    payee: "Test",
    narration: account,
    postings: [{ account, amount: 100, currency: "CNY" }],
    source: { file: "transactions.bean", line: 1 },
  };
}

describe("buildLedgerCacheFromBootstrap", () => {
  it("keeps locked client state masked even if the server session is still sensitive-unlocked", () => {
    const data: LedgerBootstrapResponse = {
      sensitiveUnlocked: true,
      valuationCurrency: "CNY",
      summary: { income: 100, expense: 20, net: 80, days: {}, categories: {} },
      balances: { "Assets:Cash": 1000 },
      accountBalances: [{ account: "Assets:Cash", currency: "CNY", amount: 1000, valuationCurrency: "CNY", valuation: 1000 }],
      netWorthHistory: [{ date: "2026-06-01", assets: 1000, liabilities: 0, netWorth: 1000 }],
      transactions: [txn("Income:Salary"), txn("Expenses:Food")],
      incomeStatement: {
        income: [{ account: "Income:Salary", label: "Salary", amount: 100, children: [], depth: 0, txCount: 1 }],
        expense: [],
        totalIncome: 100,
        totalExpense: 20,
        netIncome: 80,
        valuationCurrency: "CNY",
      },
      accountStatuses: [{ account: "Assets:Cash", status: "green", lastEntryDate: "2026-06-01", lastEntryType: "transaction", assertionAmount: null, computedBalance: 1000 }],
      ledgerVersion: version,
    };

    const { cache, cacheUnlocked } = buildLedgerCacheFromBootstrap(data, false, "CNY", version, 1_234);

    expect(cacheUnlocked).toBe(false);
    expect(cache.balances).toEqual({});
    expect(cache.accountBalances).toEqual([]);
    expect(cache.netWorthRows).toEqual([]);
    expect(cache.incomeStatement?.income).toEqual([]);
    expect(cache.incomeStatement?.totalIncome).toBe(0);
    expect(cache.incomeStatement?.netIncome).toBe(0);
    expect(cache.accountStatuses).toEqual([]);
    expect(cache.txns).toHaveLength(1);
    expect(cache.txns[0].postings[0].account).toBe("Expenses:Food");
    expect(cache.ledgerVersion).toEqual(version);
    expect(cache.savedAt).toBe(1_234);
  });
});

describe("maskSensitiveLedgerCache", () => {
  it("keeps cached offline data readable without exposing sensitive unlocked fields", () => {
    const { cache } = buildLedgerCacheFromBootstrap({
      sensitiveUnlocked: true,
      valuationCurrency: "CNY",
      summary: { income: 100, expense: 20, net: 80, days: {}, categories: {} },
      balances: { "Assets:Cash": 1000 },
      accountBalances: [{ account: "Assets:Cash", currency: "CNY", amount: 1000, valuationCurrency: "CNY", valuation: 1000 }],
      netWorthHistory: [{ date: "2026-06-01", assets: 1000, liabilities: 0, netWorth: 1000 }],
      transactions: [txn("Income:Salary"), txn("Expenses:Food")],
      incomeStatement: {
        income: [{ account: "Income:Salary", label: "Salary", amount: 100, children: [], depth: 0, txCount: 1 }],
        expense: [],
        totalIncome: 100,
        totalExpense: 20,
        netIncome: 80,
        valuationCurrency: "CNY",
      },
      accountStatuses: [{ account: "Assets:Cash", status: "green", lastEntryDate: "2026-06-01", lastEntryType: "transaction", assertionAmount: null, computedBalance: 1000 }],
      ledgerVersion: version,
    }, true, "CNY", version, 1_234);

    const masked = maskSensitiveLedgerCache(cache);

    expect(masked.summary).toEqual(cache.summary);
    expect(masked.balances).toEqual({});
    expect(masked.accountBalances).toEqual([]);
    expect(masked.netWorthRows).toEqual([]);
    expect(masked.txns).toHaveLength(1);
    expect(masked.txns[0].postings[0].account).toBe("Expenses:Food");
    expect(masked.incomeStatement?.income).toEqual([]);
    expect(masked.incomeStatement?.totalIncome).toBe(0);
    expect(masked.incomeStatement?.totalExpense).toBe(20);
    expect(masked.ledgerVersion).toEqual(version);
  });
});
