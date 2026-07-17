import { describe, expect, it } from "vitest";
import { ApiResponseError } from "@/lib/clientFetch";
import { importActionFeedback, importFlowForEntry, latestImportDocumentsByProvider, reviewableGmailPendingImports } from "./ImportPage";

type ImportEntryInput = Parameters<typeof importFlowForEntry>[0];
type ImportDocumentInput = Parameters<typeof latestImportDocumentsByProvider>[0][number];

function entry(patch: Partial<ImportEntryInput>): ImportEntryInput {
  return {
    id: "import-1",
    date: "2026-06-08",
    flag: "*",
    payee: "Merchant",
    narration: "Merchant",
    categoryAccount: "Expenses:Food:Meals",
    fundingAccount: "Liabilities:CN:CMB:CreditCard:0016",
    amount: 82,
    currency: "CNY",
    metadata: {},
    postings: [
      { account: "Expenses:Food:Meals", amount: "82.00", currency: "CNY" },
      { account: "Liabilities:CN:CMB:CreditCard:0016", amount: "-82.00", currency: "CNY" },
    ],
    ...patch,
  };
}

describe("import flow display", () => {
  it("shows normal expenses from funding account to expense category", () => {
    expect(importFlowForEntry(entry({}))).toEqual({
      from: "Liabilities:CN:CMB:CreditCard:0016",
      to: "Expenses:Food:Meals",
      kind: "支出流向",
    });
  });

  it("shows refunds from the expense category back to the funding account", () => {
    expect(importFlowForEntry(entry({
      postings: [
        { account: "Liabilities:CN:CMB:CreditCard:0016", amount: "82.00", currency: "CNY" },
        { account: "Expenses:Food:Meals", amount: "-82.00", currency: "CNY" },
      ],
    }))).toEqual({
      from: "Expenses:Food:Meals",
      to: "Liabilities:CN:CMB:CreditCard:0016",
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

describe("latest import coverage by provider", () => {
  function document(patch: Partial<ImportDocumentInput>): ImportDocumentInput {
    return {
      path: "transactions/2026/documents/imports/statement.pdf",
      name: "statement.pdf",
      year: "2026",
      ext: ".pdf",
      provider: "alipay",
      dateStart: "2026-05-01",
      dateEnd: "2026-05-31",
      size: 1024,
      modTime: "2026-06-01T08:00:00Z",
      ...patch,
    };
  }

  it("uses the latest statement end date for each provider", () => {
    const latest = latestImportDocumentsByProvider([
      document({ provider: "alipay", dateStart: "2026-05-01", dateEnd: "2026-05-31", modTime: "2026-06-08T08:00:00Z", name: "older-uploaded-later.pdf" }),
      document({ provider: "alipay", dateStart: "2026-06-01", dateEnd: "2026-06-10", modTime: "2026-06-07T08:00:00Z", name: "newer-statement.pdf" }),
      document({ provider: "wechat", dateStart: "2026-06-01", dateEnd: "2026-06-05", name: "wechat.xlsx" }),
    ]);

    expect(latest.alipay?.name).toBe("newer-statement.pdf");
    expect(latest.wechat?.dateEnd).toBe("2026-06-05");
  });

  it("ignores documents without a known provider", () => {
    const latest = latestImportDocumentsByProvider([
      document({ provider: undefined, name: "unknown.pdf" }),
      document({ provider: "cmb", dateStart: "2026-04-01", dateEnd: "2026-04-30", name: "cmb.pdf" }),
    ]);

    expect(Object.keys(latest)).toEqual(["cmb"]);
  });
});

describe("Gmail pending imports", () => {
  it("keeps ready and failed items in the Review inbox", () => {
    const base = { id: "pending", messageId: "message", sender: "bill@example.com", subject: "账单", receivedAt: "2026-07-15T00:00:00Z", filename: "statement.csv", candidateCount: 1, createdAt: "2026-07-15T00:00:00Z", updatedAt: "2026-07-15T00:00:00Z" };
    const visible = reviewableGmailPendingImports([
      { ...base, id: "ready", status: "ready" },
      { ...base, id: "failed", status: "failed" },
      { ...base, id: "committed", status: "committed" },
      { ...base, id: "dismissed", status: "dismissed" },
    ]);
    expect(visible.map((item) => item.id)).toEqual(["ready", "failed"]);
  });
});

describe("import action feedback", () => {
  it("routes locked action errors to a toast and the sensitive unlock flow", () => {
    const error = new ApiResponseError(
      "Sensitive data is locked",
      new Response(JSON.stringify({ error: "Sensitive data is locked" }), { status: 423 }),
      "write",
    );

    expect(importActionFeedback(error)).toBe("敏感数据已锁定，请先解锁后重试");
  });

  it("keeps other action errors in toast feedback", () => {
    expect(importActionFeedback(new Error("Gmail 同步失败"))).toBe("Gmail 同步失败");
  });
});
