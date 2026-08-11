import { renderToString } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { NetWorthPage } from "./NetWorthPage";
import type { AccountBalance, AccountView, MetricPeriodComparisons, NetWorthWindows } from "./types";

const accounts: AccountView[] = [
  { account: "Assets:Cash", openDate: "2024-01-01", closeDate: null, currency: "CNY", alias: null, label: "现金", group: "cash", active: true },
  { account: "Assets:Broker", openDate: "2024-01-01", closeDate: null, currency: "CNY", alias: null, label: "证券账户", group: "wealth", active: true },
  { account: "Liabilities:Card", openDate: "2024-01-01", closeDate: null, currency: "CNY", alias: null, label: "信用卡", group: "credit", active: true },
];

const accountBalances: AccountBalance[] = [
  { account: "Assets:Cash", currency: "CNY", amount: 500000, valuationCurrency: "CNY", valuation: 500000 },
  { account: "Assets:Broker", currency: "CNY", amount: 800000, valuationCurrency: "CNY", valuation: 800000 },
  { account: "Liabilities:Card", currency: "CNY", amount: -120000, valuationCurrency: "CNY", valuation: -120000 },
];

const windows: NetWorthWindows = {
  latest: { date: "2026-07-28", assets: 1300000, liabilities: 120000, netWorth: 1180000 },
  previousMonthEnd: { date: "2026-06-30", assets: 1200000, liabilities: 110000, netWorth: 1090000 },
  monthChange: 90000,
  sixMonth: { baseline: null, change: 180000, changeRatio: 0.18 },
  twelveMonth: { baseline: null, change: 260000, changeRatio: 0.28 },
};

const comparisons: MetricPeriodComparisons = {
  monthOverMonth: { currentRange: { start: "2026-07-01", end: "2026-07-31" }, baselineRange: { start: "2026-06-01", end: "2026-06-30" }, current: 1200000, baseline: 1100000, delta: 100000, percentage: 1 / 11 },
  yearOverYear: { currentRange: { start: "2026-07-01", end: "2026-07-31" }, baselineRange: { start: "2025-07-01", end: "2025-07-31" }, current: 1200000, baseline: 1000000, delta: 200000, percentage: 0.2 },
};

describe("NetWorthPage information architecture", () => {
  it("adds selected period-end comparisons under the existing total-assets value", () => {
    const html = renderToString(
      <NetWorthPage
        rows={[]}
        monthEndRows={[]}
        windows={windows}
        accountBalances={accountBalances}
        accounts={accounts}
        comparisons={comparisons}
        valuationCurrency="CNY"
        visible
        onToggleVisible={vi.fn()}
      />,
    );

    expect(html).toContain("¥13,000.00");
    expect(html).toContain("↑ +¥1,000.00 · +9.1%");
    expect(html).toContain("当前 2026-07-01 至 2026-07-31，对比 2026-06-01 至 2026-06-30");
  });

  it("renders a balance-sheet workspace without income-statement metrics", () => {
    const html = renderToString(
      <NetWorthPage
        rows={[{ date: "07-28", assets: 13000, liabilities: 1200, netWorth: 11800 }]}
        monthEndRows={[windows.previousMonthEnd!, windows.latest!]}
        windows={windows}
        accountBalances={accountBalances}
        accounts={accounts}
        valuationCurrency="CNY"
        visible
        onToggleVisible={vi.fn()}
      />,
    );

    expect(html).toContain('data-asset-section="position"');
    expect(html).toContain('data-asset-section="structure"');
    expect(html).toContain('data-asset-section="movement"');
    expect(html).toContain("当前头寸");
    expect(html).toContain("资产结构");
    expect(html).toContain("净值变化");
    expect(html).not.toContain("储蓄率");
    expect(html).not.toContain("财富/投资收入");
  });

  it("masks position values, ratios, and trend charts together", () => {
    const html = renderToString(
      <NetWorthPage
        rows={[{ date: "07-28", assets: 13000, liabilities: 1200, netWorth: 11800 }]}
        monthEndRows={[]}
        windows={windows}
        accountBalances={accountBalances}
        accounts={accounts}
        valuationCurrency="CNY"
        visible={false}
        onToggleVisible={vi.fn()}
      />,
    );

    expect(html).not.toContain("¥13,000.00");
    expect(html).not.toContain("9.2%");
    expect(html).toContain("此区域包含具体金额");
    expect(html).toContain("width:0%");
  });
});
