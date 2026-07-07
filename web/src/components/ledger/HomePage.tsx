import { ArrowDownRight, ArrowUpRight, CalendarDays, Eye, EyeOff, PieChart, WalletCards } from "lucide-react";
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

export function HomePage({ summary, valuationCurrency, privacySettings, sensitiveUnlocked, expenseAnalytics, onPrivacyChange, onSelectCategory }: HomePageProps) {
  const showAmounts = privacySettings.showHomeSummaryAmounts;
  const displayCurrency = summary?.currency ?? valuationCurrency;
  const canShowSensitive = sensitiveUnlocked && showAmounts;
  const mask = (value: string, sensitive = true) => sensitive ? canShowSensitive ? value : "••••••" : showAmounts ? value : "••••••";
  const visibleExpenseCategories = expenseAnalytics.filter((row) => row.account !== "Expenses:Unknown");
  const topCategories = visibleExpenseCategories.slice(0, 5);
  const topCategory = topCategories[0];
  const dayRows = Object.entries(summary?.days ?? {}).sort(([a], [b]) => a.localeCompare(b));
  const income = summary?.income ?? 0;
  const expense = summary?.expense ?? 0;
  const net = summary?.net ?? 0;
  const averageExpense = dayRows.length ? expense / dayRows.length : 0;
  const expenseRatio = income > 0 ? expense / income : null;
  const savingsRate = income > 0 ? net / income : null;
  const expenseDays = dayRows.filter(([, value]) => value.expense > 0).length;
  const latestDate = dayRows.at(-1)?.[0] ?? "";
  const lastSevenExpense = sumExpense(dayRows.slice(-7));
  const previousSevenExpense = sumExpense(dayRows.slice(-14, -7));
  const weeklyExpenseDelta = previousSevenExpense > 0 ? (lastSevenExpense - previousSevenExpense) / previousSevenExpense : null;
  const topThreeShare = topCategories.slice(0, 3).reduce((sum, row) => sum + (row.share ?? 0), 0);
  const netTone = net < 0 ? "amount-expense" : "amount-gold";
  const dashboardGridClass = "grid min-w-0 gap-4 xl:grid-cols-[minmax(0,5fr)_minmax(0,7fr)]";

  return <>
    <div className={`${dashboardGridClass} xl:items-stretch`}>
      <section className="card flex min-w-0 flex-col overflow-hidden p-4 md:p-5">
        <div className="flex min-h-24 items-start justify-between gap-4">
          <SectionTitle eyebrow="当前周期" title="本期总览" detail="收入、支出、结余和支出速度集中查看。" />
          <button className="grid h-10 w-10 shrink-0 place-items-center rounded-xl border border-line bg-panel text-brand hover:bg-tag" onClick={() => onPrivacyChange("showHomeSummaryAmounts", !privacySettings.showHomeSummaryAmounts)} title={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"} aria-label={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"}>
            {privacySettings.showHomeSummaryAmounts ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
          </button>
        </div>
        <div className="rounded-xl bg-paper p-4 shadow-[inset_0_0_0_1px_var(--line)]">
          <div className="ledger-label">本期结余</div>
          <div className={`mt-2 break-words font-serif text-3xl font-medium leading-none tracking-[-0.012em] md:text-4xl ${netTone}`}>{mask(formatValuation(net / 100, displayCurrency))}</div>
          <div className="mt-4 grid gap-2 sm:grid-cols-3">
            <FlowMetric label="收入" value={mask(formatValuation(income / 100, displayCurrency))} tone="amount-income" />
            <FlowMetric label="支出" value={mask(formatValuation(expense / 100, displayCurrency), false)} tone="amount-expense" />
            <FlowMetric label="日均支出" value={mask(formatValuation(averageExpense / 100, displayCurrency), false)} tone="amount-gold" />
          </div>
        </div>
        <div className="mt-4 grid gap-3 md:grid-cols-3">
          <SignalCard icon={<WalletCards className="h-4 w-4" />} label="支出占收入" value={expenseRatio == null ? "暂无收入" : formatPercent(expenseRatio)} detail={savingsRate == null ? "还没有可比口径" : `储蓄率 ${formatPercent(savingsRate)}`} tone={expenseRatio != null && expenseRatio > 1 ? "amount-expense" : "amount-income"} />
          <SignalCard icon={<PieChart className="h-4 w-4" />} label="消费集中度" value={topCategories.length ? formatPercent(topThreeShare) : "暂无分类"} detail={topCategories.length ? "前三类支出占比" : "本期暂无支出分类"} tone="amount-gold" />
          <SignalCard icon={<CalendarDays className="h-4 w-4" />} label="记录节奏" value={dayRows.length ? `${expenseDays}/${dayRows.length} 天` : "暂无记录"} detail={latestDate ? `最近更新 ${latestDate.slice(5)}` : "等待本期数据"} tone="text-warm" />
        </div>
      </section>
      <DailyTrendCard rows={dayRows} showAmounts={canShowSensitive} valuationCurrency={displayCurrency} />
    </div>

    <div className={`${dashboardGridClass} mt-4 items-start`}>
      <CategoryFocus rows={topCategories} totalExpense={expense} showAmounts={showAmounts} valuationCurrency={displayCurrency} onSelectCategory={onSelectCategory} />
      <RhythmBrief lastSevenExpense={lastSevenExpense} weeklyExpenseDelta={weeklyExpenseDelta} topCategory={topCategory} dayRows={dayRows} showAmounts={showAmounts} valuationCurrency={displayCurrency} onSelectCategory={onSelectCategory} />
    </div>

  </>;
}

function DailyTrendCard({ rows, showAmounts, valuationCurrency }: { rows: [string, { income: number; expense: number }][]; showAmounts: boolean; valuationCurrency: string }) {
  const label = rows.length ? `${rows[0][0].slice(5)} ~ ${rows.at(-1)?.[0].slice(5)}` : "本期";
  const { ref, ready } = useDeferredChartReady(rows.length > 0 && showAmounts);
  return <section className="card flex h-full min-w-0 flex-col overflow-hidden p-4 md:p-5 xl:min-h-0 max-xl:min-h-[360px]">
    <div className="flex min-h-24 items-start justify-between gap-3">
      <SectionTitle eyebrow="日趋势" title="日收支趋势" detail={
        <span className="flex flex-wrap items-center gap-3">
          <span className="inline-flex items-center gap-1"><span className="h-2 w-2 rounded-sm bg-[rgb(var(--color-expense))]" />支出柱</span>
          <span className="inline-flex items-center gap-1"><span className="h-2 w-2 rounded-full bg-[rgb(var(--color-income))]" />收入线</span>
        </span>
      } />
      <span className="ledger-chip rounded-full px-2.5 py-1 text-xs">
        {label}
      </span>
    </div>
    {rows.length ? showAmounts ? <div ref={ref} className="ledger-chart min-h-[260px] min-w-0 max-w-full flex-1 xl:min-h-0">
      {ready ? <Suspense fallback={<EmptyPanel text="正在准备趋势图…" className="min-h-[260px]" />}>
        <LazyHomeDailyTrendChart rows={rows} valuationCurrency={valuationCurrency} />
      </Suspense> : <EmptyPanel text="趋势图稍后加载" className="min-h-[260px]" />}
    </div> : <EmptyPanel text="金额已隐藏，显示金额后可查看趋势与明细。" className="mt-0 min-h-[260px] flex-1 xl:min-h-0" /> : <EmptyPanel text="暂无日趋势数据" className="mt-0 min-h-[260px] flex-1 xl:min-h-0" />}
  </section>;
}

function SectionTitle({ eyebrow, title, detail }: { eyebrow: string; title: string; detail?: React.ReactNode }) {
  return <div className="min-w-0">
    <div className="ledger-label text-[11px] font-semibold text-stone">{eyebrow}</div>
    <h2 className="mt-1.5 text-wrap-balance text-2xl font-semibold leading-tight tracking-normal text-warm md:text-[1.625rem]">{title}</h2>
    {detail && <div className="mt-2 text-sm leading-6 text-olive">{detail}</div>}
  </div>;
}

function EmptyPanel({ text, className = "" }: { text: string; className?: string }) {
  return <div className={`grid place-items-center rounded-xl bg-paper px-4 py-6 text-center text-sm text-stone shadow-[inset_0_0_0_1px_var(--line)] ${className}`}>{text}</div>;
}

function useDeferredChartReady(enabled: boolean) {
  const ref = useRef<HTMLDivElement | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    if (!enabled) {
      setReady(false);
      return;
    }
    const element = ref.current;
    if (!element || ready) return;

    let idleId: number | null = null;
    let delayId: number | null = null;
    const markReady = () => setReady(true);
    const scheduleReady = () => {
      if (delayId != null || idleId != null) return;
      delayId = window.setTimeout(() => {
        delayId = null;
        if (window.requestIdleCallback) idleId = window.requestIdleCallback(markReady, { timeout: 2400 });
        else markReady();
      }, 900);
    };
    const observer = "IntersectionObserver" in window ? new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) scheduleReady();
    }, { rootMargin: "160px" }) : null;

    observer?.observe(element);
    if (!observer) {
      scheduleReady();
    }

    return () => {
      observer?.disconnect();
      if (delayId != null) window.clearTimeout(delayId);
      if (idleId != null) {
        if (window.cancelIdleCallback) window.cancelIdleCallback(idleId);
        else window.clearTimeout(idleId);
      }
    };
  }, [enabled, ready]);

  return { ref, ready };
}

