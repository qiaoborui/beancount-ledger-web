import { useTranslation } from "react-i18next";
import { formatValuation } from "@/lib/money";
import type { MetricPeriodComparisons, PeriodComparison } from "./types";

type ComparisonMetricKind = "income" | "expense" | "totalAssets";

export function PeriodComparisonRows({ comparisons, metric, currency, hidden = false }: { comparisons: MetricPeriodComparisons; metric: ComparisonMetricKind; currency: string; hidden?: boolean }) {
  const { t } = useTranslation();
  return <div className="mt-2 space-y-1 border-t border-line/70 pt-2">
    <PeriodComparisonRow label={t("comparisons.monthOverMonth")} comparison={comparisons.monthOverMonth} metric={metric} currency={currency} hidden={hidden} />
    <PeriodComparisonRow label={t("comparisons.yearOverYear")} comparison={comparisons.yearOverYear} metric={metric} currency={currency} hidden={hidden} />
  </div>;
}

function PeriodComparisonRow({ label, comparison, metric, currency, hidden }: { label: string; comparison: PeriodComparison; metric: ComparisonMetricKind; currency: string; hidden: boolean }) {
  const { t } = useTranslation();
  const available = comparison.delta != null;
  const deltaText = available ? formatSignedMoney(comparison.delta!, currency) : "—";
  const percentageText = available && comparison.percentage != null ? formatSignedPercentage(comparison.percentage) : "—";
  const direction = available ? comparison.delta! > 0 ? t("comparisons.increase") : comparison.delta! < 0 ? t("comparisons.decrease") : t("comparisons.unchanged") : t("comparisons.unavailable");
  const arrow = available ? comparison.delta! > 0 ? "↑" : comparison.delta! < 0 ? "↓" : "→" : "";
  const valueText = hidden ? "••••••" : available ? `${arrow} ${deltaText} · ${percentageText}` : t("comparisons.unavailable");
  const ranges = t("comparisons.rangeTitle", {
    currentStart: comparison.currentRange.start,
    currentEnd: comparison.currentRange.end,
    baselineStart: comparison.baselineRange.start,
    baselineEnd: comparison.baselineRange.end,
  });
  const accessible = hidden
    ? t("comparisons.hiddenAccessible", { label, ranges })
    : t("comparisons.accessible", { label, ranges, direction, delta: deltaText, percentage: percentageText });
  return <div className="flex min-w-0 items-baseline justify-between gap-2 text-[11px] leading-4" title={ranges} role="group" aria-label={accessible}>
    <span className="shrink-0 font-medium text-stone" aria-hidden="true">{label}</span>
    <span className={`min-w-0 text-right font-semibold tabular-nums ${hidden || !available ? "text-stone" : comparisonTone(metric, comparison.delta!)}`} aria-hidden="true">{valueText}</span>
  </div>;
}

function comparisonTone(metric: ComparisonMetricKind, delta: number) {
  if (delta === 0) return "text-stone";
  const favorable = metric === "expense" ? delta < 0 : delta > 0;
  return favorable ? "text-[var(--success)]" : "amount-danger";
}

function formatSignedMoney(value: number, currency: string) {
  const formatted = formatValuation(value / 100, currency);
  return value > 0 ? `+${formatted}` : formatted;
}

function formatSignedPercentage(value: number) {
  const formatted = `${(value * 100).toFixed(1)}%`;
  return value > 0 ? `+${formatted}` : formatted;
}
