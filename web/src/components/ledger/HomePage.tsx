import { ArrowUpRight, Eye, EyeOff, RefreshCw } from "lucide-react";
import { useMemo, useState, type ReactNode } from "react";
import { formatValuation } from "@/lib/money";
import type { TimeRange } from "@/lib/timeRange";
import { ClientNavLink } from "./ClientNavLink";
import { formatAccountOptionLabel } from "./accountDisplay";
import { PeriodComparisonChart, type ComparisonMetric } from "./HomeReportCharts";
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
};

export function HomePage({ summary, timeRange, valuationCurrency, ledgerRevision = "", privacySettings, sensitiveUnlocked, expenseAnalytics, onPrivacyChange, onSensitiveLocked }: HomePageProps) {
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
  />;
}

export function HomeReportWorkspace({ report, summary, timeRange, valuationCurrency, privacySettings, sensitiveUnlocked, expenseAnalytics, loading = false, error = "", onReload, onPrivacyChange }: Omit<HomePageProps, "onSensitiveLocked"> & { report: HomeReport | null; loading?: boolean; error?: string; onReload?: () => void }) {
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
  const [comparisonMetric, setComparisonMetric] = useState<ComparisonMetric>("net");
  const topCategory = categories[0];
  const previousTopCategory = report?.previous.categorySeries.find((row) => row.account === topCategory?.account);
  const topPaymentAccount = report?.topPaymentAccounts[0];
  const activeExpenseDays = report?.dailyExpenseSeries.length ?? Object.keys(summary?.days ?? {}).length;
  const generatedLabel = report?.generatedAt ? new Date(report.generatedAt).toLocaleString("zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }) : "等待更新";
  const mask = (value: string) => canShowSensitive ? value : "••••••";
  const chartState = { show: canShowSensitive, loading, error, hasReport: Boolean(report), onReload };

  const categorySignal = topCategory ? {
    headline: formatAccountOptionLabel(topCategory.account, topCategory.label, topCategory.alias),
    value: canShowSensitive ? percentageOf(topCategory.total, current.expense) : "••••••",
    detail: canShowSensitive && reportReady ? comparisonCopy(topCategory.total, previousTopCategory?.total ?? 0) : "分类变化已隐藏",
  } : { headline: "暂无支出分类", value: "--", detail: "当前范围没有可分析的分类" };
  const paymentSignal = topPaymentAccount ? {
    headline: formatAccountOptionLabel(topPaymentAccount.account, topPaymentAccount.label, topPaymentAccount.alias),
    value: mask(formatValuation(topPaymentAccount.amount / 100, currency)),
    detail: canShowSensitive ? `${topPaymentAccount.txCount} 笔 · ${percentageOf(topPaymentAccount.amount, current.expense)} 支出` : "付款集中度已隐藏",
  } : { headline: "暂无付款账户", value: "--", detail: "当前范围没有消费来源数据" };

  return <div className="home-dashboard bg-panel">
    <section data-home-section="position" className="border-b border-line">
      <ReportSectionIntro
        title={`${periodName}结论`}
        detail={`首页只回答${periodScope}结果是否健康，以及接下来应该去哪里核查。`}
        meta={loading ? "更新中" : generatedLabel}
        action={<button type="button" className="grid h-9 w-9 shrink-0 place-items-center rounded-md border border-line text-stone hover:bg-tag hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand" onClick={() => onPrivacyChange("showHomeSummaryAmounts", !showAmounts)} title={showAmounts ? "隐藏首页金额" : "显示首页金额"} aria-label={showAmounts ? "隐藏首页金额" : "显示首页金额"}>{showAmounts ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}</button>}
      />

      <div className="grid gap-px bg-line sm:grid-cols-2 xl:grid-cols-4">
        <ReportMetric label={`${periodScope}净收入`} value={mask(formatValuation(current.net / 100, currency))} detail={comparisonDetail(canShowSensitive, reportReady, current.net, previous.net)} alert={canShowSensitive && current.net < 0} />
        <ReportMetric label={`${periodScope}收入`} value={mask(formatValuation(current.income / 100, currency))} detail={comparisonDetail(canShowSensitive, reportReady, current.income, previous.income)} />
        <ReportMetric label={`${periodScope}支出`} value={mask(formatValuation(current.expense / 100, currency))} detail={comparisonDetail(canShowSensitive, reportReady, current.expense, previous.expense)} />
        <ReportMetric label="交易笔数" value={canShowSensitive ? String(current.transactionCount) : "••••••"} detail={!canShowSensitive ? "同比 ••••••" : reportReady ? comparisonCountCopy(current.transactionCount, previous.transactionCount) : "等待同比数据"} />
      </div>
    </section>

    <section data-home-section="pulse" className="grid border-b border-line xl:grid-cols-[minmax(0,1.55fr)_minmax(19rem,0.8fr)]">
      <div className="min-w-0 border-b border-line xl:border-b-0 xl:border-r">
        <ReportPanel title={`${periodScope}周期轨迹`} detail={`用一张图对照 ${currentLabel} 与 ${previousLabel} 的同周期变化。`} action={<MetricSwitch value={comparisonMetric} onChange={setComparisonMetric} />}>
          <ChartViewport {...chartState} hasData={Boolean(report?.current.cashflowSeries.length)} pointCount={report?.current.cashflowSeries.length ?? 0}>
            <PeriodComparisonChart current={report?.current.cashflowSeries ?? []} previous={report?.previous.cashflowSeries ?? []} metric={comparisonMetric} currency={currency} currentLabel={currentLabel} previousLabel={previousLabel} />
          </ChartViewport>
        </ReportPanel>
      </div>

      <div className="min-w-0">
        <ReportPanel title="待核查事项" detail="从实际流水中提取需要关注的信号，详细解释交给对应工作区。">
          <div className="divide-y divide-line">
            <DecisionSignal label="支出结构" headline={categorySignal.headline} value={categorySignal.value} detail={categorySignal.detail} href="/dashboard" action="查看归因" />
            <DecisionSignal label="付款来源" headline={paymentSignal.headline} value={paymentSignal.value} detail={paymentSignal.detail} href="/transactions" action="核对流水" />
            <DecisionSignal label="记录覆盖" headline={`${canShowSensitive ? activeExpenseDays : "••••••"} 个支出日`} value={canShowSensitive ? `${current.transactionCount} 笔` : "••••••"} detail="用于判断本期数据密度，不在首页展开日历分析" href="/dashboard" action="查看节奏" />
          </div>
        </ReportPanel>
      </div>
    </section>

    <section data-home-section="handoff">
      <ReportSectionIntro title="继续处理" detail="三个工作区各自负责一类问题：首页不再重复承载完整分析。" />
      <div className="grid gap-px border-t border-line bg-line md:grid-cols-3">
        <DestinationRow href="/dashboard" label="收支分析" description="解释支出发生在何时、花给谁、归到哪里。" meta={canShowSensitive && topCategory ? `Top ${formatAccountOptionLabel(topCategory.account, topCategory.label, topCategory.alias)}` : "筛选与归因"} />
        <DestinationRow href="/net-worth" label="资产负债" description="检查资产结构、负债比例与净资产变化。" meta={report ? `${report.accountBalanceSeries.length} 个主要账户` : "账户结构"} />
        <DestinationRow href="/transactions" label="交易账本" description="回到事实记录，核对、搜索或编辑具体流水。" meta={canShowSensitive ? `${current.transactionCount} 笔记录` : "具体流水"} />
      </div>
    </section>
  </div>;
}

function ReportSectionIntro({ title, detail, meta, action }: { title: string; detail: string; meta?: string; action?: ReactNode }) {
  return <div className="flex min-h-24 items-start justify-between gap-5 px-4 py-5 md:px-6 xl:px-8">
    <div className="min-w-0"><h2 className="text-lg font-semibold tracking-[-0.018em] text-ink">{title}</h2><p className="mt-1 text-sm leading-5 text-stone">{detail}</p></div>
    <div className="flex shrink-0 items-center gap-3">{meta && <span className="hidden text-xs tabular-nums text-stone sm:block">{meta}</span>}{action}</div>
  </div>;
}

function ReportMetric({ label, value, detail, alert = false }: { label: string; value: string; detail: string; alert?: boolean }) {
  return <div className="min-w-0 bg-panel px-4 py-4 md:px-5 xl:px-6"><div className="text-[11px] font-semibold text-stone">{label}</div><div data-home-position-value="true" className={`mt-2 max-w-full whitespace-nowrap font-semibold tracking-[-0.03em] tabular-nums ${amountSizeClass(value)} ${alert ? "amount-danger" : "text-ink"}`} title={value}>{value}</div><div className="mt-3 text-xs text-stone">{detail}</div></div>;
}

function ReportPanel({ title, detail, action, children }: { title: string; detail: string; action?: ReactNode; children: ReactNode }) {
  return <section className="min-w-0 bg-panel"><div className="flex min-h-[4.5rem] flex-col gap-3 border-b border-line px-4 py-3.5 sm:flex-row sm:items-start sm:justify-between md:px-6 xl:px-8"><div className="min-w-0"><h3 className="text-base font-semibold tracking-[-0.015em] text-ink">{title}</h3><p className="mt-1.5 text-xs leading-5 text-stone">{detail}</p></div>{action}</div>{children}</section>;
}

function ChartViewport({ show, loading, error, hasReport, hasData, pointCount = 0, onReload, children }: { show: boolean; loading: boolean; error: string; hasReport: boolean; hasData: boolean; pointCount?: number; onReload?: () => void; children: ReactNode }) {
  const height = !hasData ? "min-h-48" : pointCount <= 1 ? "h-[13rem] md:h-[15rem]" : pointCount <= 4 ? "h-[16rem] md:h-[18rem]" : "h-[18rem] md:h-[21rem]";
  if (!show) return <ChartStatus className={height} text="解锁并显示金额后查看周期轨迹" />;
  if (error && !hasReport) return <ChartStatus className={height} text={error} action={onReload ? <button type="button" className="inline-flex h-9 items-center gap-2 rounded-md border border-line px-3 text-xs font-medium text-ink hover:bg-tag" onClick={onReload}><RefreshCw className="h-3.5 w-3.5" />重试</button> : null} />;
  if (loading && !hasReport) return <ChartStatus className={height} text="正在生成财务简报…" />;
  return <div className={height}>{children}</div>;
}

function ChartStatus({ className, text, action }: { className: string; text: string; action?: ReactNode }) {
  return <div className={`grid place-items-center px-4 text-center ${className}`}><div><div className="text-sm text-stone">{text}</div>{action && <div className="mt-3">{action}</div>}</div></div>;
}

function MetricSwitch({ value, onChange }: { value: ComparisonMetric; onChange: (value: ComparisonMetric) => void }) {
  const options: { value: ComparisonMetric; label: string }[] = [{ value: "net", label: "净收入" }, { value: "expense", label: "支出" }, { value: "income", label: "收入" }];
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
