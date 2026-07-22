import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { AccountPeriodSummaryCard } from "./AccountDetailPage";
import type { AccountDetailRow } from "./types";

const inflow: AccountDetailRow = {
  date: "2026-06-29",
  payee: "名称非常长的网商银行转入账户",
  narration: "稳利宝转入并带有一段很长的交易说明",
  change: 1_103_880,
  balance: 6_549_183,
  txn: {
    date: "2026-06-29",
    payee: "名称非常长的网商银行转入账户",
    narration: "稳利宝转入并带有一段很长的交易说明",
    postings: [
      { account: "Assets:Bank:Checking", amount: 1_103_880, currency: "CNY" },
      { account: "Assets:Bank:Very:Long:Counterparty:Account", amount: -1_103_880, currency: "CNY" },
    ],
    source: { file: "transactions/2026/06.bean", line: 29 },
  },
};

describe("AccountPeriodSummaryCard layout", () => {
  it("responds to its own narrow container instead of the viewport", () => {
    const html = renderToString(
      <AccountPeriodSummaryCard
        summary={{
          inflow: inflow.change,
          outflow: 1_000_000,
          netChange: 103_880,
          maxInflow: inflow,
          maxOutflow: { ...inflow, change: -1_000_000, payee: "余额宝转出" },
          counterparties: [{ account: "Assets:Bank:Very:Long:Counterparty:Account", amount: 1_103_880, count: 3 }],
        }}
        rows={[inflow]}
        currency="CNY"
      />,
    );

    expect(html).toContain("@container");
    expect(html).toContain("@lg:grid-cols-2");
    expect(html).toContain("@sm:grid-cols-[minmax(0,1fr)_auto]");
    expect(html).not.toContain("sm:grid-cols-2");
  });
});
