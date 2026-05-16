import { describe, expect, it } from "vitest";
import { creditCardAnalytics, monthEndNetWorth, netWorthChangeWindows } from "./assetAnalytics";
import type { AccountView, TransactionView } from "./beancountParser";

function txn(date: string, line: number, postings: TransactionView["postings"]): TransactionView {
  return { date, payee: "Test", narration: "Test", metadata: {}, tags: [], postings, source: { file: "test.bean", line } };
}

const cardAccount: AccountView = {
  account: "Liabilities:CreditCard:Visa",
  openDate: "2026-01-01",
  closeDate: null,
  currency: "CNY",
  alias: "Visa",
  label: "Visa",
  group: "credit",
  active: true,
};

describe("asset analytics", () => {
  it("selects month-end net worth snapshots and change windows", () => {
    const rows = [
      { date: "2025-06-15", assets: 100000, liabilities: 10000, netWorth: 90000 },
      { date: "2025-06-30", assets: 110000, liabilities: 10000, netWorth: 100000 },
      { date: "2025-12-31", assets: 160000, liabilities: 10000, netWorth: 150000 },
      { date: "2026-04-30", assets: 190000, liabilities: 20000, netWorth: 170000 },
      { date: "2026-05-10", assets: 210000, liabilities: 20000, netWorth: 190000 },
    ];

    expect(monthEndNetWorth(rows)).toEqual([
      rows[1],
      rows[2],
      rows[3],
      rows[4],
    ]);
    expect(netWorthChangeWindows(rows)).toMatchObject({
      latest: rows[4],
      previousMonthEnd: rows[3],
      monthChange: 20000,
      sixMonth: { baseline: rows[1], change: 90000, changeRatio: 0.9 },
      twelveMonth: { baseline: rows[1], change: 90000, changeRatio: 0.9 },
    });
  });

  it("summarizes credit card outstanding, spending, repayments and activity", () => {
    const rows = creditCardAnalytics([
      txn("2026-05-01", 1, [
        { account: "Expenses:Food", amount: 5000, currency: "CNY" },
        { account: "Liabilities:CreditCard:Visa", amount: -5000, currency: "CNY" },
      ]),
      txn("2026-05-03", 2, [
        { account: "Assets:Bank", amount: -3000, currency: "CNY" },
        { account: "Liabilities:CreditCard:Visa", amount: 3000, currency: "CNY" },
      ]),
      txn("2026-04-20", 3, [
        { account: "Expenses:Travel", amount: 8000, currency: "CNY" },
        { account: "Liabilities:CreditCard:Visa", amount: -8000, currency: "CNY" },
      ]),
    ], { "Liabilities:CreditCard:Visa": -10000 }, [cardAccount], "2026-05-01", "2026-06-01");

    expect(rows).toEqual([{ account: "Liabilities:CreditCard:Visa", label: "Visa", balance: -10000, outstanding: 10000, periodSpend: 5000, periodRepayments: 3000, txCount: 1, repaymentCount: 1, lastActivityDate: "2026-05-03" }]);
  });
});
