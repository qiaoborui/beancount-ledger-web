import { describe, expect, it } from "vitest";
import { importFlowForEntry } from "./ImportPage";

type ImportEntryInput = Parameters<typeof importFlowForEntry>[0];

function entry(patch: Partial<ImportEntryInput>): ImportEntryInput {
  return {
    id: "import-1",
    date: "2026-06-08",
    flag: "*",
    payee: "Merchant",
    narration: "Merchant",
    categoryAccount: "Expenses:Food:Meals",
    fundingAccount: "Liabilities:CN:CMB:CreditCard",
    amount: 82,
    currency: "CNY",
    metadata: {},
    postings: [
      { account: "Expenses:Food:Meals", amount: "82.00", currency: "CNY" },
      { account: "Liabilities:CN:CMB:CreditCard", amount: "-82.00", currency: "CNY" },
    ],
    ...patch,
  };
}

describe("import flow display", () => {
  it("shows normal expenses from funding account to expense category", () => {
    expect(importFlowForEntry(entry({}))).toEqual({
      from: "Liabilities:CN:CMB:CreditCard",
      to: "Expenses:Food:Meals",
      kind: "支出流向",
    });
  });

  it("shows refunds from the expense category back to the funding account", () => {
    expect(importFlowForEntry(entry({
      postings: [
        { account: "Liabilities:CN:CMB:CreditCard", amount: "82.00", currency: "CNY" },
        { account: "Expenses:Food:Meals", amount: "-82.00", currency: "CNY" },
      ],
    }))).toEqual({
      from: "Expenses:Food:Meals",
      to: "Liabilities:CN:CMB:CreditCard",
      kind: "退款流入",
    });
  });

  it("keeps income flowing from income category to the receiving account", () => {
    expect(importFlowForEntry(entry({
      categoryAccount: "Income:Other",
      fundingAccount: "Assets:CN:Wechat:Balance",
      postings: [
        { account: "Assets:CN:Wechat:Balance", amount: "82.00", currency: "CNY" },
        { account: "Income:Other", amount: "-82.00", currency: "CNY" },
      ],
    }))).toEqual({
      from: "Income:Other",
      to: "Assets:CN:Wechat:Balance",
      kind: "收入流入",
    });
  });

  it("uses posting signs for non-category account transfers", () => {
    expect(importFlowForEntry(entry({
      categoryAccount: "Assets:CN:Wechat:Balance",
      fundingAccount: "Assets:CN:Bank:PrimaryChecking",
      postings: [
        { account: "Assets:CN:Wechat:Balance", amount: "100.00", currency: "CNY" },
        { account: "Assets:CN:Bank:PrimaryChecking", amount: "-100.00", currency: "CNY" },
      ],
    }))).toEqual({
      from: "Assets:CN:Bank:PrimaryChecking",
      to: "Assets:CN:Wechat:Balance",
      kind: "账户转移",
    });
  });
});
