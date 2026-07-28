import { Eye, EyeOff, RefreshCw } from "lucide-react";
import { useEffect, useMemo, useState, type ReactNode } from "react";
import { formatValuation } from "@/lib/money";
import type { TimeRange } from "@/lib/timeRange";
import { formatAccountOptionLabel } from "./accountDisplay";
import {
  AccountBalanceTrendChart,
  CashflowTrendChart,
  CategoryComparisonChart,
  CategoryDistributionChart,
  ExpenseHeatmap,
  PaymentAccountChart,
  PeriodComparisonChart,
  type ComparisonMetric,
} from "./HomeReportCharts";
import { useHomeReport } from "./hooks/useHomeReport";
import type { DashboardCategorySeries, ExpenseCategoryAnalytics, HomeReport, HomeReportKPI, PrivacySettings, Summary } from "./types";

type HomePageProps = {
  summary: Summary | null;
  timeRange: TimeRange;
  valuationCurrency: string;
  ledgerRevision?: string;
  privacySettings: PrivacySettings;
  sensitiveUnlocked: boolean;
  expenseAnalytics: ExpenseCategoryAnalytics[];
  onPrivacyChange: <K extends keyof PrivacySettings>(key: K, value: PrivacySettings[K]) => void;
  onSensitiveLocked: () => void;
  onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void;
};

export function HomePage({ summary, timeRange, valuationCurrency, ledgerRevision = "", privacySettings, sensitiveUnlocked, expenseAnalytics, onPrivacyChange, onSensitiveLocked, onSelectCategory }: HomePageProps) {
  const { data, loading, error, reload } = useHomeReport({ timeRange, valuationCurrency, ledgerRevision, enabled: sensitiveUnlocked, onSensitiveLocked });
  return <HomeReportWorkspace
    report={data}
    summary={summary}
    timeRange={timeRange}
    valuationCurrency={valuationCurrency}
    privacySettings={privacySettings}
    sensitiveUnlocked={sensitiveUnlocked}
    expenseAnalytics={expenseAnalytics}
    loading={loading}
    error={error}
    onReload={reload}
    onPrivacyChange={onPrivacyChange}
    onSelectCategory={onSelectCategory}
  />;
}

