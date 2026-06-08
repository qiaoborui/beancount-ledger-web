import { describe, expect, it } from "vitest";
import { filterTransactions, matchesMetadataQuery } from "./transactionFilters";
import type { Txn } from "./types";

function txn(line: number, patch: Partial<Txn> = {}): Txn {
  return {
    date: "2026-05-20",
    payee: "Cafe",
    narration: "Lunch",
    metadata: {},
    tags: [],
    postings: [
      { account: "Expenses:Food:Coffee", amount: 1800, currency: "CNY" },
      { account: "Assets:Cash", amount: -1800, currency: "CNY" },
    ],
    source: { file: "/ledger/2026.bean", line, hash: `hash-${line}` },
    ...patch,
  };
}

describe("transaction filters", () => {
  const rows = [
    txn(1, {
      payee: "Blue Bottle",
      narration: "Morning coffee",
      metadata: { platform: "alipay", person: "mom" },
      tags: ["trip", "family"],
      postings: [
        { account: "Expenses:Food:Coffee", amount: 3500, currency: "CNY" },
        { account: "Assets:Alipay", amount: -3500, currency: "CNY" },
      ],
    }),
    txn(2, {
      payee: "Payroll",
      narration: "June salary",
      metadata: { platform: "bank", project: "office" },
      tags: ["salary"],
      postings: [
        { account: "Income:Salary", amount: -3000000, currency: "CNY" },
        { account: "Assets:Bank:CMB", amount: 3000000, currency: "CNY" },
      ],
    }),
    txn(3, {
      payee: "Supermarket",
      narration: "Groceries",
      metadata: { platform: "wechat", person: "self" },
      tags: ["home"],
      postings: [
        { account: "Expenses:Food:Groceries", amount: 8900, currency: "CNY" },
        { account: "Assets:Wechat", amount: -8900, currency: "CNY" },
      ],
    }),
  ];

  it("matches category prefixes and exact categories distinctly", () => {
    expect(filterTransactions(rows, { categoryQuery: "Expenses:Food", matchMode: "prefix" }).map((row) => row.source.line)).toEqual([1, 3]);
    expect(filterTransactions(rows, { categoryQuery: "Expenses:Food", matchMode: "exact" }).map((row) => row.source.line)).toEqual([]);
    expect(filterTransactions(rows, { categoryQuery: "Income:Salary", matchMode: "exact" }).map((row) => row.source.line)).toEqual([2]);
  });

  it("matches every keyword across payee, narration, accounts, and metadata", () => {
    expect(filterTransactions(rows, { searchQuery: "blue coffee alipay" }).map((row) => row.source.line)).toEqual([1]);
    expect(filterTransactions(rows, { searchQuery: "salary cmb" }).map((row) => row.source.line)).toEqual([2]);
  });

  it("matches metadata key/value queries and free metadata text", () => {
    expect(filterTransactions(rows, { metadataQuery: "platform:wechat person:self" }).map((row) => row.source.line)).toEqual([3]);
    expect(filterTransactions(rows, { metadataQuery: "office" }).map((row) => row.source.line)).toEqual([2]);
    expect(matchesMetadataQuery(rows[0], "person:mom platform:ali")).toBe(true);
  });

  it("matches tag queries with hash prefixes", () => {
    expect(filterTransactions(rows, { metadataQuery: "#trip" }).map((row) => row.source.line)).toEqual([1]);
    expect(filterTransactions(rows, { metadataQuery: "#family platform:alipay" }).map((row) => row.source.line)).toEqual([1]);
  });
});
