import { renderToString } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { HomePage } from "./HomePage";
import type { ExpenseCategoryAnalytics, PrivacySettings, Summary } from "./types";

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

describe("HomePage privacy", () => {
  it("does not prepare the daily income chart before sensitive data is unlocked", () => {
    const html = renderToString(
      <HomePage
        summary={summary}
        valuationCurrency="CNY"
        privacySettings={privacySettings}
        sensitiveUnlocked={false}
        expenseAnalytics={expenseAnalytics}
        onPrivacyChange={vi.fn()}
      />,
    );

    expect(html).toContain("金额已隐藏");
    expect(html).not.toContain("趋势图稍后加载");
    expect(html).not.toContain("¥1,234.56");
  });
});

describe("HomePage layout", () => {
  it("uses a dual-chart workfield with an inspection bench on desktop", () => {
    const html = renderToString(
      <HomePage
        summary={summary}
        valuationCurrency="CNY"
        privacySettings={privacySettings}
        sensitiveUnlocked={false}
        expenseAnalytics={expenseAnalytics}
        onPrivacyChange={vi.fn()}
      />,
    );

    expect(html).toContain("xl:grid-cols-[minmax(0,1fr)_24rem]");
    expect(html).toContain("xl:grid-cols-2");
    expect(html).toContain("日收支趋势");
    expect(html).toContain("累计收支趋势");
    expect(html).not.toContain("home-structure-chart");
    expect(html).toContain("检查台");
    expect(html).toContain("最大支出日");
  });
});
