import { Eye, EyeOff } from "lucide-react";
import { Bar, CartesianGrid, ComposedChart, Line, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { formatCny } from "@/lib/money";
import { formatAccountOptionLabel } from "./accountDisplay";
import { Metric } from "./shared";
import type { AccountStatus, BudgetRow, CreditCardAnalytics, ExpenseCategoryAnalytics, PrivacySettings, Summary } from "./types";

export function HomePage({ summary, privacySettings, sensitiveUnlocked, creditCards, expenseAnalytics, budgetRows, accountStatuses, onPrivacyChange, onSelectCategory }: { summary: Summary | null; privacySettings: PrivacySettings; sensitiveUnlocked: boolean; creditCards: CreditCardAnalytics[]; expenseAnalytics: ExpenseCategoryAnalytics[]; budgetRows: BudgetRow[]; accountStatuses: AccountStatus[]; onPrivacyChange: <K extends keyof PrivacySettings>(key: K, value: PrivacySettings[K]) => void; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  const showAmounts = privacySettings.showHomeSummaryAmounts;
  const canShowSensitive = sensitiveUnlocked && showAmounts;
  const mask = (value: string, sensitive = true) => sensitive ? canShowSensitive ? value : "••••••" : showAmounts ? value : "••••••";
  const cardOutstanding = creditCards.reduce((sum, card) => sum + card.outstanding, 0);
  const cardSpend = creditCards.reduce((sum, card) => sum + card.billCycleSpend, 0);
  const topCategories = expenseAnalytics.slice(0, 3);
  const unknown = expenseAnalytics.find((row) => row.account === "Expenses:Unknown");
  const budgetPressure = budgetRows.filter((row) => row.ratio !== null).sort((a, b) => (b.ratio ?? 0) - (a.ratio ?? 0)).slice(0, 3);
  const healthCounts = accountStatuses.reduce<Record<AccountStatus["status"], number>>((acc, item) => ({ ...acc, [item.status]: acc[item.status] + 1 }), { green: 0, red: 0, yellow: 0, grey: 0 });
  const dayRows = Object.entries(summary?.days ?? {}).sort(([a], [b]) => a.localeCompare(b));
  const dashboardGridClass = "grid gap-4 xl:grid-cols-[minmax(0,5fr)_minmax(0,7fr)]";

  return <>
    <div className={`${dashboardGridClass} xl:items-stretch`}>
      <div className="flex flex-col gap-4 xl:h-full">
        <section className="card overflow-hidden p-0">
          <div className="border-l-4 border-brand p-4 md:p-5">
            <div className="flex items-start justify-between gap-4">
              <div>
                <div className="text-[11px] uppercase tracking-[0.2em] text-stone">financial dashboard</div>
                <h1 className="mt-1.5 font-serif text-2xl font-medium leading-tight md:text-3xl">本期总览</h1>
                <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">收支、信用卡、预算和待整理项集中查看。</p>
              </div>
              <button className="shrink-0 rounded-xl border border-line bg-panel px-3 py-2 text-sm text-olive hover:bg-tag" onClick={() => onPrivacyChange("showHomeSummaryAmounts", !privacySettings.showHomeSummaryAmounts)} title={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"} aria-label={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"}>
                {privacySettings.showHomeSummaryAmounts ? <EyeOff className="h-4 w-4 text-brand" /> : <Eye className="h-4 w-4 text-brand" />}
              </button>
            </div>
          </div>
          <div className="grid grid-cols-3 divide-x divide-line border-t border-line p-3 text-center md:p-4">
            <Metric label="收入" value={mask(formatCny((summary?.income ?? 0) / 100))} cls="amount-income text-base sm:text-xl" />
            <Metric label="支出" value={mask(formatCny((summary?.expense ?? 0) / 100), false)} cls="amount-expense text-base sm:text-xl" />
            <Metric label="结余" value={mask(formatCny((summary?.net ?? 0) / 100))} cls="amount-gold text-base sm:text-xl" />
          </div>
        </section>
        <section className="grid gap-3 sm:grid-cols-2 xl:grid-rows-2 xl:flex-1">
          <DashboardCard label="信用卡未还" value={mask(formatCny(cardOutstanding / 100))} tone="amount-expense" detail={`账单周期消费 ${mask(formatCny(cardSpend / 100))}`} />
          <DashboardCard label="预算压力" value={budgetPressure[0] ? `${Math.round((budgetPressure[0].ratio ?? 0) * 100)}%` : "暂无"} tone={(budgetPressure[0]?.ratio ?? 0) >= 1 ? "amount-expense" : "amount-gold"} detail={budgetPressure[0] ? formatAccountOptionLabel(budgetPressure[0].account, budgetPressure[0].label, budgetPressure[0].alias) : "暂无预算数据"} />
          <DashboardCard label="账户健康" value={`${healthCounts.red} 红 · ${healthCounts.yellow} 黄 · ${healthCounts.grey} 灰`} tone={healthCounts.red ? "amount-expense" : healthCounts.yellow || healthCounts.grey ? "amount-gold" : "amount-income"} detail={`${healthCounts.green} 个账户断言通过`} />
          <DashboardCard label="待整理" value={unknown ? formatCny(unknown.amount / 100) : "无"} tone={unknown ? "amount-expense" : "amount-income"} detail={unknown ? `${unknown.txCount} 笔 Unknown` : "Unknown 已清理"} onClick={unknown && onSelectCategory ? () => onSelectCategory("Expenses:Unknown", "exact") : undefined} />
        </section>
      </div>
      <DailyTrendCard rows={dayRows} showAmounts={showAmounts} />
    </div>

    <div className={`${dashboardGridClass} mt-4 items-start`}>
      <ListCard title="支出 Top 分类" items={topCategories.map((row) => ({ key: row.account, title: formatAccountOptionLabel(row.account, row.label, row.alias), value: formatCny(row.amount / 100), detail: `${row.txCount} 笔 · ${row.share == null ? "—" : `${(row.share * 100).toFixed(1)}%`}`, onClick: onSelectCategory ? () => onSelectCategory(row.account, "prefix") : undefined }))} empty="暂无支出分类" />
      <ListCard title="预算压力" items={budgetPressure.map((row) => ({ key: row.account, title: formatAccountOptionLabel(row.account, row.label, row.alias), value: `${Math.round((row.ratio ?? 0) * 100)}%`, detail: showAmounts ? `剩余 ${formatCny(row.remaining / 100)}` : "金额已隐藏" }))} empty="暂无预算数据" />
    </div>

  </>;
}

function DailyTrendCard({ rows, showAmounts }: { rows: [string, { income: number; expense: number }][]; showAmounts: boolean }) {
  const label = rows.length ? `${rows[0][0].slice(5)} ~ ${rows.at(-1)?.[0].slice(5)}` : "本期";
  const data = rows.map(([date, value]) => ({
    date,
    income: value.income / 100,
    expense: value.expense / 100,
  }));
  return <section className="card flex h-full min-h-[360px] flex-col p-4 xl:min-h-0">
    <div className="flex items-start justify-between gap-3">
      <div>
        <div className="text-[11px] uppercase tracking-[0.18em] text-stone">daily rhythm</div>
        <h2 className="mt-1 font-serif text-xl">日收支趋势</h2>
        <div className="mt-1 flex flex-wrap items-center gap-3 text-xs text-stone">
          <span className="inline-flex items-center gap-1"><span className="h-2 w-2 rounded-sm bg-[rgb(var(--color-expense))]" />支出柱</span>
          <span className="inline-flex items-center gap-1"><span className="h-2 w-2 rounded-full bg-[rgb(var(--color-income))]" />收入线</span>
        </div>
      </div>
      <span className="rounded-full bg-tag px-2 py-1 text-xs text-stone">{label}</span>
    </div>
    {rows.length ? showAmounts ? <div className="ledger-chart mt-4 min-h-[260px] min-w-0 flex-1 xl:min-h-0">
      <ResponsiveContainer width="100%" height="100%">
        <ComposedChart data={data} margin={{ top: 8, right: 10, bottom: 0, left: 0 }} barCategoryGap="34%">
          <CartesianGrid stroke="var(--chart-grid)" strokeDasharray="3 3" vertical={false} />
          <XAxis dataKey="date" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={12} tickFormatter={(value) => String(value).slice(5)} />
          <YAxis yAxisId="expense" width={48} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactMoney} />
          <YAxis yAxisId="income" orientation="right" width={48} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactMoney} />
          <Tooltip
            cursor={{ fill: "var(--selected-bg)" }}
            contentStyle={{ background: "var(--ivory)", border: "1px solid var(--line)", borderRadius: 12, color: "var(--ink)" }}
            labelFormatter={(label) => String(label)}
            formatter={(value, name) => [formatCny(Number(value)), name === "收入" ? "收入" : "支出"]}
          />
          <Bar yAxisId="expense" dataKey="expense" name="支出" fill="rgb(var(--color-expense))" radius={[4, 4, 0, 0]} maxBarSize={22} />
          <Line yAxisId="income" type="monotone" dataKey="income" name="收入" stroke="rgb(var(--color-income))" strokeWidth={2} dot={{ r: 2, fill: "rgb(var(--color-income))" }} activeDot={{ r: 4 }} />
        </ComposedChart>
      </ResponsiveContainer>
    </div> : <div className="mt-4 grid min-h-[260px] flex-1 place-items-center rounded-xl border border-line bg-panel text-sm text-stone xl:min-h-0">金额已隐藏，显示金额后可查看趋势与明细。</div> : <div className="mt-4 grid min-h-[260px] flex-1 place-items-center rounded-xl border border-line bg-panel text-sm text-stone xl:min-h-0">暂无日趋势数据</div>}
  </section>;
}

