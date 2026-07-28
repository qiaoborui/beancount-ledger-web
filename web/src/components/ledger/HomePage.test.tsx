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
  it("uses a simplified two-column insight layout on desktop", () => {
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

    expect(html).toContain("xl:grid-cols-[minmax(0,8fr)_minmax(21rem,4fr)]");
    expect(html).toContain("本期支出结构图");
    expect(html).toContain("home-structure-chart");
    expect(html).toContain("xl:items-start");
    expect(html).not.toContain("检查台");
  });
});
