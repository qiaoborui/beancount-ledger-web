import { describe, expect, it } from "vitest";
import { transactionDisplayAmount } from "./TransactionList";
import type { AccountView, Txn } from "./types";

const source = { file: "transactions/2026/07.bean", line: 1 };

function account(account: string, group: AccountView["group"]): AccountView {
  return { account, group, active: true, alias: null, label: account, currency: "HKD", openDate: "2026-01-01", closeDate: null };
}

describe("transactionDisplayAmount", () => {
  it("uses the settlement cash amount for a stock sale instead of fee or gain postings", () => {
    const txn: Txn = {
      date: "2026-07-27",
      payee: "HSBC",
      narration: "Sell SSPC 5 @ 22.21",
      source,
      postings: [
        { account: "Assets:HK:HSBC:Investments:SSPC", amount: -500, currency: "SSPC" },
        { account: "Assets:HK:HSBC:Cash", amount: 1099500, currency: "HKD" },
        { account: "Expenses:Investment:Fee", amount: 100, currency: "HKD" },
        { account: "Income:Investment:Gain", amount: -1099100, currency: "HKD" },
      ],
    };
    const accounts = [
      account("Assets:HK:HSBC:Investments:SSPC", "wealth"),
      account("Assets:HK:HSBC:Cash", "cash"),
      account("Expenses:Investment:Fee", "expense"),
      account("Income:Investment:Gain", "income"),
    ];

    expect(transactionDisplayAmount(txn, accounts)).toEqual({
      account: "Assets:HK:HSBC:Cash",
      amount: 1099500,
      currency: "HKD",
      direction: "inflow",
    });
  });

  it("uses the total payment for a split expense instead of the first category", () => {
    const txn: Txn = {
      date: "2026-06-27",
      payee: "朋友聚餐",
      narration: "代付三人晚餐",
      source,
      postings: [
        { account: "Assets:CN:Wechat:Balance", amount: -28800, currency: "CNY" },
        { account: "Expenses:Social:Treat", amount: 9600, currency: "CNY" },
        { account: "Expenses:Food:Restaurant", amount: 19200, currency: "CNY" },
      ],
    };
    const accounts = [
      account("Assets:CN:Wechat:Balance", "cash"),
      account("Expenses:Social:Treat", "expense"),
      account("Expenses:Food:Restaurant", "expense"),
    ];

    expect(transactionDisplayAmount(txn, accounts)).toEqual({
      account: "Assets:CN:Wechat:Balance",
      amount: 28800,
      currency: "CNY",
      direction: "outflow",
    });
  });

  it("keeps account transfers neutral and unsigned", () => {
    const txn: Txn = {
      date: "2026-07-28",
      payee: "",
      narration: "Transfer to brokerage",
      source,
      postings: [
        { account: "Assets:HK:HSBC:Cash", amount: -500000, currency: "HKD" },
        { account: "Assets:HK:Broker:Cash", amount: 500000, currency: "HKD" },
      ],
    };
    const accounts = [
      account("Assets:HK:HSBC:Cash", "cash"),
      account("Assets:HK:Broker:Cash", "cash"),
    ];

    expect(transactionDisplayAmount(txn, accounts)).toEqual({
      account: "Assets:HK:HSBC:Cash",
      amount: 500000,
      currency: "HKD",
      direction: "transfer",
    });
  });
});
