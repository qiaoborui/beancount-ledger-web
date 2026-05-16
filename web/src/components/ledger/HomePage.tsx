import { Eye, EyeOff } from "lucide-react";
import { Bar, BarChart, CartesianGrid, Legend, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { formatCny } from "@/lib/money";
import { HiddenPanel, Metric } from "./shared";
import type { AccountStatus, BudgetRow, CreditCardAnalytics, ExpenseCategoryAnalytics, PrivacySettings, Summary } from "./types";

export function HomePage({ summary, chart, privacySettings, sensitiveUnlocked, creditCards, expenseAnalytics, budgetRows, accountStatuses, onPrivacyChange, onSelectCategory }: { summary: Summary | null; chart: { day: string; 收入: number; 支出: number }[]; privacySettings: PrivacySettings; sensitiveUnlocked: boolean; creditCards: CreditCardAnalytics[]; expenseAnalytics: ExpenseCategoryAnalytics[]; budgetRows: BudgetRow[]; accountStatuses: AccountStatus[]; onPrivacyChange: <K extends keyof PrivacySettings>(key: K, value: PrivacySettings[K]) => void; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  const showAmounts = privacySettings.showHomeSummaryAmounts;
  const canShowSensitive = sensitiveUnlocked && showAmounts;
  const mask = (value: string, sensitive = true) => sensitive ? canShowSensitive ? value : "••••••" : showAmounts ? value : "••••••";
  const cardOutstanding = creditCards.reduce((sum, card) => sum + card.outstanding, 0);
  const cardSpend = creditCards.reduce((sum, card) => sum + card.billCycleSpend, 0);
  const topCategories = expenseAnalytics.slice(0, 3);
  const unknown = expenseAnalytics.find((row) => row.account === "Expenses:Unknown");
  const budgetPressure = budgetRows.filter((row) => row.ratio !== null).sort((a, b) => (b.ratio ?? 0) - (a.ratio ?? 0)).slice(0, 3);
  const healthCounts = accountStatuses.reduce<Record<AccountStatus["status"], number>>((acc, item) => ({ ...acc, [item.status]: acc[item.status] + 1 }), { green: 0, red: 0, yellow: 0, grey: 0 });

  return <>
    <section className="card overflow-hidden p-0">
      <div className="border-l-4 border-brand p-5 md:p-6">
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="text-xs uppercase tracking-[0.24em] text-stone">financial dashboard</div>
            <h1 className="mt-2 font-serif text-3xl font-medium leading-tight md:text-4xl">现金流、信用卡和待整理项先看。</h1>
            <p className="mt-3 max-w-2xl text-sm leading-6 text-olive">首页聚合本期收支、信用卡压力、预算风险和待整理项；净资产保留在独立页面。解锁后金额默认可见，可用右侧眼睛临时隐藏。</p>
          </div>
          <button className="shrink-0 rounded-xl border border-line bg-panel px-3 py-2 text-sm text-olive hover:bg-tag" onClick={() => onPrivacyChange("showHomeSummaryAmounts", !privacySettings.showHomeSummaryAmounts)} title={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"} aria-label={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"}>
            {privacySettings.showHomeSummaryAmounts ? <EyeOff className="h-4 w-4 text-brand" /> : <Eye className="h-4 w-4 text-brand" />}
          </button>
        </div>
      </div>
      <div className="grid grid-cols-3 divide-x divide-line border-t border-line p-5 text-center">
        <Metric label="收入" value={mask(formatCny((summary?.income ?? 0) / 100))} cls="amount-income text-lg sm:text-2xl" />
        <Metric label="支出" value={mask(formatCny((summary?.expense ?? 0) / 100), false)} cls="amount-expense text-lg sm:text-2xl" />
        <Metric label="结余" value={mask(formatCny((summary?.net ?? 0) / 100))} cls="amount-gold text-lg sm:text-2xl" />
      </div>
    </section>

    <section className="mt-6 grid gap-4 md:grid-cols-2 xl:grid-cols-4">
      <DashboardCard label="信用卡未还" value={mask(formatCny(cardOutstanding / 100))} tone="amount-expense" detail={`账单周期消费 ${mask(formatCny(cardSpend / 100))}`} />
      <DashboardCard label="预算压力" value={budgetPressure[0] ? `${Math.round((budgetPressure[0].ratio ?? 0) * 100)}%` : "暂无"} tone={(budgetPressure[0]?.ratio ?? 0) >= 1 ? "amount-expense" : "amount-gold"} detail={budgetPressure[0]?.account.replace(/^Expenses:/, "") ?? "暂无预算数据"} />
      <DashboardCard label="账户健康" value={`${healthCounts.red} 红 · ${healthCounts.yellow} 黄 · ${healthCounts.grey} 灰`} tone={healthCounts.red ? "amount-expense" : healthCounts.yellow || healthCounts.grey ? "amount-gold" : "amount-income"} detail={`${healthCounts.green} 个账户断言通过`} />
      <DashboardCard label="待整理" value={unknown ? formatCny(unknown.amount / 100) : "无"} tone={unknown ? "amount-expense" : "amount-income"} detail={unknown ? `${unknown.txCount} 笔 Unknown` : "Unknown 已清理"} onClick={unknown && onSelectCategory ? () => onSelectCategory("Expenses:Unknown", "exact") : undefined} />
    </section>

    <section className="mt-6 grid gap-4 xl:grid-cols-2">
      <ListCard title="支出 Top 分类" items={topCategories.map((row) => ({ key: row.account, title: row.label, value: formatCny(row.amount / 100), detail: `${row.txCount} 笔 · ${row.share == null ? "—" : `${(row.share * 100).toFixed(1)}%`}`, onClick: onSelectCategory ? () => onSelectCategory(row.account, "prefix") : undefined }))} empty="暂无支出分类" />
      <ListCard title="预算压力" items={budgetPressure.map((row) => ({ key: row.account, title: row.account.replace(/^Expenses:/, ""), value: `${Math.round((row.ratio ?? 0) * 100)}%`, detail: showAmounts ? `剩余 ${formatCny(row.remaining / 100)}` : "金额已隐藏" }))} empty="暂无预算数据" />
    </section>

    <section className="card mt-6 p-5">
      <div className="mb-4 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
        <div><h2 className="font-serif text-2xl font-medium">每日收支节奏</h2><p className="mt-1 text-sm text-olive">保留日节奏图，但首页结论由上方卡片承担。</p></div>
      </div>
      {privacySettings.showHomeCashflowChart ? <div className="h-72"><ResponsiveContainer width="100%" height="100%"><BarChart data={chart}><CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" /><XAxis dataKey="day" /><YAxis /><Tooltip /><Legend />{sensitiveUnlocked && <Bar dataKey="收入" fill="var(--chart-primary)" />}<Bar dataKey="支出" fill="var(--chart-secondary)" /></BarChart></ResponsiveContainer></div> : <HiddenPanel text="每日支出图包含具体金额，默认隐藏。收入曲线需解锁后才会显示。" />}
    </section>
  </>;
}

function DashboardCard({ label, value, tone, detail, onClick }: { label: string; value: string; tone: string; detail?: string; onClick?: () => void }) {
  const content = <><div className="text-xs uppercase tracking-[0.18em] text-stone">{label}</div><div className={`mt-2 text-xl font-semibold ${tone}`}>{value}</div>{detail && <div className="mt-1 text-xs text-stone">{detail}</div>}</>;
  if (!onClick) return <div className="rounded-2xl border border-line bg-panel p-4">{content}</div>;
  return <button className="rounded-2xl border border-line bg-panel p-4 text-left hover:bg-tag" onClick={onClick}>{content}</button>;
}

function ListCard({ title, items, empty }: { title: string; items: { key: string; title: string; value: string; detail?: string; onClick?: () => void }[]; empty: string }) {
  return <section className="card p-4"><h2 className="font-serif text-2xl">{title}</h2><div className="mt-4 space-y-3">{items.length ? items.map((item) => {
    const content = <><div className="min-w-0"><div className="truncate text-sm font-medium text-olive">{item.title}</div>{item.detail && <div className="mt-0.5 text-xs text-stone">{item.detail}</div>}</div><div className="shrink-0 font-semibold text-warm">{item.value}</div></>;
    return item.onClick ? <button key={item.key} className="flex w-full items-center justify-between gap-3 rounded-xl border border-line bg-panel p-3 text-left hover:bg-tag" onClick={item.onClick}>{content}</button> : <div key={item.key} className="flex items-center justify-between gap-3 rounded-xl border border-line bg-panel p-3">{content}</div>;
  }) : <div className="rounded-xl border border-line bg-panel p-4 text-center text-sm text-stone">{empty}</div>}</div></section>;
}

