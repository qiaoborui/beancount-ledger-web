import { Eye, EyeOff } from "lucide-react";
import { lazy, Suspense, useEffect, useRef, useState } from "react";
import { formatValuation } from "@/lib/money";
import { formatAccountOptionLabel } from "./accountDisplay";
import type { ExpenseCategoryAnalytics, PrivacySettings, Summary } from "./types";

const LazyHomeDailyTrendChart = lazy(() => import("./HomeDailyTrendChart").then((mod) => ({ default: mod.HomeDailyTrendChart })));

type HomePageProps = {
  summary: Summary | null;
  valuationCurrency: string;
  privacySettings: PrivacySettings;
  sensitiveUnlocked: boolean;
  expenseAnalytics: ExpenseCategoryAnalytics[];
  onPrivacyChange: <K extends keyof PrivacySettings>(key: K, value: PrivacySettings[K]) => void;
  onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void;
};

export function HomePage({ summary, valuationCurrency, privacySettings, sensitiveUnlocked, expenseAnalytics, onPrivacyChange, onSelectCategory }: HomePageProps) {
  const showAmounts = privacySettings.showHomeSummaryAmounts;
  const displayCurrency = summary?.currency ?? valuationCurrency;
  const canShowSensitive = sensitiveUnlocked && showAmounts;
  const mask = (value: string, sensitive = true) => sensitive ? canShowSensitive ? value : "••••••" : showAmounts ? value : "••••••";
  const dayRows = Object.entries(summary?.days ?? {}).sort(([a], [b]) => a.localeCompare(b));
  const visibleExpenseCategories = expenseAnalytics.filter((row) => row.account !== "Expenses:Unknown");
  const topCategories = visibleExpenseCategories.slice(0, 6);
  const income = summary?.income ?? 0;
  const expense = summary?.expense ?? 0;
  const net = summary?.net ?? 0;
  const expenseRatio = income > 0 ? expense / income : null;
  const savingsRate = income > 0 ? net / income : null;
  const expenseDays = dayRows.filter(([, value]) => value.expense > 0).length;
  const averageExpense = expenseDays ? expense / expenseDays : 0;
  const latestDate = dayRows.at(-1)?.[0] ?? "暂无记录";
  const lastSevenExpense = sumExpense(dayRows.slice(-7));
  const previousSevenExpense = sumExpense(dayRows.slice(-14, -7));
  const weeklyExpenseDelta = previousSevenExpense > 0 ? (lastSevenExpense - previousSevenExpense) / previousSevenExpense : null;

  return <div className="home-dashboard home-console">
    <section className="border-b border-line bg-panel">
      <div className="flex min-h-16 items-center justify-between gap-5 border-b border-line px-4 py-3 md:px-6 xl:px-8">
        <div className="min-w-0">
          <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1">
            <h2 className="text-base font-semibold tracking-[-0.015em] text-ink">本期头寸</h2>
            <span className="text-xs tabular-nums text-stone">账本截止 {latestDate}</span>
          </div>
        </div>
        <button className="grid h-9 w-9 shrink-0 place-items-center rounded-md border border-line text-stone hover:bg-tag hover:text-ink" onClick={() => onPrivacyChange("showHomeSummaryAmounts", !privacySettings.showHomeSummaryAmounts)} title={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"} aria-label={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"}>
          {privacySettings.showHomeSummaryAmounts ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
        </button>
      </div>

      <div className="grid grid-cols-2 md:grid-cols-5">
        <PositionMetric label="本期结余" value={mask(formatValuation(net / 100, displayCurrency))} detail={savingsRate == null ? "暂无储蓄率" : `储蓄率 ${formatPercent(savingsRate)}`} alert={net < 0} primary />
        <PositionMetric label="收入" value={mask(formatValuation(income / 100, displayCurrency))} detail={`${dayRows.length} 个记账日`} />
        <PositionMetric label="支出" value={mask(formatValuation(expense / 100, displayCurrency), false)} detail={expenseRatio == null ? "暂无收入对照" : `收入占用 ${formatPercent(expenseRatio)}`} alert={expenseRatio != null && expenseRatio > 1} />
        <PositionMetric label="消费日均" value={mask(formatValuation(averageExpense / 100, displayCurrency), false)} detail={`${expenseDays} 个消费日`} />
        <PositionMetric label="近 7 日支出" value={mask(formatValuation(lastSevenExpense / 100, displayCurrency), false)} detail={weeklyExpenseDelta == null ? "暂无前期对照" : `环比 ${formatSignedPercent(weeklyExpenseDelta)}`} alert={weeklyExpenseDelta != null && weeklyExpenseDelta > 0.3} />
      </div>
    </section>

    <section className="grid border-b border-line xl:grid-cols-[minmax(0,8fr)_minmax(21rem,4fr)] xl:items-start">
      <div className="min-w-0 border-b border-line xl:border-b-0 xl:border-r">
        <WorkbenchHeading title="日收支趋势" detail="收入、支出与净收入以同一坐标展示。" meta={`${dayRows.length} 天`} />
        <div className="h-[22rem] min-w-0 px-4 pb-6 pt-3 md:h-[25rem] md:px-6 xl:px-8">
          <DailyTrend rows={dayRows} showAmounts={canShowSensitive} valuationCurrency={displayCurrency} />
        </div>
      </div>

      <div className="min-w-0 border-b border-line xl:border-b-0 xl:border-r">
        <WorkbenchHeading title="支出结构" detail="最大分类与其他高频入口的相对占比。" meta={`${topCategories.length} 类`} />
        <ExpenseStructureChart rows={topCategories.slice(0, 5)} showAmounts={showAmounts} valuationCurrency={displayCurrency} onSelectCategory={onSelectCategory} />
        <div className="divide-y divide-line">
          {topCategories.length ? topCategories.map((row, index) => {
            const content = <>
              <span className="w-7 shrink-0 text-xs tabular-nums text-stone">{String(index + 1).padStart(2, "0")}</span>
              <span className="min-w-0 flex-1">
                <span className="block truncate text-sm font-medium text-ink">{formatAccountOptionLabel(row.account, row.label, row.alias)}</span>
                <span className="mt-2 block h-1.5 overflow-hidden bg-line"><span className="block h-full bg-ink" style={{ width: `${Math.max(3, Math.min(100, (row.share ?? 0) * 100))}%` }} /></span>
              </span>
              <span className="shrink-0 text-right">
                <span className="block text-sm font-semibold tabular-nums text-ink">{showAmounts ? formatValuation(row.amount / 100, displayCurrency) : "••••••"}</span>
                <span className="mt-1 block text-xs tabular-nums text-stone">{row.txCount} 笔 · {formatPercent(row.share)}</span>
              </span>
            </>;
            return onSelectCategory ? <button key={row.account} type="button" className="flex w-full items-center gap-3 px-4 py-4 text-left hover:bg-tag focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand md:px-6 xl:px-8" onClick={() => onSelectCategory(row.account, "prefix")}>{content}</button> : <div key={row.account} className="flex items-center gap-3 px-4 py-4 md:px-6 xl:px-8">{content}</div>;
          }) : <EmptyRail text="本期没有可分析的支出分类。" />}
        </div>
      </div>
    </section>
  </div>;
}

function PositionMetric({ label, value, detail, alert = false, primary = false }: { label: string; value: string; detail: string; alert?: boolean; primary?: boolean }) {
  return <div className={`min-w-0 border-b border-r border-line px-4 py-5 last:border-r-0 md:border-b-0 md:px-5 xl:px-8 ${primary ? "col-span-2 md:col-span-1" : ""}`}>
    <div className="text-xs font-medium text-stone">{label}</div>
    <div className={`mt-2 truncate font-semibold tracking-[-0.025em] tabular-nums ${primary ? "text-[2rem] leading-none xl:text-[2.25rem]" : "text-[1.55rem] leading-tight xl:text-[1.75rem]"} ${alert ? "amount-danger" : "text-ink"}`}>{value}</div>
    <div className="mt-2 truncate text-xs text-stone">{detail}</div>
  </div>;
}

function WorkbenchHeading({ title, detail, meta }: { title: string; detail: string; meta: string }) {
  return <div className="flex min-h-[5.25rem] items-start justify-between gap-4 border-b border-line px-4 py-4 md:px-6 xl:px-8">
    <div className="min-w-0">
      <h3 className="text-base font-semibold tracking-[-0.015em] text-ink">{title}</h3>
      <p className="mt-1.5 truncate text-xs text-stone">{detail}</p>
    </div>
    <span className="shrink-0 text-xs tabular-nums text-stone">{meta}</span>
  </div>;
}

function ExpenseStructureChart({ rows, showAmounts, valuationCurrency, onSelectCategory }: { rows: ExpenseCategoryAnalytics[]; showAmounts: boolean; valuationCurrency: string; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  const maxAmount = Math.max(...rows.map((row) => Math.abs(row.amount)), 1);
  if (!rows.length) return <EmptyRail text="本期没有可视化的支出结构。" />;
  return <div className="home-structure-chart border-b border-line px-4 py-5 md:px-6 xl:px-8" role="img" aria-label="本期支出结构图">
    <div className="home-structure-grid" aria-hidden="true" />
    <div className="grid gap-3">
      {rows.map((row, index) => {
        const ratio = Math.max(0.04, Math.min(1, Math.abs(row.amount) / maxAmount));
        const label = formatAccountOptionLabel(row.account, row.label, row.alias);
        const content = <>
          <span className="flex items-baseline justify-between gap-3">
            <span className="min-w-0 truncate text-xs font-medium text-ink">{label}</span>
            <span className="shrink-0 text-xs tabular-nums text-stone">{formatPercent(row.share)}</span>
          </span>
          <span className="home-structure-track mt-2">
            <span className="home-structure-bar" style={{ width: `${ratio * 100}%` }} />
          </span>
          <span className="mt-1.5 flex items-center justify-between gap-3 text-[11px] tabular-nums text-stone">
            <span>{String(index + 1).padStart(2, "0")} · {row.txCount} 笔</span>
            <span>{showAmounts ? formatValuation(row.amount / 100, valuationCurrency) : "••••••"}</span>
          </span>
        </>;
        return onSelectCategory ? <button key={row.account} type="button" className="home-structure-row text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand" onClick={() => onSelectCategory(row.account, "prefix")}>{content}</button> : <div key={row.account} className="home-structure-row">{content}</div>;
      })}
    </div>
  </div>;
}

function DailyTrend({ rows, showAmounts, valuationCurrency }: { rows: [string, { income: number; expense: number }][]; showAmounts: boolean; valuationCurrency: string }) {
  const ready = useDeferredChartReady(showAmounts && rows.length > 0);
  if (!showAmounts) return <div className="grid h-full place-items-center text-sm text-stone">金额已隐藏</div>;
  if (!rows.length) return <div className="grid h-full place-items-center text-sm text-stone">当前周期暂无日收支数据</div>;
  if (!ready) return <div className="grid h-full place-items-center text-sm text-stone">正在准备趋势图…</div>;
  return <Suspense fallback={<div className="grid h-full place-items-center text-sm text-stone">正在准备趋势图…</div>}><LazyHomeDailyTrendChart rows={rows} valuationCurrency={valuationCurrency} /></Suspense>;
}

function EmptyRail({ text }: { text: string }) {
  return <div className="grid min-h-40 place-items-center px-4 text-center text-xs text-stone">{text}</div>;
}

function useDeferredChartReady(enabled: boolean) {
  const [ready, setReady] = useState(false);
  const timeoutRef = useRef<number | null>(null);
  useEffect(() => {
    if (!enabled) {
      setReady(false);
      return;
    }
    const markReady = () => setReady(true);
    if (window.requestIdleCallback) {
      const idleId = window.requestIdleCallback(markReady, { timeout: 900 });
      return () => window.cancelIdleCallback?.(idleId);
    }
    timeoutRef.current = window.setTimeout(markReady, 80);
    return () => {
      if (timeoutRef.current != null) window.clearTimeout(timeoutRef.current);
    };
  }, [enabled]);
  return ready;
}

function sumExpense(rows: [string, { income: number; expense: number }][]) {
  return rows.reduce((sum, [, value]) => sum + value.expense, 0);
}

function formatPercent(value: number | null) {
  if (value == null || !Number.isFinite(value)) return "暂无";
  return `${(value * 100).toFixed(value < 0.1 ? 1 : 0)}%`;
}

function formatSignedPercent(value: number) {
  const sign = value > 0 ? "+" : "";
  return `${sign}${(value * 100).toFixed(0)}%`;
}
