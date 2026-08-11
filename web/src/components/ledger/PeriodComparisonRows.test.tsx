import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { PeriodComparisonRows } from "./PeriodComparisonRows";
import type { MetricPeriodComparisons, PeriodComparison } from "./types";

function comparison(delta: number | null, percentage: number | null, baseline = 100): PeriodComparison {
  return {
    currentRange: { start: "2026-08-01", end: "2026-08-11" },
    baselineRange: { start: "2026-07-01", end: "2026-07-11" },
    current: delta == null ? null : baseline + delta,
    baseline: delta == null ? null : baseline,
    delta,
    percentage,
  };
}

function comparisons(month: PeriodComparison, year = comparison(-50, -0.2, 250)): MetricPeriodComparisons {
  return { monthOverMonth: month, yearOverYear: year };
}

describe("PeriodComparisonRows", () => {
  it("keeps signs and gives income increases a non-color direction cue", () => {
    const html = renderToString(<PeriodComparisonRows comparisons={comparisons(comparison(200, 2))} metric="income" currency="CNY" />);

    expect(html).toContain("↑ +¥2.00 · +200.0%");
    expect(html).toContain("text-[var(--success)]");
    expect(html).toContain("当前 2026-08-01 至 2026-08-11，对比 2026-07-01 至 2026-07-11");
  });

  it("marks an expense increase as unfavorable while preserving its positive sign", () => {
    const html = renderToString(<PeriodComparisonRows comparisons={comparisons(comparison(200, 2))} metric="expense" currency="CNY" />);

    expect(html).toContain("↑ +¥2.00 · +200.0%");
    expect(html).toContain("amount-danger");
  });

  it("shows an absolute delta and the U+2014 unavailable glyph for a zero baseline percentage", () => {
    const html = renderToString(<PeriodComparisonRows comparisons={comparisons(comparison(100_000, null, 0))} metric="totalAssets" currency="CNY" />);

    expect(html).toContain("↑ +¥1,000.00 · —");
    expect(html).not.toContain("Infinity");
    expect(html).not.toContain("NaN");
  });

  it("uses the localized unavailable placeholder when comparison data is missing", () => {
    const html = renderToString(<PeriodComparisonRows comparisons={comparisons(comparison(null, null))} metric="income" currency="CNY" />);

    expect(html).toContain("暂无可用比较");
  });

  it("does not expose comparison values through hidden text or accessible labels", () => {
    const html = renderToString(<PeriodComparisonRows comparisons={comparisons(comparison(987_654, 9.87654))} metric="income" currency="CNY" hidden />);

    expect(html).toContain("比较金额已隐藏");
    expect(html).toContain("••••••");
    expect(html).not.toContain("9,876.54");
    expect(html).not.toContain("987.7%");
  });
});
