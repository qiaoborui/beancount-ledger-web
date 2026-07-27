import { AlertTriangle, ArrowDownRight, ArrowUpRight, Check, Eye, EyeOff } from "lucide-react";
import { lazy, Suspense, useEffect, useRef, useState } from "react";
import { formatValuation } from "@/lib/money";
import { formatAccountOptionLabel } from "./accountDisplay";
import type { AccountStatus, CreditCardAnalytics, ExpenseCategoryAnalytics, PrivacySettings, Summary } from "./types";

const LazyHomeDailyTrendChart = lazy(() => import("./HomeDailyTrendChart").then((mod) => ({ default: mod.HomeDailyTrendChart })));

type HomePageProps = {
  summary: Summary | null;
  valuationCurrency: string;
  privacySettings: PrivacySettings;
  sensitiveUnlocked: boolean;
  creditCards: CreditCardAnalytics[];
  expenseAnalytics: ExpenseCategoryAnalytics[];
  accountStatuses: AccountStatus[];
  onPrivacyChange: <K extends keyof PrivacySettings>(key: K, value: PrivacySettings[K]) => void;
  onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void;
};

export function HomePage({ summary, valuationCurrency, privacySettings, sensitiveUnlocked, creditCards, expenseAnalytics, accountStatuses, onPrivacyChange, onSelectCategory }: HomePageProps) {
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
  const attentionAccounts = accountStatuses.filter((row) => row.status === "red" || row.status === "yellow");
  const openCreditCards = creditCards.filter((row) => row.outstanding > 0);

  return <div className="home-dashboard home-console">
    <section className="border-b border-line bg-panel">
      <div className="flex min-h-12 items-center justify-between gap-4 border-b border-line px-3 py-2 md:px-4 xl:px-5">
        <div className="min-w-0">
          <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <h2 className="text-sm font-semibold text-ink">本期头寸</h2>
            <span className="text-[11px] tabular-nums text-stone">账本截止 {latestDate}</span>
          </div>
        </div>
        <button className="grid h-7 w-7 shrink-0 place-items-center rounded-md text-stone hover:bg-tag hover:text-ink" onClick={() => onPrivacyChange("showHomeSummaryAmounts", !privacySettings.showHomeSummaryAmounts)} title={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"} aria-label={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"}>
          {privacySettings.showHomeSummaryAmounts ? <EyeOff className="h-3.5 w-3.5" /> : <Eye className="h-3.5 w-3.5" />}
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

    <section className="grid border-b border-line xl:grid-cols-[minmax(0,6fr)_minmax(17rem,3fr)_minmax(17rem,3fr)] xl:items-start">
      <div className="min-w-0 border-b border-line xl:border-b-0 xl:border-r">
        <WorkbenchHeading title="日收支节奏" detail="柱形为支出，折线为收入；点击下方流水继续核对。" meta={`${dayRows.length} 天`} />
        <div className="h-[18rem] min-w-0 px-2 pb-3 pt-1 md:h-[20rem] md:px-3">
          <DailyTrend rows={dayRows} showAmounts={canShowSensitive} valuationCurrency={displayCurrency} />
        </div>
      </div>

      <div className="min-w-0 border-b border-line xl:border-b-0 xl:border-r">
        <WorkbenchHeading title="支出分类账" detail="按本期支出金额排序，优先检查高集中分类。" meta={`${topCategories.length} 类`} />
        <div className="divide-y divide-line">
          {topCategories.length ? topCategories.map((row, index) => {
            const content = <>
              <span className="w-6 shrink-0 text-[11px] tabular-nums text-stone">{String(index + 1).padStart(2, "0")}</span>
              <span className="min-w-0 flex-1">
                <span className="block truncate text-xs font-medium text-ink">{formatAccountOptionLabel(row.account, row.label, row.alias)}</span>
                <span className="mt-1 block h-1 overflow-hidden bg-line"><span className="block h-full bg-ink" style={{ width: `${Math.max(3, Math.min(100, (row.share ?? 0) * 100))}%` }} /></span>
              </span>
              <span className="shrink-0 text-right">
                <span className="block text-xs font-semibold tabular-nums text-ink">{showAmounts ? formatValuation(row.amount / 100, displayCurrency) : "••••••"}</span>
                <span className="mt-0.5 block text-[10px] tabular-nums text-stone">{row.txCount} 笔 · {formatPercent(row.share)}</span>
              </span>
            </>;
            return onSelectCategory ? <button key={row.account} type="button" className="flex w-full items-center gap-2.5 px-3 py-3 text-left hover:bg-tag focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand md:px-4" onClick={() => onSelectCategory(row.account, "prefix")}>{content}</button> : <div key={row.account} className="flex items-center gap-2.5 px-3 py-3 md:px-4">{content}</div>;
          }) : <EmptyRail text="本期没有可分析的支出分类。" />}
        </div>
      </div>

      <InspectionBench
        accountAttention={attentionAccounts.length}
        openCreditCards={openCreditCards.length}
        weeklyExpenseDelta={weeklyExpenseDelta}
        topCategory={topCategories[0]}
        showAmounts={showAmounts}
        valuationCurrency={displayCurrency}
        onSelectCategory={onSelectCategory}
      />
    </section>
  </div>;
}