function compactMoney(value: number) {
  if (Math.abs(value) >= 10000) return `${Math.round(value / 10000)}万`;
  if (Math.abs(value) >= 1000) return `${Math.round(value / 1000)}k`;
  return `${Math.round(value)}`;
}

function DashboardCard({ label, value, tone, detail, onClick }: { label: string; value: string; tone: string; detail?: string; onClick?: () => void }) {
  const content = <><div className="text-[11px] uppercase tracking-[0.14em] text-stone">{label}</div><div className={`mt-1.5 text-lg font-semibold ${tone}`}>{value}</div>{detail && <div className="mt-0.5 text-xs text-stone">{detail}</div>}</>;
  if (!onClick) return <div className="h-full rounded-2xl border border-line bg-panel p-3">{content}</div>;
  return <button className="h-full rounded-2xl border border-line bg-panel p-3 text-left hover:bg-tag" onClick={onClick}>{content}</button>;
}

function ListCard({ title, items, empty }: { title: string; items: { key: string; title: string; value: string; detail?: string; onClick?: () => void }[]; empty: string }) {
  return <section className="card p-4"><h2 className="font-serif text-xl">{title}</h2><div className="mt-3 space-y-2">{items.length ? items.map((item) => {
    const content = <><div className="min-w-0"><div className="truncate text-sm font-medium text-olive">{item.title}</div>{item.detail && <div className="mt-0.5 text-xs text-stone">{item.detail}</div>}</div><div className="shrink-0 font-semibold text-warm">{item.value}</div></>;
    return item.onClick ? <button key={item.key} className="flex w-full items-center justify-between gap-3 rounded-xl border border-line bg-panel p-3 text-left hover:bg-tag" onClick={item.onClick}>{content}</button> : <div key={item.key} className="flex items-center justify-between gap-3 rounded-xl border border-line bg-panel p-3">{content}</div>;
  }) : <div className="rounded-xl border border-line bg-panel p-4 text-center text-sm text-stone">{empty}</div>}</div></section>;
}
