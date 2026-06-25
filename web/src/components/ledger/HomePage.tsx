import { Eye, EyeOff } from "lucide-react";
import { lazy, Suspense, useEffect, useRef, useState } from "react";
import { formatValuation } from "@/lib/money";
import { formatAccountOptionLabel } from "./accountDisplay";
import { Metric } from "./shared";
import type { AccountStatus, CreditCardAnalytics, ExpenseCategoryAnalytics, PrivacySettings, Summary } from "./types";

const LazyHomeDailyTrendChart = lazy(() => import("./HomeDailyTrendChart").then((mod) => ({ default: mod.HomeDailyTrendChart })));

export function HomePage({ summary, valuationCurrency, privacySettings, sensitiveUnlocked, creditCards, expenseAnalytics, accountStatuses, onPrivacyChange, onSelectCategory }: { summary: Summary | null; valuationCurrency: string; privacySettings: PrivacySettings; sensitiveUnlocked: boolean; creditCards: CreditCardAnalytics[]; expenseAnalytics: ExpenseCategoryAnalytics[]; accountStatuses: AccountStatus[]; onPrivacyChange: <K extends keyof PrivacySettings>(key: K, value: PrivacySettings[K]) => void; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  const showAmounts = privacySettings.showHomeSummaryAmounts;
  const displayCurrency = summary?.currency ?? valuationCurrency;
  const canShowSensitive = sensitiveUnlocked && showAmounts;
  const mask = (value: string, sensitive = true) => sensitive ? canShowSensitive ? value : "••••••" : showAmounts ? value : "••••••";
  const cardOutstanding = creditCards.reduce((sum, card) => sum + card.outstanding, 0);
  const cardSpend = creditCards.reduce((sum, card) => sum + card.billCycleSpend, 0);
  const topCategories = expenseAnalytics.slice(0, 3);
  const topCategory = topCategories[0];
  const unknown = expenseAnalytics.find((row) => row.account === "Expenses:Unknown");
  const healthCounts = accountStatuses.reduce<Record<AccountStatus["status"], number>>((acc, item) => ({ ...acc, [item.status]: acc[item.status] + 1 }), { green: 0, red: 0, yellow: 0, grey: 0 });
  const dayRows = Object.entries(summary?.days ?? {}).sort(([a], [b]) => a.localeCompare(b));
  const dashboardGridClass = "grid min-w-0 gap-4 xl:grid-cols-[minmax(0,5fr)_minmax(0,7fr)]";

  return <>
    <div className={`${dashboardGridClass} xl:items-stretch`}>
      <div className="flex min-w-0 flex-col gap-4 xl:h-full">
        <section className="card min-w-0 overflow-hidden p-0">
          <div className="border-l-4 border-brand p-4 md:p-5">
            <div className="flex items-start justify-between gap-4">
              <div>
                <div className="ledger-kicker">financial dashboard</div>
                <h1 className="mt-1.5 font-serif text-2xl font-medium leading-tight md:text-3xl">本期总览</h1>
                <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">收支、信用卡、分类和待整理项集中查看。</p>
              </div>
              <button className="shrink-0 rounded-xl border border-line bg-panel px-3 py-2 text-sm text-olive hover:bg-tag" onClick={() => onPrivacyChange("showHomeSummaryAmounts", !privacySettings.showHomeSummaryAmounts)} title={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"} aria-label={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"}>
                {privacySettings.showHomeSummaryAmounts ? <EyeOff className="h-4 w-4 text-brand" /> : <Eye className="h-4 w-4 text-brand" />}
              </button>
            </div>
          </div>
          <div className="grid grid-cols-3 divide-x divide-line border-t border-line p-3 text-center md:p-4">
            <Metric label="收入" value={mask(formatValuation((summary?.income ?? 0) / 100, displayCurrency))} cls="amount-income text-base sm:text-xl" />
            <Metric label="支出" value={mask(formatValuation((summary?.expense ?? 0) / 100, displayCurrency), false)} cls="amount-expense text-base sm:text-xl" />
            <Metric label="结余" value={mask(formatValuation((summary?.net ?? 0) / 100, displayCurrency))} cls="amount-gold text-base sm:text-xl" />
          </div>
        </section>
        <section className="grid min-w-0 gap-3 sm:grid-cols-2 xl:grid-rows-2 xl:flex-1">
          <DashboardCard label="信用卡未还" value={mask(formatValuation(cardOutstanding / 100, displayCurrency))} tone="amount-expense" detail={`账单周期消费 ${mask(formatValuation(cardSpend / 100, displayCurrency))}`} />
          <DashboardCard label="最大分类" value={topCategory ? mask(formatValuation(topCategory.amount / 100, displayCurrency), false) : "暂无"} tone={topCategory ? "amount-expense" : "text-stone"} detail={topCategory ? formatAccountOptionLabel(topCategory.account, topCategory.label, topCategory.alias) : "暂无支出分类"} onClick={topCategory && onSelectCategory ? () => onSelectCategory(topCategory.account, "prefix") : undefined} />
          <DashboardCard label="账户健康" value={`${healthCounts.red} 红 · ${healthCounts.yellow} 黄 · ${healthCounts.grey} 灰`} tone={healthCounts.red ? "amount-expense" : healthCounts.yellow || healthCounts.grey ? "amount-gold" : "amount-income"} detail={`${healthCounts.green} 个账户断言通过`} />
          <DashboardCard label="待整理" value={unknown ? formatValuation(unknown.amount / 100, displayCurrency) : "无"} tone={unknown ? "amount-expense" : "amount-income"} detail={unknown ? `${unknown.txCount} 笔 Unknown` : "Unknown 已清理"} onClick={unknown && onSelectCategory ? () => onSelectCategory("Expenses:Unknown", "exact") : undefined} />
        </section>
      </div>
      <DailyTrendCard rows={dayRows} showAmounts={showAmounts} valuationCurrency={displayCurrency} />
    </div>

    <div className={`${dashboardGridClass} mt-4 items-start`}>
      <ListCard title="支出 Top 分类" items={topCategories.map((row) => ({ key: row.account, title: formatAccountOptionLabel(row.account, row.label, row.alias), value: formatValuation(row.amount / 100, displayCurrency), detail: `${row.txCount} 笔 · ${row.share == null ? "—" : `${(row.share * 100).toFixed(1)}%`}`, onClick: onSelectCategory ? () => onSelectCategory(row.account, "prefix") : undefined }))} empty="暂无支出分类" />
      <ListCard title="待整理分类" items={unknown ? [{ key: unknown.account, title: formatAccountOptionLabel(unknown.account, unknown.label, unknown.alias), value: formatValuation(unknown.amount / 100, displayCurrency), detail: `${unknown.txCount} 笔需要补分类`, onClick: onSelectCategory ? () => onSelectCategory("Expenses:Unknown", "exact") : undefined }] : []} empty="暂无待整理分类" />
    </div>

  </>;
}

function DailyTrendCard({ rows, showAmounts, valuationCurrency }: { rows: [string, { income: number; expense: number }][]; showAmounts: boolean; valuationCurrency: string }) {
  const label = rows.length ? `${rows[0][0].slice(5)} ~ ${rows.at(-1)?.[0].slice(5)}` : "本期";
  const { ref, ready } = useDeferredChartReady(rows.length > 0 && showAmounts);
  return <section className="card flex h-full min-w-0 flex-col overflow-hidden p-4 xl:min-h-0 max-xl:min-h-[360px]">
    <div className="flex items-start justify-between gap-3">
      <div>
        <div className="ledger-kicker">daily rhythm</div>
        <h2 className="mt-1 font-serif text-xl">日收支趋势</h2>
        <div className="mt-1 flex flex-wrap items-center gap-3 text-xs text-stone">
          <span className="inline-flex items-center gap-1"><span className="h-2 w-2 rounded-sm bg-[rgb(var(--color-expense))]" />支出柱</span>
          <span className="inline-flex items-center gap-1"><span className="h-2 w-2 rounded-full bg-[rgb(var(--color-income))]" />收入线</span>
        </div>
      </div>
      <span className="ledger-chip rounded-full px-2 py-1 text-xs">{label}</span>
    </div>
    {rows.length ? showAmounts ? <div ref={ref} className="ledger-chart mt-4 min-h-[260px] min-w-0 max-w-full flex-1 xl:min-h-0">
      {ready ? <Suspense fallback={<div className="grid h-full min-h-[260px] place-items-center rounded-xl border border-line bg-panel text-sm text-stone">正在准备趋势图…</div>}>
        <LazyHomeDailyTrendChart rows={rows} valuationCurrency={valuationCurrency} />
      </Suspense> : <div className="grid h-full min-h-[260px] place-items-center rounded-xl border border-line bg-panel text-sm text-stone">趋势图稍后加载</div>}
    </div> : <div className="mt-4 grid min-h-[260px] flex-1 place-items-center rounded-xl border border-line bg-panel text-sm text-stone xl:min-h-0">金额已隐藏，显示金额后可查看趋势与明细。</div> : <div className="mt-4 grid min-h-[260px] flex-1 place-items-center rounded-xl border border-line bg-panel text-sm text-stone xl:min-h-0">暂无日趋势数据</div>}
  </section>;
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
    const markReady = () => setReady(true);
    const observer = "IntersectionObserver" in window ? new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) markReady();
    }, { rootMargin: "160px" }) : null;

    observer?.observe(element);
    if (!observer) {
      idleId = window.setTimeout(markReady, 600);
    } else if (window.requestIdleCallback) {
      idleId = window.requestIdleCallback(markReady, { timeout: 2200 });
    } else {
      idleId = window.setTimeout(markReady, 1800);
    }

    return () => {
      observer?.disconnect();
      if (idleId != null) {
        if (window.cancelIdleCallback) window.cancelIdleCallback(idleId);
        else window.clearTimeout(idleId);
      }
    };
  }, [enabled, ready]);

  return { ref, ready };
}