function PositionMetric({ label, value, detail, alert = false, primary = false }: { label: string; value: string; detail: string; alert?: boolean; primary?: boolean }) {
  return <div className={`min-w-0 border-b border-r border-line px-3 py-3 last:border-r-0 md:border-b-0 md:px-4 ${primary ? "col-span-2 md:col-span-1" : ""}`}>
    <div className="text-[10px] font-medium text-stone">{label}</div>
    <div className={`mt-1 truncate font-semibold tracking-[-0.02em] tabular-nums ${primary ? "text-[1.55rem]" : "text-lg"} ${alert ? "amount-danger" : "text-ink"}`}>{value}</div>
    <div className="mt-0.5 truncate text-[10px] text-stone">{detail}</div>
  </div>;
}

function WorkbenchHeading({ title, detail, meta }: { title: string; detail: string; meta: string }) {
  return <div className="flex min-h-[4.5rem] items-start justify-between gap-3 border-b border-line px-3 py-3 md:px-4">
    <div className="min-w-0">
      <h3 className="text-sm font-semibold text-ink">{title}</h3>
      <p className="mt-1 truncate text-[11px] text-stone">{detail}</p>
    </div>
    <span className="shrink-0 text-[11px] tabular-nums text-stone">{meta}</span>
  </div>;
}

function DailyTrend({ rows, showAmounts, valuationCurrency }: { rows: [string, { income: number; expense: number }][]; showAmounts: boolean; valuationCurrency: string }) {
  const ready = useDeferredChartReady(showAmounts && rows.length > 0);
  if (!showAmounts) return <div className="grid h-full place-items-center text-sm text-stone">金额已隐藏</div>;
  if (!rows.length) return <div className="grid h-full place-items-center text-sm text-stone">当前周期暂无日收支数据</div>;
  if (!ready) return <div className="grid h-full place-items-center text-sm text-stone">正在准备趋势图…</div>;
  return <Suspense fallback={<div className="grid h-full place-items-center text-sm text-stone">正在准备趋势图…</div>}><LazyHomeDailyTrendChart rows={rows} valuationCurrency={valuationCurrency} /></Suspense>;
}

function InspectionBench({ accountAttention, openCreditCards, weeklyExpenseDelta, topCategory, showAmounts, valuationCurrency, onSelectCategory }: { accountAttention: number; openCreditCards: number; weeklyExpenseDelta: number | null; topCategory?: ExpenseCategoryAnalytics; showAmounts: boolean; valuationCurrency: string; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  const checks = [
    { label: "账户状态", value: accountAttention ? `${accountAttention} 个待处理` : "全部正常", danger: accountAttention > 0, detail: accountAttention ? "存在断言或更新异常" : "未发现红黄状态账户" },
    { label: "信用卡敞口", value: openCreditCards ? `${openCreditCards} 张有余额` : "无待还余额", danger: false, detail: openCreditCards ? "进入账户页核对到期日" : "本期无需处理" },
    { label: "支出速度", value: weeklyExpenseDelta == null ? "缺少对照" : formatSignedPercent(weeklyExpenseDelta), danger: weeklyExpenseDelta != null && weeklyExpenseDelta > 0.3, detail: weeklyExpenseDelta == null ? "再积累一个对照周期" : "最近 7 天相对前 7 天" },
  ];
  return <aside className="min-w-0 bg-[oklch(0.985_0_0)]">
    <WorkbenchHeading title="检查台" detail="异常优先，正常状态保持安静。" meta={`${checks.filter((row) => row.danger).length} 异常`} />
    <div className="divide-y divide-line">
      {checks.map((row) => <div key={row.label} className="flex items-start gap-3 px-3 py-3 md:px-4">
        <span className={`mt-0.5 grid h-5 w-5 shrink-0 place-items-center rounded-full ${row.danger ? "bg-destructive/10 text-destructive" : "bg-tag text-olive"}`}>
          {row.danger ? <AlertTriangle className="h-3 w-3" /> : <Check className="h-3 w-3" />}
        </span>
        <span className="min-w-0 flex-1">
          <span className="flex items-baseline justify-between gap-2"><span className="text-[11px] text-stone">{row.label}</span><strong className={`text-xs tabular-nums ${row.danger ? "amount-danger" : "text-ink"}`}>{row.value}</strong></span>
          <span className="mt-1 block text-[10px] text-stone">{row.detail}</span>
        </span>
      </div>)}
      {topCategory && <button type="button" className="flex w-full items-start gap-3 px-3 py-3 text-left hover:bg-tag md:px-4" onClick={onSelectCategory ? () => onSelectCategory(topCategory.account, "prefix") : undefined} disabled={!onSelectCategory}>
        <span className="mt-0.5 grid h-5 w-5 shrink-0 place-items-center rounded-full bg-tag text-olive">{weeklyExpenseDelta != null && weeklyExpenseDelta > 0 ? <ArrowUpRight className="h-3 w-3" /> : <ArrowDownRight className="h-3 w-3" />}</span>
        <span className="min-w-0 flex-1">
          <span className="block text-[11px] text-stone">最大支出入口</span>
          <strong className="mt-0.5 block truncate text-xs text-ink">{formatAccountOptionLabel(topCategory.account, topCategory.label, topCategory.alias)}</strong>
          <span className="mt-1 block text-[10px] text-stone">{showAmounts ? formatValuation(topCategory.amount / 100, valuationCurrency) : "••••••"} · {topCategory.txCount} 笔</span>
        </span>
      </button>}
    </div>
  </aside>;
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
