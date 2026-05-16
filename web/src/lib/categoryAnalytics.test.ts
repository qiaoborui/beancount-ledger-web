import { describe, expect, it } from "vitest";
import { expenseAnalyticsSummary, expenseCategoryAnalytics } from "./categoryAnalytics";
import type { TransactionView } from "./beancountParser";

function txn(date: string, line: number, payee: string, account: string, amount: number, paymentAccount = "Assets:Cash"): TransactionView {
  return {
    date,
    payee,
    narration: "Test",
    metadata: {},
    tags: [],
    postings: [
      { account, amount, currency: "CNY" },
      { account: paymentAccount, amount: -amount, currency: "CNY" },
    ],
    source: { file: "test.bean", line },
  };
}

describe("expenseCategoryAnalytics", () => {
  it("computes share, previous-period change, counts, and top payees", () => {
    const rows = expenseCategoryAnalytics([
      txn("2026-04-02", 1, "Cafe", "Expenses:Food:Coffee", 500),
      txn("2026-05-01", 2, "Cafe", "Expenses:Food:Coffee", 800),
      txn("2026-05-02", 3, "Cafe", "Expenses:Food:Coffee", 700),
      txn("2026-05-03", 4, "Metro", "Expenses:Transport", 500),
    ], "2026-05-01", "2026-06-01");

    expect(rows.map((row) => row.account)).toEqual(["Expenses:Food:Coffee", "Expenses:Transport"]);
    expect(rows[0]).toMatchObject({
      amount: 1500,
      txCount: 2,
      previousAmount: 500,
      changeRatio: 2,
      share: 0.75,
      topPayees: [{ payee: "Cafe", amount: 1500, txCount: 2 }],
    });
    expect(rows[1]).toMatchObject({
      amount: 500,
      txCount: 1,
      previousAmount: 0,
      changeRatio: null,
      share: 0.25,
    });
  });

  it("summarizes top payees and payment accounts across expenses", () => {
    const summary = expenseAnalyticsSummary([
      txn("2026-05-01", 1, "Cafe", "Expenses:Food:Coffee", 800, "Assets:Cash"),
      txn("2026-05-02", 2, "Cafe", "Expenses:Food:Coffee", 700, "Assets:Bank"),
      txn("2026-05-03", 3, "Metro", "Expenses:Transport", 500, "Liabilities:CreditCard"),
      txn("2026-05-04", 4, "Salary", "Income:Salary", -10000, "Assets:Bank"),
    ], "2026-05-01", "2026-06-01");

    expect(summary.topPayees).toEqual([
      { payee: "Cafe", amount: 1500, txCount: 2 },
      { payee: "Metro", amount: 500, txCount: 1 },
    ]);
    expect(summary.topPaymentAccounts).toEqual([
      { account: "Assets:Bank", amount: 700, txCount: 1 },
      { account: "Assets:Cash", amount: 800, txCount: 1 },
      { account: "Liabilities:CreditCard", amount: 500, txCount: 1 },
    ].sort((a, b) => b.amount - a.amount || b.txCount - a.txCount || a.account.localeCompare(b.account)));
  });
});
