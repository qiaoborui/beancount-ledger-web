import { ArrowUpRight, Eye, EyeOff, RefreshCw } from "lucide-react";
import { useMemo, useState, type ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { formatValuation } from "@/lib/money";
import type { TimeRange } from "@/lib/timeRange";
import { ClientNavLink } from "./ClientNavLink";
import { formatAccountOptionLabel } from "./accountDisplay";
import { PeriodComparisonRows } from "./PeriodComparisonRows";
import { PeriodComparisonChart, type ComparisonMetric } from "./HomeReportCharts";
import { useHomeReport } from "./hooks/useHomeReport";
import type { DashboardCategorySeries, ExpenseCategoryAnalytics, HomeReport, HomeReportKPI, LedgerPeriodComparisons, PrivacySettings, Summary } from "./types";

type HomePageProps = {
  summary: Summary | null;
  comparisons?: LedgerPeriodComparisons | null;
  timeRange: TimeRange;
  valuationCurrency: string;
  ledgerRevision?: string;
  privacySettings: PrivacySettings;
  sensitiveUnlocked: boolean;
  expenseAnalytics: ExpenseCategoryAnalytics[];
  onPrivacyChange: <K extends keyof PrivacySettings>(key: K, value: PrivacySettings[K]) => void;
  onSensitiveLocked: () => void;
};

export function HomePage({ summary, comparisons, timeRange, valuationCurrency, ledgerRevision = "", privacySettings, sensitiveUnlocked, expenseAnalytics, onPrivacyChange, onSensitiveLocked }: HomePageProps) {
  const { data, loading, error, reload } = useHomeReport({ timeRange, valuationCurrency, ledgerRevision, enabled: sensitiveUnlocked, onSensitiveLocked });
  return <HomeReportWorkspace
    report={data}
    summary={summary}
    comparisons={comparisons}
    timeRange={timeRange}
    valuationCurrency={valuationCurrency}
    privacySettings={privacySettings}
    sensitiveUnlocked={sensitiveUnlocked}
    expenseAnalytics={expenseAnalytics}
    loading={loading}
    error={error}
    onReload={reload}
    onPrivacyChange={onPrivacyChange}
  />;
}

export function HomeReportWorkspace({ report, summary, comparisons, timeRange, valuationCurrency, privacySettings, sensitiveUnlocked, expenseAnalytics, loading = false, error = "", onReload, onPrivacyChange }: Omit<HomePageProps, "onSensitiveLocked"> & { report: HomeReport | null; loading?: boolean; error?: string; onReload?: () => void }) {
  const { t, i18n } = useTranslation();
  const showAmounts = privacySettings.showHomeSummaryAmounts;
  const canShowSensitive = sensitiveUnlocked && showAmounts;
  const currency = report?.currency ?? summary?.currency ?? valuationCurrency;
  const current = report?.current.kpis ?? fallbackKPIs(summary);
  const previous = report?.previous.kpis ?? emptyKPIs;
  const reportReady = Boolean(report);
  const currentLabel = report?.start.slice(0, 4) || timeRange.start.slice(0, 4);
  const previousLabel = report?.previousStart.slice(0, 4) || String(Number(currentLabel) - 1);
  const periodName = homePeriodName(timeRange, t);
  const periodScope = homePeriodScope(timeRange, t);
  const categories = useMemo(() => report?.current.categorySeries ?? fallbackCategorySeries(expenseAnalytics), [expenseAnalytics, report]);
  const [comparisonMetric, setComparisonMetric] = useState<ComparisonMetric>("net");
  const topCategory = categories[0];
  const previousTopCategory = report?.previous.categorySeries.find((row) => row.account === topCategory?.account);
  const topPaymentAccount = report?.topPaymentAccounts[0];
  const activeExpenseDays = report?.dailyExpenseSeries.length ?? Object.keys(summary?.days ?? {}).length;
  const generatedLabel = report?.generatedAt ? new Date(report.generatedAt).toLocaleString(i18n.language, { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }) : t("home.waitingForUpdate");
  const mask = (value: string) => canShowSensitive ? value : "••••••";
  const chartState = { show: canShowSensitive, loading, error, hasReport: Boolean(report), onReload };

  const categorySignal = topCategory ? {
    headline: formatAccountOptionLabel(topCategory.account, topCategory.label, topCategory.alias),
    value: canShowSensitive ? percentageOf(topCategory.total, current.expense) : "••••••",
    detail: canShowSensitive && reportReady ? comparisonCopy(topCategory.total, previousTopCategory?.total ?? 0, t) : t("home.categoryChangeHidden"),
  } : { headline: t("home.noExpenseCategory"), value: "--", detail: t("home.noExpenseCategoryDetail") };
  const paymentSignal = topPaymentAccount ? {
    headline: formatAccountOptionLabel(topPaymentAccount.account, topPaymentAccount.label, topPaymentAccount.alias),
    value: mask(formatValuation(topPaymentAccount.amount / 100, currency)),
    detail: canShowSensitive ? t("home.paymentConcentration", { count: topPaymentAccount.txCount, percent: percentageOf(topPaymentAccount.amount, current.expense) }) : t("home.paymentConcentrationHidden"),
  } : { headline: t("home.noPaymentAccount"), value: "--", detail: t("home.noPaymentAccountDetail") };

  return <div className="home-dashboard bg-panel">
    <section data-home-section="position" className="border-b border-line">
      <ReportSectionIntro
        title={t("home.periodConclusion", { name: periodName })}
        detail={t("home.homeSectionDetail", { scope: periodScope })}
        meta={loading ? t("home.updating") : generatedLabel}
        action={<button type="button" className="grid h-9 w-9 shrink-0 place-items-center rounded-md border border-line text-stone hover:bg-tag hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand" onClick={() => onPrivacyChange("showHomeSummaryAmounts", !showAmounts)} title={showAmounts ? t("home.hideHomeAmounts") : t("home.showHomeAmounts")} aria-label={showAmounts ? t("home.hideHomeAmounts") : t("home.showHomeAmounts")}>{showAmounts ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}</button>}
      />

      <div className="grid gap-px bg-line sm:grid-cols-2 xl:grid-cols-4">
        <ReportMetric label={t("home.netIncome", { scope: periodScope })} value={mask(formatValuation(current.net / 100, currency))} detail={comparisonDetail(canShowSensitive, reportReady, current.net, previous.net, t)} alert={canShowSensitive && current.net < 0} />
        <ReportMetric label={t("home.income", { scope: periodScope })} value={mask(formatValuation(current.income / 100, currency))} detail={comparisons ? <PeriodComparisonRows comparisons={comparisons.income} metric="income" currency={currency} hidden={!canShowSensitive} /> : comparisonDetail(canShowSensitive, reportReady, current.income, previous.income, t)} />
        <ReportMetric label={t("home.expense", { scope: periodScope })} value={mask(formatValuation(current.expense / 100, currency))} detail={comparisons ? <PeriodComparisonRows comparisons={comparisons.expense} metric="expense" currency={currency} hidden={!canShowSensitive} /> : comparisonDetail(canShowSensitive, reportReady, current.expense, previous.expense, t)} />
        <ReportMetric label={t("home.transactionCount")} value={canShowSensitive ? String(current.transactionCount) : "••••••"} detail={!canShowSensitive ? t("home.yoyHidden") : reportReady ? comparisonCountCopy(current.transactionCount, previous.transactionCount, t) : t("home.waitingYoY")} />
      </div>
    </section>

    <section data-home-section="pulse" className="grid border-b border-line xl:grid-cols-[minmax(0,1.55fr)_minmax(19rem,0.8fr)]">
      <div className="min-w-0 border-b border-line xl:border-b-0 xl:border-r">
        <ReportPanel title={t("home.periodTrajectory", { scope: periodScope })} detail={t("home.trajectoryDetail", { current: currentLabel, previous: previousLabel })} action={<MetricSwitch value={comparisonMetric} onChange={setComparisonMetric} t={t} />}>
          <ChartViewport {...chartState} hasData={Boolean(report?.current.cashflowSeries.length)} pointCount={report?.current.cashflowSeries.length ?? 0} t={t}>
            <PeriodComparisonChart current={report?.current.cashflowSeries ?? []} previous={report?.previous.cashflowSeries ?? []} metric={comparisonMetric} currency={currency} currentLabel={currentLabel} previousLabel={previousLabel} />
          </ChartViewport>
        </ReportPanel>
      </div>

      <div className="min-w-0">
        <ReportPanel title={t("home.pendingReview")} detail={t("home.pendingReviewDetail")}>
          <div className="divide-y divide-line">
            <DecisionSignal label={t("home.expenseStructure")} headline={categorySignal.headline} value={categorySignal.value} detail={categorySignal.detail} href="/dashboard" action={t("home.viewAttribution")} />
            <DecisionSignal label={t("home.paymentSource")} headline={paymentSignal.headline} value={paymentSignal.value} detail={paymentSignal.detail} href="/transactions" action={t("home.verifyTxns")} />
            <DecisionSignal label={t("home.coverage")} headline={t("home.expenseDays", { count: canShowSensitive ? activeExpenseDays : "••••••" })} value={canShowSensitive ? t("home.txCount", { count: current.transactionCount }) : "••••••"} detail={t("home.coverageDetail")} href="/dashboard" action={t("home.viewRhythm")} />
          </div>
        </ReportPanel>
      </div>
    </section>

    <section data-home-section="handoff">
      <ReportSectionIntro title={t("home.continueHandling")} detail={t("home.continueDetail")} />
      <div className="grid gap-px border-t border-line bg-line md:grid-cols-3">
        <DestinationRow href="/dashboard" label={t("home.dashboard")} description={t("home.dashboardDescription")} meta={canShowSensitive && topCategory ? t("home.topCategoryPrefix", { label: formatAccountOptionLabel(topCategory.account, topCategory.label, topCategory.alias) }) : t("home.filterAttribution")} />
        <DestinationRow href="/net-worth" label={t("home.netWorth")} description={t("home.netWorthDescription")} meta={report ? t("home.mainAccounts", { count: report.accountBalanceSeries.length }) : t("home.accountStructure")} />
        <DestinationRow href="/transactions" label={t("home.transactions")} description={t("home.transactionsDescription")} meta={canShowSensitive ? t("home.recordsCount", { count: current.transactionCount }) : t("home.specificTxns")} />
      </div>
    </section>
  </div>;
}

function ReportSectionIntro({ title, detail, meta, action }: { title: string; detail: string; meta?: string; action?: ReactNode }) {
  return <div className="flex min-h-24 items-start justify-between gap-5 px-4 py-5 md:min-h-20 md:px-6 md:py-4 xl:px-8">
    <div className="min-w-0"><h2 className="text-lg font-semibold tracking-[-0.018em] text-ink">{title}</h2><p className="mt-1 text-sm leading-5 text-stone">{detail}</p></div>
    <div className="flex shrink-0 items-center gap-3">{meta && <span className="hidden text-xs tabular-nums text-stone sm:block">{meta}</span>}{action}</div>
  </div>;
}

function ReportMetric({ label, value, detail, alert = false }: { label: string; value: string; detail: ReactNode; alert?: boolean }) {
  return <div className="min-w-0 bg-panel px-4 py-4 md:px-5 xl:px-6"><div className="text-[11px] font-semibold text-stone">{label}</div><div data-home-position-value="true" className={`mt-2 max-w-full whitespace-nowrap font-semibold tracking-[-0.03em] tabular-nums ${amountSizeClass(value)} ${alert ? "amount-danger" : "text-ink"}`} title={value}>{value}</div><div className="mt-3 text-xs text-stone">{detail}</div></div>;
}

function ReportPanel({ title, detail, action, children }: { title: string; detail: string; action?: ReactNode; children: ReactNode }) {
  return <section className="min-w-0 bg-panel"><div className="flex min-h-[4.5rem] flex-col gap-3 border-b border-line px-4 py-3.5 sm:flex-row sm:items-start sm:justify-between md:px-6 xl:px-8"><div className="min-w-0"><h3 className="text-base font-semibold tracking-[-0.015em] text-ink">{title}</h3><p className="mt-1.5 text-xs leading-5 text-stone">{detail}</p></div>{action}</div>{children}</section>;
}

function ChartViewport({ show, loading, error, hasReport, hasData, pointCount = 0, onReload, t, children }: { show: boolean; loading: boolean; error: string; hasReport: boolean; hasData: boolean; pointCount?: number; onReload?: () => void; t: (key: string) => string; children: ReactNode }) {
  const height = !hasData ? "min-h-48" : pointCount <= 1 ? "h-[13rem] md:h-[15rem]" : pointCount <= 4 ? "h-[16rem] md:h-[18rem]" : "h-[18rem]";
  if (!show) return <ChartStatus className={height} text={t("home.unlockToView")} />;
  if (error && !hasReport) return <ChartStatus className={height} text={error} action={onReload ? <button type="button" className="inline-flex h-9 items-center gap-2 rounded-md border border-line px-3 text-xs font-medium text-ink hover:bg-tag" onClick={onReload}><RefreshCw className="h-3.5 w-3.5" />{t("home.retry")}</button> : null} />;
  if (loading && !hasReport) return <ChartStatus className={height} text={t("home.generatingBrief")} />;
  return <div className={height}>{children}</div>;
}

function ChartStatus({ className, text, action }: { className: string; text: string; action?: ReactNode }) {
  return <div className={`grid place-items-center px-4 text-center ${className}`}><div><div className="text-sm text-stone">{text}</div>{action && <div className="mt-3">{action}</div>}</div></div>;
}

function MetricSwitch({ value, onChange, t }: { value: ComparisonMetric; onChange: (value: ComparisonMetric) => void; t: (key: string) => string }) {
  const options: { value: ComparisonMetric; label: string }[] = [{ value: "net", label: t("home.netIncomeShort") }, { value: "expense", label: t("home.expenseShort") }, { value: "income", label: t("home.incomeShort") }];
  return <div className="inline-flex shrink-0 rounded-md border border-line bg-paper p-0.5">{options.map((option) => <button key={option.value} type="button" className={`h-8 rounded-[4px] px-3 text-xs font-medium ${value === option.value ? "bg-brand text-primary-foreground" : "text-stone hover:text-ink"}`} onClick={() => onChange(option.value)} aria-pressed={value === option.value}>{option.label}</button>)}</div>;
}

function DecisionSignal({ label, headline, value, detail, href, action }: { label: string; headline: string; value: string; detail: string; href: "/dashboard" | "/transactions"; action: string }) {
  return <div className="px-4 py-3.5 md:px-6"><div className="flex items-center justify-between gap-3"><span className="text-[11px] font-semibold text-stone">{label}</span><span className="shrink-0 whitespace-nowrap text-xs font-semibold tabular-nums text-ink">{value}</span></div><div className="mt-1.5 truncate text-sm font-medium text-ink">{headline}</div><div className="mt-1 flex items-end justify-between gap-3"><span className="min-w-0 text-xs leading-5 text-stone">{detail}</span><ClientNavLink href={href} className="inline-flex shrink-0 items-center gap-1 text-xs font-medium text-brand hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand">{action}<ArrowUpRight className="h-3 w-3" /></ClientNavLink></div></div>;
}

function DestinationRow({ href, label, description, meta }: { href: "/dashboard" | "/net-worth" | "/transactions"; label: string; description: string; meta: string }) {
  return <ClientNavLink href={href} className="group min-w-0 bg-panel px-4 py-4 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand md:px-6"><div className="flex items-center justify-between gap-3"><strong className="text-sm font-semibold text-ink">{label}</strong><ArrowUpRight className="h-4 w-4 shrink-0 text-stone transition-transform group-hover:-translate-y-0.5 group-hover:translate-x-0.5 group-hover:text-brand" /></div><p className="mt-2 text-xs leading-5 text-stone">{description}</p><div className="mt-3 text-[11px] font-medium text-brand">{meta}</div></ClientNavLink>;
}

const emptyKPIs: HomeReportKPI = { income: 0, expense: 0, net: 0, transactionCount: 0, savingsRate: null };

function fallbackKPIs(summary: Summary | null): HomeReportKPI {
  return { income: summary?.income ?? 0, expense: summary?.expense ?? 0, net: summary?.net ?? 0, transactionCount: 0, savingsRate: summary?.income ? (summary.net / summary.income) : null };
}

function fallbackCategorySeries(rows: ExpenseCategoryAnalytics[]): DashboardCategorySeries[] {
  return rows.filter((row) => row.account !== "Expenses:Unknown").slice(0, 8).map((row) => ({ account: row.account, alias: row.alias, label: row.label, total: row.amount, values: [] }));
}

function homePeriodName(range: TimeRange, t: (key: string) => string) {
  if (range.preset === "year") return t("home.periodYear");
  if (range.preset === "quarter") return t("home.periodQuarter");
  if (range.preset === "month") return t("home.periodMonth");
  if (range.preset === "week") return t("home.periodWeek");
  return t("home.periodCurrent");
}

function homePeriodScope(range: TimeRange, t: (key: string) => string) {
  if (range.preset === "year") return t("home.scopeYear");
  if (range.preset === "quarter") return t("home.scopeQuarter");
  if (range.preset === "month") return t("home.scopeMonth");
  if (range.preset === "week") return t("home.scopeWeek");
  return t("home.scopeCurrent");
}

function comparisonCopy(current: number, previous: number, t: (key: string, options?: Record<string, unknown>) => string) {
  if (previous === 0) return current === 0 ? t("home.yoyDash") : t("home.yoyNew");
  const delta = (current - previous) / Math.abs(previous);
  return t("home.yoyPercent", { delta: `${delta > 0 ? "+" : ""}${(delta * 100).toFixed(0)}%` });
}

function comparisonDetail(show: boolean, ready: boolean, current: number, previous: number, t: (key: string) => string) {
  if (!show) return t("home.yoyHidden");
  return ready ? comparisonCopy(current, previous, t) : t("home.waitingYoY");
}

function comparisonCountCopy(current: number, previous: number, t: (key: string, options?: Record<string, unknown>) => string) {
  if (previous === 0) return current === 0 ? t("home.yoyDash") : t("home.yoyNew");
  return t("home.yoyCount", { delta: `${current - previous > 0 ? "+" : ""}${current - previous}` });
}

function percentageOf(value: number, total: number) {
  if (total <= 0) return "0.0%";
  return `${(value / total * 100).toFixed(1)}%`;
}

function amountSizeClass(value: string) {
  if (value.length > 20) return "text-[0.78rem] sm:text-sm";
  if (value.length > 16) return "text-sm sm:text-base";
  if (value.length > 12) return "text-base sm:text-lg";
  return "text-[clamp(1.15rem,2vw,1.75rem)]";
}
