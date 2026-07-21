import { describe, expect, it } from "vitest";
import { ApiResponseError } from "@/lib/clientFetch";
import { appendImportPosting, createImportPreviewForm, gmailPendingImportActions, gmailPendingRetryURL, importActionFeedback, importEntryHasReviewError, importFlowForEntry, latestImportDocumentsByProvider, removeImportPosting, reviewableGmailPendingImports, summarizeImportPostings, updateImportPosting } from "./ImportPage";

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

describe("manual ZIP import", () => {
  it("sends the one-time password only with ZIP uploads", () => {
    const zipForm = createImportPreviewForm("auto", new File(["zip"], "statement.zip"), false, " password with spaces ");
    const csvForm = createImportPreviewForm("alipay", new File(["csv"], "statement.csv"), true, "unused");

    expect(zipForm.get("archivePassword")).toBe(" password with spaces ");
    expect(csvForm.get("archivePassword")).toBeNull();
    expect(csvForm.get("provider")).toBe("alipay");
    expect(csvForm.get("alipayFundRounding")).toBe("true");
  });
});

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

describe("import posting editor", () => {
  it("keeps the legacy funding account and displayed amount in sync", () => {
    const updated = updateImportPosting(entry({}), 1, {
      account: "Assets:CN:Cash",
      amount: "-96.50",
    });

    expect(updated.fundingAccount).toBe("Assets:CN:Cash");
    expect(updated.amount).toBe(96.5);
    expect(updated.postings[1]).toMatchObject({ account: "Assets:CN:Cash", amount: "-96.50" });
  });

  it("supports split postings and repairs the primary category after removal", () => {
    const split = entry({
      postings: [
        { account: "Expenses:Food:Meals", amount: "60.00", currency: "CNY" },
        { account: "Expenses:Transport:Taxi", amount: "22.00", currency: "CNY" },
        { account: "Liabilities:CN:CMB:CreditCard:0016", amount: "-82.00", currency: "CNY" },
      ],
    });

    const updated = removeImportPosting(split, 0);

    expect(updated.postings).toHaveLength(2);
    expect(updated.categoryAccount).toBe("Expenses:Transport:Taxi");
    expect(updated.fundingAccount).toBe("Liabilities:CN:CMB:CreditCard:0016");
  });

  it("adds a blank posting using the most recent posting currency", () => {
    const updated = appendImportPosting(entry({ currency: "USD" }));

    expect(updated.postings).toHaveLength(3);
    expect(updated.postings[2]).toEqual({ account: "", amount: "", currency: "CNY" });
    expect(importEntryHasReviewError(updated)).toBe(true);
  });

  it("summarizes posting totals and reports invalid amounts", () => {
    expect(summarizeImportPostings([
      { account: "Expenses:Food", amount: "80", currency: "cny" },
      { account: "Assets:Cash", amount: "-50", currency: "CNY" },
      { account: "Assets:Card", amount: "oops", currency: "CNY" },
    ])).toEqual({
      hasInvalidAmount: true,
      totals: [{ currency: "CNY", amount: 30 }],
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

  it("offers retry for failed imports", () => {
    expect(gmailPendingImportActions("failed")).toEqual({ retry: true, review: false, dismiss: true });
    expect(gmailPendingImportActions("ready")).toEqual({ retry: false, review: true, dismiss: true });
    expect(gmailPendingRetryURL("pending/cmb")).toBe("/api/integrations/gmail/sync?pendingId=pending%2Fcmb");
  });
});

describe("import action feedback", () => {
  it("routes locked action errors to a localized toast", () => {
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
