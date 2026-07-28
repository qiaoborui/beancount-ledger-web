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
  budget: { configured: true, amount: 120000, currency: "CNY" },
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

    expect(html).toContain("解锁并显示金额后查看完整财务简报");
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
  it("renders the three-part financial brief from the reference structure", () => {
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

    expect(html).toContain('data-home-section="status"');
    expect(html).toContain('data-home-section="spending"');
    expect(html).toContain('data-home-section="funds"');
    expect(html).toContain("本年状态");
    expect(html).toContain("年度收支同比");
    expect(html).toContain("支出分类分布");
    expect(html).toContain("支出热力图");
    expect(html).toContain("主要资金出口");
    expect(html).toContain("账户余额走势");
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
});