function DashboardCard({ label, value, tone, detail, onClick }: { label: string; value: string; tone: string; detail?: string; onClick?: () => void }) {
  const content = <><div className="ledger-kicker truncate">{label}</div><div className={`mt-1.5 truncate text-lg font-semibold tabular-nums ${tone}`}>{value}</div>{detail && <div className="mt-0.5 truncate text-xs text-stone">{detail}</div>}</>;
  if (!onClick) return <div className="h-full min-w-0 overflow-hidden rounded-2xl border border-line bg-panel p-3">{content}</div>;
  return <button className="h-full min-w-0 overflow-hidden rounded-2xl border border-line bg-panel p-3 text-left hover:bg-tag" onClick={onClick}>{content}</button>;
}

function ListCard({ title, items, empty }: { title: string; items: { key: string; title: string; value: string; detail?: string; onClick?: () => void }[]; empty: string }) {
  return <section className="card min-w-0 overflow-hidden p-4"><h2 className="font-serif text-xl">{title}</h2><div className="mt-3 space-y-2">{items.length ? items.map((item) => {
    const content = <><div className="min-w-0 flex-1"><div className="truncate text-sm font-medium text-olive">{item.title}</div>{item.detail && <div className="mt-0.5 truncate text-xs text-stone">{item.detail}</div>}</div><div className="shrink-0 font-semibold text-warm">{item.value}</div></>;
    return item.onClick ? <button key={item.key} className="flex w-full min-w-0 items-center justify-between gap-3 rounded-xl border border-line bg-panel p-3 text-left hover:bg-tag" onClick={item.onClick}>{content}</button> : <div key={item.key} className="flex min-w-0 items-center justify-between gap-3 rounded-xl border border-line bg-panel p-3">{content}</div>;
  }) : <div className="rounded-xl border border-line bg-panel p-4 text-center text-sm text-stone">{empty}</div>}</div></section>;
}
