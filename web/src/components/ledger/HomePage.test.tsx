import { renderToString } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { HomePage } from "./HomePage";
import type { PrivacySettings, Summary } from "./types";

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

describe("HomePage privacy", () => {
  it("does not prepare the daily income chart before sensitive data is unlocked", () => {
    const html = renderToString(
      <HomePage
        summary={summary}
        valuationCurrency="CNY"
        privacySettings={privacySettings}
        sensitiveUnlocked={false}
        creditCards={[]}
        expenseAnalytics={[]}
        accountStatuses={[]}
        onPrivacyChange={vi.fn()}
      />,
    );

    expect(html).toContain("金额已隐藏");
    expect(html).not.toContain("趋势图稍后加载");
    expect(html).not.toContain("¥1,234.56");
  });
});

describe("HomePage layout", () => {
  it("stretches the paired insight cards to equal height on desktop", () => {
    const html = renderToString(
      <HomePage
        summary={summary}
        valuationCurrency="CNY"
        privacySettings={privacySettings}
        sensitiveUnlocked={false}
        creditCards={[]}
        expenseAnalytics={[]}
        accountStatuses={[]}
        onPrivacyChange={vi.fn()}
      />,
    );

    expect(html).toContain("mt-4 xl:items-stretch");
  });
});