export function HomeReportWorkspace({ report, summary, timeRange, valuationCurrency, privacySettings, sensitiveUnlocked, expenseAnalytics, loading = false, error = "", onReload, onPrivacyChange, onSelectCategory }: Omit<HomePageProps, "onSensitiveLocked"> & { report: HomeReport | null; loading?: boolean; error?: string; onReload?: () => void }) {
  const showAmounts = privacySettings.showHomeSummaryAmounts;
  const canShowSensitive = sensitiveUnlocked && showAmounts;
  const currency = report?.currency ?? summary?.currency ?? valuationCurrency;
  const current = report?.current.kpis ?? fallbackKPIs(summary);
  const previous = report?.previous.kpis ?? emptyKPIs;
  const reportReady = Boolean(report);
  const currentLabel = report?.start.slice(0, 4) || timeRange.start.slice(0, 4);
  const previousLabel = report?.previousStart.slice(0, 4) || String(Number(currentLabel) - 1);
  const periodName = homePeriodName(timeRange);
  const periodScope = homePeriodScope(timeRange);
  const categories = useMemo(() => report?.current.categorySeries ?? fallbackCategorySeries(expenseAnalytics), [expenseAnalytics, report]);
  const accounts = report?.accountBalanceSeries ?? [];
  const [comparisonMetric, setComparisonMetric] = useState<ComparisonMetric>("expense");
  const [categoryAccount, setCategoryAccount] = useState(categories[0]?.account ?? "");
  const [account, setAccount] = useState(accounts[0]?.account ?? "");

  useEffect(() => {
    if (!categories.some((row) => row.account === categoryAccount)) setCategoryAccount(categories[0]?.account ?? "");
  }, [categories, categoryAccount]);
  useEffect(() => {
    if (!accounts.some((row) => row.account === account)) setAccount(accounts[0]?.account ?? "");
  }, [account, accounts]);

  const mask = (value: string) => canShowSensitive ? value : "••••••";
  const selectedCategory = categories.find((row) => row.account === categoryAccount) ?? categories[0];
  const previousCategory = report?.previous.categorySeries.find((row) => row.account === selectedCategory?.account);
  const selectedAccount = accounts.find((row) => row.account === account) ?? accounts[0];
  const generatedLabel = report?.generatedAt ? new Date(report.generatedAt).toLocaleString("zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }) : "等待更新";
  const chartState = { show: canShowSensitive, loading, error, hasReport: Boolean(report), onReload };

  return <div className="home-dashboard bg-panel">
    <section data-home-section="status" className="border-b border-line">
      <ReportSectionIntro
        number="01"
        title={`${periodName}状态`}
        detail={`先判断${periodScope}结果，再查看趋势是否稳定。`}
        meta={loading ? "更新中" : generatedLabel}
        action={<button type="button" className="grid h-9 w-9 shrink-0 place-items-center rounded-md border border-line text-stone hover:bg-tag hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand" onClick={() => onPrivacyChange("showHomeSummaryAmounts", !showAmounts)} title={showAmounts ? "隐藏首页金额" : "显示首页金额"} aria-label={showAmounts ? "隐藏首页金额" : "显示首页金额"}>{showAmounts ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}</button>}
      />

      <div className="grid gap-px bg-line sm:grid-cols-2 xl:grid-cols-5">
        <ReportMetric label={`${periodScope}净收入`} value={mask(formatValuation(current.net / 100, currency))} detail={comparisonDetail(canShowSensitive, reportReady, current.net, previous.net)} alert={canShowSensitive && current.net < 0} primary />
        <ReportMetric label={`${periodScope}支出`} value={mask(formatValuation(current.expense / 100, currency))} detail={comparisonDetail(canShowSensitive, reportReady, current.expense, previous.expense)} />
        <ReportMetric label={`${periodScope}收入`} value={mask(formatValuation(current.income / 100, currency))} detail={comparisonDetail(canShowSensitive, reportReady, current.income, previous.income)} />
        <ReportMetric label="交易笔数" value={canShowSensitive ? String(current.transactionCount) : "••••••"} detail={!canShowSensitive ? "同比 ••••••" : reportReady ? comparisonCountCopy(current.transactionCount, previous.transactionCount) : "等待同比数据"} />
        <ReportMetric label={`${periodScope}预算`} value={!report ? "等待数据" : report.budget.configured ? mask(formatValuation(report.budget.amount / 100, report.budget.currency)) : "无预算"} detail={!report ? "正在读取预算配置" : report.budget.configured ? "当前范围预算总额" : "暂无预算配置"} />
      </div>

      <div className="grid border-t border-line xl:grid-cols-2">
        <ReportPanel title={`${periodScope}收支趋势`} detail="收入、支出与净收入共用一条时间轴。" className="border-b border-line xl:border-b-0 xl:border-r">
          <ChartViewport {...chartState} hasData={Boolean(report?.current.cashflowSeries.length)} pointCount={report?.current.cashflowSeries.length ?? 0}><CashflowTrendChart rows={report?.current.cashflowSeries ?? []} currency={currency} /></ChartViewport>
        </ReportPanel>
        <ReportPanel title="累积收支趋势" detail={`观察${periodScope}现金流如何沉淀为净收入。`}>
          <ChartViewport {...chartState} hasData={Boolean(report?.current.cashflowSeries.length)} pointCount={report?.current.cashflowSeries.length ?? 0}><CashflowTrendChart rows={report?.current.cashflowSeries ?? []} currency={currency} cumulative /></ChartViewport>
        </ReportPanel>
      </div>

      <div className="border-t border-line">
        <ReportSubheading title={`${periodScope}收支同比`} detail={`对照 ${previousLabel} 年同一日期范围。`} action={<MetricSwitch value={comparisonMetric} onChange={setComparisonMetric} />} />
        <div className="grid gap-px border-b border-line bg-line md:grid-cols-3">
          <ComparisonMetricCell label="收入同比" current={current.income} previous={previous.income} currency={currency} show={canShowSensitive} ready={reportReady} />
          <ComparisonMetricCell label="支出同比" current={current.expense} previous={previous.expense} currency={currency} show={canShowSensitive} ready={reportReady} />
          <ComparisonMetricCell label="净收入同比" current={current.net} previous={previous.net} currency={currency} show={canShowSensitive} ready={reportReady} alert={current.net < 0} />
        </div>
        <div className="px-4 py-5 md:px-6 xl:px-8">
          <ChartViewport {...chartState} hasData={Boolean(report?.current.cashflowSeries.length)} pointCount={report?.current.cashflowSeries.length ?? 0} tall={false}><PeriodComparisonChart current={report?.current.cashflowSeries ?? []} previous={report?.previous.cashflowSeries ?? []} metric={comparisonMetric} currency={currency} currentLabel={currentLabel} previousLabel={previousLabel} /></ChartViewport>
        </div>
      </div>
    </section>

    <section data-home-section="spending" className="border-b border-line">
      <ReportSectionIntro number="02" title="支出驱动" detail="从分类、同比与发生日期定位支出变化来源。" />
      <div className="grid border-t border-line xl:grid-cols-2">
        <ReportPanel title="支出分类分布" detail="按支出占比展示主要分类集中度。" className="border-b border-line xl:border-b-0 xl:border-r">
          <ChartViewport {...chartState} hasData={categories.length > 0} pointCount={categories.length}><CategoryDistributionChart series={categories} currency={currency} /></ChartViewport>
          <div className="grid gap-px border-t border-line bg-line sm:grid-cols-2">
            {categories.slice(0, 6).map((row, index) => <div key={row.account} className="flex min-w-0 items-center gap-2 bg-panel px-4 py-2.5"><span className="h-2 w-2 shrink-0" style={{ background: categoryLegendColor(index) }} /><span className="min-w-0 flex-1 truncate text-xs text-stone">{formatAccountOptionLabel(row.account, row.label, row.alias)}</span><span className="shrink-0 whitespace-nowrap text-xs font-medium tabular-nums text-ink">{mask(formatValuation(row.total / 100, currency))}</span></div>)}
          </div>
        </ReportPanel>
        <ReportPanel title="支出分类排行" detail="按当前范围累计金额排序，点击直接核查流水。">
          <div className="divide-y divide-line">
            {categories.length ? categories.slice(0, 8).map((row, index) => <button key={row.account} type="button" className="grid w-full min-w-0 grid-cols-[2rem_minmax(0,1fr)_auto] items-center gap-3 px-4 py-3 text-left hover:bg-tag focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand md:px-6" onClick={() => onSelectCategory?.(row.account, "prefix")}>
              <span className="text-xs tabular-nums text-stone">{String(index + 1).padStart(2, "0")}</span>
              <span className="min-w-0"><strong className="block truncate text-sm font-medium text-ink">{formatAccountOptionLabel(row.account, row.label, row.alias)}</strong><span className="mt-2 block h-1 bg-line"><span className="block h-full bg-brand" style={{ width: `${Math.max(3, categories[0]?.total ? row.total / categories[0].total * 100 : 0)}%` }} /></span></span>
              <span className="min-w-0 text-right"><strong className="block whitespace-nowrap text-[clamp(0.7rem,1.2vw,0.875rem)] tabular-nums text-ink" title={mask(formatValuation(row.total / 100, currency))}>{mask(formatValuation(row.total / 100, currency))}</strong><span className="mt-1 block text-[11px] text-stone">{canShowSensitive ? percentageOf(row.total, current.expense) : "••••••"}</span></span>
            </button>) : <CompactEmpty text="当前范围暂无支出分类。" />}
          </div>
        </ReportPanel>
      </div>

      <div className="border-t border-line">
        <ReportSubheading title="支出分类同比趋势" detail="选择一个分类，对照当前与上一年度的同周期变化。" action={categories.length ? <select className="h-9 max-w-56 rounded-md border border-line bg-panel px-3 text-sm text-ink outline-none focus:border-brand focus:ring-2 focus:ring-[var(--focus-ring)]" value={selectedCategory?.account ?? ""} onChange={(event) => setCategoryAccount(event.target.value)}>{categories.map((row) => <option key={row.account} value={row.account}>{formatAccountOptionLabel(row.account, row.label, row.alias)}</option>)}</select> : null} />
        <div className="grid gap-px border-b border-line bg-line md:grid-cols-3">
          <ComparisonMetricCell label="分类支出同比" current={selectedCategory?.total ?? 0} previous={previousCategory?.total ?? 0} currency={currency} show={canShowSensitive} ready={reportReady} />
          <PlainMetricCell label="交易聚集度" value={canShowSensitive && selectedCategory ? percentageOf(selectedCategory.total, current.expense) : "••••••"} detail="占本期总支出" />
          <PlainMetricCell label="月均支出" value={canShowSensitive ? formatValuation((selectedCategory?.total ?? 0) / Math.max(1, report?.current.cashflowSeries.length ?? 1) / 100, currency) : "••••••"} detail={`${report?.current.cashflowSeries.length ?? 0} 个统计桶`} />
        </div>
        <div className="px-4 py-5 md:px-6 xl:px-8"><ChartViewport {...chartState} hasData={Boolean(selectedCategory?.values.length)} pointCount={selectedCategory?.values.length ?? 0} tall={false}><CategoryComparisonChart current={categories} previous={report?.previous.categorySeries ?? []} account={selectedCategory?.account ?? ""} currency={currency} currentLabel={currentLabel} previousLabel={previousLabel} /></ChartViewport></div>
      </div>

      <div className="border-t border-line">
        <ReportSubheading title="支出热力图" detail="按月份和日期查看消费出现的位置与强度。" />
        <div className="px-4 py-5 md:px-6 xl:px-8"><ChartViewport {...chartState} hasData={Boolean(report?.dailyExpenseSeries.length)} pointCount={report?.dailyExpenseSeries.length ?? 0} tall={false}><ExpenseHeatmap rows={report?.dailyExpenseSeries ?? []} start={report?.start ?? timeRange.start} end={report?.end ?? timeRange.end} currency={currency} /></ChartViewport></div>
      </div>
    </section>

    <section data-home-section="funds" className="border-b border-line">
      <ReportSectionIntro number="03" title="管控与资金" detail="检查主要付款账户，以及资金余额在当前周期的实际变化。" />
      <div className="grid border-t border-line xl:grid-cols-2">
        <ReportPanel title="主要资金出口" detail="按支出关联的付款账户汇总。" className="border-b border-line xl:border-b-0 xl:border-r">
          <ChartViewport {...chartState} hasData={Boolean(report?.topPaymentAccounts.length)} pointCount={report?.topPaymentAccounts.length ?? 0}><PaymentAccountChart rows={report?.topPaymentAccounts ?? []} currency={currency} /></ChartViewport>
        </ReportPanel>
        <ReportPanel title="账户余额走势" detail={selectedAccount ? formatAccountOptionLabel(selectedAccount.account, selectedAccount.label, selectedAccount.alias) : "选择账户查看余额变化"} action={accounts.length ? <select className="h-9 max-w-48 rounded-md border border-line bg-panel px-3 text-sm text-ink outline-none focus:border-brand focus:ring-2 focus:ring-[var(--focus-ring)]" value={selectedAccount?.account ?? ""} onChange={(event) => setAccount(event.target.value)}>{accounts.map((row) => <option key={row.account} value={row.account}>{formatAccountOptionLabel(row.account, row.label, row.alias)}</option>)}</select> : null}>
          <ChartViewport {...chartState} hasData={Boolean(selectedAccount?.values.length)} pointCount={selectedAccount?.values.length ?? 0}><AccountBalanceTrendChart series={accounts} account={selectedAccount?.account ?? ""} currency={currency} /></ChartViewport>
        </ReportPanel>
      </div>
    </section>
  </div>;
}

function ReportSectionIntro({ number, title, detail, meta, action }: { number: string; title: string; detail: string; meta?: string; action?: ReactNode }) {
  return <div className="flex min-h-28 items-start justify-between gap-5 px-4 py-6 md:px-6 xl:px-8">
    <div className="min-w-0"><div className="text-[11px] font-semibold tabular-nums text-stone">{number}</div><h2 className="mt-2 text-lg font-semibold tracking-[-0.018em] text-ink">{title}</h2><p className="mt-1 text-sm leading-5 text-stone">{detail}</p></div>
    <div className="flex shrink-0 items-center gap-3">{meta && <span className="hidden text-xs tabular-nums text-stone sm:block">{meta}</span>}{action}</div>
  </div>;
}

function ReportMetric({ label, value, detail, alert = false, primary = false }: { label: string; value: string; detail: string; alert?: boolean; primary?: boolean }) {
  return <div className={`min-w-0 bg-panel px-4 py-4 md:px-5 xl:px-6 ${primary ? "sm:col-span-2 xl:col-span-1" : ""}`}><div className="text-[11px] font-semibold text-stone">{label}</div><div data-home-position-value="true" className={`mt-2 whitespace-nowrap text-[clamp(1.15rem,2.15vw,1.75rem)] font-semibold tracking-[-0.03em] tabular-nums ${alert ? "amount-danger" : "text-ink"}`} title={value}>{value}</div><div className="mt-3 text-xs text-stone">{detail}</div></div>;
}

function ReportPanel({ title, detail, action, className = "", children }: { title: string; detail: string; action?: ReactNode; className?: string; children: ReactNode }) {
  return <section className={`min-w-0 bg-panel ${className}`}><div className="flex min-h-[4.5rem] items-start justify-between gap-4 border-b border-line px-4 py-3.5 md:px-6 xl:px-8"><div className="min-w-0"><h3 className="text-base font-semibold tracking-[-0.015em] text-ink">{title}</h3><p className="mt-1.5 text-xs leading-5 text-stone">{detail}</p></div>{action}</div>{children}</section>;
}

function ReportSubheading({ title, detail, action }: { title: string; detail: string; action?: ReactNode }) {
  return <div className="flex flex-col gap-3 px-4 py-4 sm:flex-row sm:items-end sm:justify-between md:px-6 xl:px-8"><div><h3 className="text-base font-semibold tracking-[-0.015em] text-ink">{title}</h3><p className="mt-1 text-xs text-stone">{detail}</p></div>{action}</div>;
}

function ChartViewport({ show, loading, error, hasReport, hasData, pointCount = 0, onReload, tall = true, children }: { show: boolean; loading: boolean; error: string; hasReport: boolean; hasData: boolean; pointCount?: number; onReload?: () => void; tall?: boolean; children: ReactNode }) {
  const height = !hasData ? "min-h-40" : pointCount <= 1 ? "h-[11rem] md:h-[13rem]" : pointCount <= 4 ? "h-[14rem] md:h-[16rem]" : tall ? "h-[16rem] md:h-[18rem]" : "h-[14rem] md:h-[16rem]";
  if (!show) return <ChartStatus className={height} text="解锁并显示金额后查看完整财务简报" />;
  if (error && !hasReport) return <ChartStatus className={height} text={error} action={onReload ? <button type="button" className="inline-flex h-9 items-center gap-2 rounded-md border border-line px-3 text-xs font-medium text-ink hover:bg-tag" onClick={onReload}><RefreshCw className="h-3.5 w-3.5" />重试</button> : null} />;
  if (loading && !hasReport) return <ChartStatus className={height} text="正在生成财务简报…" />;
  return <div className={height}>{children}</div>;
}

function ChartStatus({ className, text, action }: { className: string; text: string; action?: ReactNode }) {
  return <div className={`grid place-items-center px-4 text-center ${className}`}><div><div className="text-sm text-stone">{text}</div>{action && <div className="mt-3">{action}</div>}</div></div>;
}

function MetricSwitch({ value, onChange }: { value: ComparisonMetric; onChange: (value: ComparisonMetric) => void }) {
  const options: { value: ComparisonMetric; label: string }[] = [{ value: "income", label: "收入" }, { value: "expense", label: "支出" }, { value: "net", label: "净收入" }];
  return <div className="inline-flex rounded-md border border-line bg-paper p-0.5">{options.map((option) => <button key={option.value} type="button" className={`h-8 rounded-[4px] px-3 text-xs font-medium ${value === option.value ? "bg-panel text-ink" : "text-stone hover:text-ink"}`} onClick={() => onChange(option.value)} aria-pressed={value === option.value}>{option.label}</button>)}</div>;
}

function ComparisonMetricCell({ label, current, previous, currency, show, ready, alert = false }: { label: string; current: number; previous: number; currency: string; show: boolean; ready: boolean; alert?: boolean }) {
  return <div className="min-w-0 bg-panel px-4 py-3.5 md:px-6"><div className="flex items-center justify-between gap-3"><span className="text-[11px] font-semibold text-stone">{label}</span><span className="h-2 w-2 rounded-full bg-stone" /></div><div className={`mt-1 whitespace-nowrap text-[clamp(1rem,2vw,1.25rem)] font-semibold tabular-nums ${show && alert ? "amount-danger" : "text-ink"}`}>{show ? formatValuation(current / 100, currency) : "••••••"}</div><div className="mt-2 grid gap-1 text-xs text-stone sm:grid-cols-[1fr_auto]"><span>{show ? ready ? comparisonCopy(current, previous) : "等待数据" : "同比 ••••••"}</span><span className="whitespace-nowrap">{show && ready ? previousLabelValue(previous, currency) : "••••••"}</span></div></div>;
}

function PlainMetricCell({ label, value, detail }: { label: string; value: string; detail: string }) {
  return <div className="min-w-0 bg-panel px-4 py-3.5 md:px-6"><div className="text-[11px] font-semibold text-stone">{label}</div><div className="mt-1 whitespace-nowrap text-[clamp(1rem,2vw,1.25rem)] font-semibold tabular-nums text-ink">{value}</div><div className="mt-2 text-xs text-stone">{detail}</div></div>;
}

function CompactEmpty({ text }: { text: string }) {
  return <div className="grid min-h-40 place-items-center px-4 text-sm text-stone">{text}</div>;
}

const emptyKPIs: HomeReportKPI = { income: 0, expense: 0, net: 0, transactionCount: 0, savingsRate: null };

function fallbackKPIs(summary: Summary | null): HomeReportKPI {
  return { income: summary?.income ?? 0, expense: summary?.expense ?? 0, net: summary?.net ?? 0, transactionCount: 0, savingsRate: summary?.income ? (summary.net / summary.income) : null };
}

function fallbackCategorySeries(rows: ExpenseCategoryAnalytics[]): DashboardCategorySeries[] {
  return rows.filter((row) => row.account !== "Expenses:Unknown").slice(0, 8).map((row) => ({ account: row.account, alias: row.alias, label: row.label, total: row.amount, values: [] }));
}

function homePeriodName(range: TimeRange) {
  if (range.preset === "year") return "本年";
  if (range.preset === "quarter") return "本季";
  if (range.preset === "month") return "本月";
  if (range.preset === "week") return "本周";
  return "本期";
}

function homePeriodScope(range: TimeRange) {
  if (range.preset === "year") return "年度";
  if (range.preset === "quarter") return "季度";
  if (range.preset === "month") return "月度";
  if (range.preset === "week") return "周度";
  return "本期";
}

function comparisonCopy(current: number, previous: number) {
  if (previous === 0) return current === 0 ? "同比 --" : "同比 新增";
  const delta = (current - previous) / Math.abs(previous);
  return `同比 ${delta > 0 ? "+" : ""}${(delta * 100).toFixed(0)}%`;
}

function comparisonDetail(show: boolean, ready: boolean, current: number, previous: number) {
  if (!show) return "同比 ••••••";
  return ready ? comparisonCopy(current, previous) : "等待同比数据";
}

function comparisonCountCopy(current: number, previous: number) {
  if (previous === 0) return current === 0 ? "同比 --" : "同比 新增";
  return `同比 ${current - previous > 0 ? "+" : ""}${current - previous} 笔`;
}

function previousLabelValue(value: number, currency: string) {
  return `上期 ${formatValuation(value / 100, currency)}`;
}

function percentageOf(value: number, total: number) {
  if (total <= 0) return "0.0%";
  return `${(value / total * 100).toFixed(1)}%`;
}

function categoryLegendColor(index: number) {
  return ["oklch(var(--color-brand) / 1)", "oklch(var(--color-brand) / .78)", "oklch(var(--color-brand) / .58)", "oklch(var(--color-brand) / .40)", "oklch(var(--color-brand) / .25)", "oklch(var(--color-brand) / .14)"][index % 6];
}