function FlowMetric({ label, value, tone }: { label: string; value: string; tone: string }) {
  return <div className="min-w-0 rounded-xl bg-panel px-3 py-2 shadow-[inset_0_0_0_1px_var(--line)]">
    <div className="text-[11px] font-semibold text-stone">{label}</div>
    <div className={`mt-1 truncate text-sm font-semibold tabular-nums sm:text-base ${tone}`}>{value}</div>
  </div>;
}

function SignalCard({ icon, label, value, detail, tone }: { icon: React.ReactNode; label: string; value: string; detail: string; tone: string }) {
  return <div className="min-w-0 rounded-2xl border border-line bg-panel p-3">
    <div className="flex items-center gap-2 text-xs font-medium text-stone">{icon}<span>{label}</span></div>
    <div className={`mt-2 truncate text-xl font-semibold tabular-nums ${tone}`}>{value}</div>
    <div className="mt-1 truncate text-xs text-stone">{detail}</div>
  </div>;
}

function CategoryFocus({ rows, totalExpense, showAmounts, valuationCurrency, onSelectCategory }: { rows: ExpenseCategoryAnalytics[]; totalExpense: number; showAmounts: boolean; valuationCurrency: string; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  return <section className="card min-w-0 overflow-hidden p-4 md:p-5">
    <div className="flex min-h-20 items-start justify-between gap-3">
      <SectionTitle eyebrow="支出结构" title="分类分布" />
      <span className="ledger-chip shrink-0 rounded-full px-2.5 py-1 text-xs">{rows.length ? `${rows.length} 类` : "暂无"}</span>
    </div>
    <div className="mt-4 space-y-3">
      {rows.length ? rows.map((row, index) => {
        const share = row.share ?? (totalExpense > 0 ? row.amount / totalExpense : 0);
        const label = formatAccountOptionLabel(row.account, row.label, row.alias);
        const content = <><div className="flex min-w-0 items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="truncate text-sm font-medium text-warm">{label}</div>
            <div className="mt-1 text-xs text-stone">{row.txCount} 笔 · {formatPercent(share)}</div>
          </div>
          <div className="shrink-0 text-right text-sm font-semibold tabular-nums text-warm">{showAmounts ? formatValuation(row.amount / 100, valuationCurrency) : "••••••"}</div>
        </div>
        <div className="mt-2 h-2 overflow-hidden rounded-full bg-line">
          <div className={index === 0 ? "h-full rounded-full bg-[rgb(var(--color-expense))]" : "h-full rounded-full bg-brand"} style={{ width: `${Math.max(4, Math.min(100, share * 100))}%` }} />
        </div></>;
        if (!onSelectCategory) return <div key={row.account} className="rounded-xl bg-paper p-3 shadow-[inset_0_0_0_1px_var(--line)]">{content}</div>;
        return <button key={row.account} type="button" className="w-full rounded-xl bg-paper p-3 text-left shadow-[inset_0_0_0_1px_var(--line)] hover:bg-tag focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2 focus-visible:ring-offset-paper" onClick={() => onSelectCategory(row.account, "prefix")}>{content}</button>;
      }) : <div className="rounded-xl bg-paper p-6 text-center text-sm text-stone shadow-[inset_0_0_0_1px_var(--line)]">本期还没有支出分类。</div>}
    </div>
  </section>;
}

function RhythmBrief({ lastSevenExpense, weeklyExpenseDelta, topCategory, dayRows, showAmounts, valuationCurrency, onSelectCategory }: { lastSevenExpense: number; weeklyExpenseDelta: number | null; topCategory?: ExpenseCategoryAnalytics; dayRows: [string, { income: number; expense: number }][]; showAmounts: boolean; valuationCurrency: string; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  const recentRows = dayRows.slice(-5).reverse();
  const weeklyTone = weeklyExpenseDelta != null && weeklyExpenseDelta > 0 ? "amount-expense" : "amount-income";
  return <section className="card min-w-0 overflow-hidden p-4 md:p-5">
    <div className="min-h-20">
      <SectionTitle eyebrow="近期变化" title="动向摘要" />
    </div>
    <div className="mt-4 grid gap-3">
      <BriefRow
        title="最近 7 天支出"
        value={showAmounts ? formatValuation(lastSevenExpense / 100, valuationCurrency) : "••••••"}
        detail={weeklyExpenseDelta == null ? "暂无上个 7 天对照" : `较前 7 天 ${formatSignedPercent(weeklyExpenseDelta)}`}
        tone={weeklyTone}
        icon={weeklyExpenseDelta != null && weeklyExpenseDelta > 0 ? <ArrowUpRight className="h-4 w-4" /> : <ArrowDownRight className="h-4 w-4" />}
      />
      <BriefRow
        title="最大的消费入口"
        value={topCategory ? formatAccountOptionLabel(topCategory.account, topCategory.label, topCategory.alias) : "暂无分类"}
        detail={topCategory ? `${topCategory.txCount} 笔 · ${formatPercent(topCategory.share ?? null)}` : "本期没有可分析的支出"}
        tone="text-warm"
        onClick={topCategory && onSelectCategory ? () => onSelectCategory(topCategory.account, "prefix") : undefined}
      />
    </div>
    <div className="mt-4 rounded-2xl bg-paper p-3 shadow-[inset_0_0_0_1px_var(--line)]">
      <div className="mb-2 flex items-center justify-between gap-3 text-xs text-stone">
        <span>最近记录日</span>
        <span>{recentRows.length} 天</span>
      </div>
      <div className="space-y-2">
        {recentRows.length ? recentRows.map(([date, value]) => <div key={date} className="grid grid-cols-[3.5rem_minmax(0,1fr)_auto] items-center gap-3 text-sm">
          <span className="text-stone">{date.slice(5)}</span>
          <div className="h-1.5 overflow-hidden rounded-full bg-line">
            <div className="h-full rounded-full bg-[rgb(var(--color-expense))]" style={{ width: `${Math.max(3, Math.min(100, value.expense / Math.max(1, lastSevenExpense) * 100))}%` }} />
          </div>
          <span className="min-w-16 text-right text-xs tabular-nums text-warm">{showAmounts ? formatValuation(value.expense / 100, valuationCurrency) : "••••••"}</span>
        </div>) : <div className="py-3 text-center text-sm text-stone">暂无最近记录。</div>}
      </div>
    </div>
  </section>;
}

function BriefRow({ title, value, detail, tone, icon, onClick }: { title: string; value: string; detail: string; tone: string; icon?: React.ReactNode; onClick?: () => void }) {
  const content = <><div className="min-w-0 flex-1">
    <div className="text-xs text-stone">{title}</div>
    <div className={`mt-1 truncate text-sm font-semibold tabular-nums ${tone}`}>{value}</div>
    <div className="mt-0.5 truncate text-xs text-stone">{detail}</div>
  </div>{icon && <span className={`grid h-8 w-8 shrink-0 place-items-center rounded-xl bg-paper ${tone}`}>{icon}</span>}</>;
  if (!onClick) return <div className="flex min-w-0 items-center gap-3 rounded-2xl border border-line bg-panel p-3">{content}</div>;
  return <button type="button" className="flex w-full min-w-0 items-center gap-3 rounded-2xl border border-line bg-panel p-3 text-left hover:bg-tag focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2 focus-visible:ring-offset-paper" onClick={onClick}>{content}</button>;
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
