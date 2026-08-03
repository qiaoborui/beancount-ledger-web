import { renderToString } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { HomePage, HomeReportWorkspace } from "./HomePage";
import type { TimeRange } from "@/lib/timeRange";
import type { ExpenseCategoryAnalytics, HomeReport, PrivacySettings, Summary } from "./types";

const summary: Summary = {
  currency: "CNY",
  income: 123456,
  expense: 7890,
  net: 115566,
  days: {
    "2026-07-01": { income: 123456, expense: 7890 },
  },
  categories: {},
};

const privacySettings: PrivacySettings = {
  homePage: "agent",
  showHomeSummaryAmounts: true,
  showAccountBalancesByDefault: false,
  showNetWorthByDefault: false,
  showIncomeStatementByDefault: false,
  valuationCurrency: "CNY",
};

const expenseAnalytics: ExpenseCategoryAnalytics[] = [
  { account: "Expenses:Food", label: "餐饮", amount: 5600, txCount: 4, share: 0.71, previousAmount: 0, changeRatio: null, topPayees: [] },
  { account: "Expenses:Transport", label: "交通", amount: 2290, txCount: 2, share: 0.29, previousAmount: 0, changeRatio: null, topPayees: [] },
];

const timeRange: TimeRange = { start: "2026-01-01", end: "2027-01-01", preset: "year" };

const report: HomeReport = {
  start: "2026-01-01",
  end: "2027-01-01",
  previousStart: "2025-01-01",
  previousEnd: "2026-01-01",
  currency: "CNY",
  current: {
    kpis: { income: 123456, expense: 7890, net: 115566, transactionCount: 6, savingsRate: 0.93 },
    cashflowSeries: [{ month: "1月", income: 123456, expense: 7890, net: 115566 }],
    categorySeries: [{ account: "Expenses:Food", label: "餐饮", total: 5600, values: [{ month: "1月", value: 5600 }] }],
  },
  previous: {
    kpis: { income: 100000, expense: 6000, net: 94000, transactionCount: 4, savingsRate: 0.94 },
    cashflowSeries: [{ month: "1月", income: 100000, expense: 6000, net: 94000 }],
    categorySeries: [{ account: "Expenses:Food", label: "餐饮", total: 4200, values: [{ month: "1月", value: 4200 }] }],
  },
  dailyExpenseSeries: [{ date: "2026-01-08", weekday: "周四", amount: 5600, txCount: 2 }],
  accountBalanceSeries: [{ account: "Assets:Cash", label: "现金", group: "cash", values: [{ month: "1月", value: 115566 }] }],
  topPaymentAccounts: [{ account: "Assets:Cash", label: "现金", amount: 7890, txCount: 6 }],
  generatedAt: "2026-07-28T10:00:00Z",
};

describe("HomePage privacy", () => {
  it("does not prepare the daily income chart before sensitive data is unlocked", () => {
    const html = renderToString(
      <HomePage
        summary={summary}
        timeRange={timeRange}
        valuationCurrency="CNY"
        privacySettings={privacySettings}
        sensitiveUnlocked={false}
        expenseAnalytics={expenseAnalytics}
        onPrivacyChange={vi.fn()}
        onSensitiveLocked={vi.fn()}
      />,
    );

    expect(html).toContain("解锁并显示金额后查看周期轨迹");
    expect(html).not.toContain("¥1,234.56");
    expect(html).not.toContain("¥78.90");
  });

  it("masks report amounts, comparisons, and amount tooltips when hidden", () => {
    const html = renderToString(
      <HomeReportWorkspace
        report={report}
        summary={summary}
        timeRange={timeRange}
        valuationCurrency="CNY"
        privacySettings={{ ...privacySettings, showHomeSummaryAmounts: false }}
        sensitiveUnlocked
        expenseAnalytics={expenseAnalytics}
        onPrivacyChange={vi.fn()}
      />,
    );

    expect(html).not.toContain("¥1,155.66");
    expect(html).not.toContain("¥56.00");
    expect(html).not.toContain("同比 +23%");
    expect(html).not.toContain("同比 +2 笔");
  });
});

describe("HomePage layout", () => {
  it("renders a decision brief with explicit handoffs instead of duplicate analysis", () => {
    const html = renderToString(
      <HomeReportWorkspace
        report={report}
        summary={summary}
        timeRange={timeRange}
        valuationCurrency="CNY"
        privacySettings={privacySettings}
        sensitiveUnlocked
        expenseAnalytics={expenseAnalytics}
        onPrivacyChange={vi.fn()}
      />,
    );

    expect(html).toContain('data-home-section="position"');
    expect(html).toContain('data-home-section="pulse"');
    expect(html).toContain('data-home-section="handoff"');
    expect(html).toContain("本年结论");
    expect(html).toContain("年度周期轨迹");
    expect(html).toContain("待核查事项");
    expect(html).toContain("收支分析");
    expect(html).toContain("资产负债");
    expect(html).toContain("支出结构");
    expect(html).toContain("付款来源");
    expect(html).toContain("记录覆盖");
    expect(html).not.toContain(String.fromCodePoint(0x9884, 0x7b97));
    expect(html).not.toContain("支出热力图");
    expect(html).not.toContain("账户余额走势");
  });

  it("renders complete position amounts without truncation classes", () => {
    const html = renderToString(
      <HomeReportWorkspace
        report={report}
        summary={summary}
        timeRange={timeRange}
        valuationCurrency="CNY"
        privacySettings={privacySettings}
        sensitiveUnlocked
        expenseAnalytics={expenseAnalytics}
        onPrivacyChange={vi.fn()}
      />,
    );

    expect(html).toContain("¥1,155.66");
    expect(html).toContain('data-home-position-value="true"');
    expect(html).not.toMatch(/data-home-position-value="true"[^>]*truncate/);
  });

  it("reduces position type size for exceptionally long amounts", () => {
    const html = renderToString(
      <HomeReportWorkspace
        report={{ ...report, current: { ...report.current, kpis: { ...report.current.kpis, net: 123456789012345 } } }}
        summary={summary}
        timeRange={timeRange}
        valuationCurrency="CNY"
        privacySettings={privacySettings}
        sensitiveUnlocked
        expenseAnalytics={expenseAnalytics}
        onPrivacyChange={vi.fn()}
      />,
    );

    expect(html).toContain("text-[0.78rem]");
  });
});
