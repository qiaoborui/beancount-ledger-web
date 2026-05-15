import { Eye, EyeOff } from "lucide-react";
import { Area, AreaChart, CartesianGrid, Cell, Legend, Line, LineChart, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { formatCny, formatCompactCny } from "@/lib/money";
import { Metric } from "./shared";
import type { AccountView, IncomeStatementCache } from "./types";

const COLORS = [
  "var(--chart-palette-1)",
  "var(--chart-palette-2)",
  "var(--chart-palette-3)",
  "var(--chart-palette-4)",
  "var(--chart-palette-5)",
  "var(--chart-palette-6)",
];

export function NetWorthPage({ rows, balances, accounts, incomeStatement, visible, onToggleVisible }: { rows: { date: string; 资产: number; 负债: number; 净资产: number }[]; balances: Record<string, number>; accounts: AccountView[]; incomeStatement: IncomeStatementCache; visible: boolean; onToggleVisible: () => void }) {
  const assets = Object.entries(balances).filter(([a]) => a.startsWith("Assets:")).reduce((s, [, v]) => s + v, 0);
  const liabilities = Object.entries(balances).filter(([a]) => a.startsWith("Liabilities:")).reduce((s, [, v]) => s + Math.abs(v), 0);
  const currentNetWorth = assets - liabilities;
  const recentRows = rows.slice(-6);
  const baseline = recentRows[0] ?? rows[0];
  const latest = rows.at(-1);
  const netWorthChange = latest && baseline ? latest.净资产 - baseline.净资产 : 0;
  const income = Math.abs(incomeStatement?.totalIncome ?? 0);
  const netIncome = incomeStatement?.netIncome ?? 0;
  const investmentIncome = sumTree(incomeStatement?.income ?? [], (account) => /Investment|Interest|Dividend|Wealth|理财|利息|股息/i.test(account));
  const savingsRate = income > 0 ? netIncome / income : null;
  const mask = (value: string) => visible ? value : "••••••";

  return <>
    <section className="card p-4">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="grid flex-1 grid-cols-3 divide-x divide-line text-center">
          <Metric label="资产" value={mask(formatCompactCny(assets / 100))} cls="amount-income text-lg sm:text-xl" />
          <Metric label="负债" value={mask(formatCompactCny(liabilities / 100))} cls="amount-expense text-lg sm:text-xl" />
          <Metric label="净资产" value={mask(formatCompactCny(currentNetWorth / 100))} cls="amount-gold text-lg sm:text-xl" />
        </div>
        <button className="shrink-0 self-end rounded-xl border border-line bg-panel px-3 py-2 text-sm text-olive hover:bg-panel sm:self-auto" onClick={onToggleVisible}>{visible ? <EyeOff className="inline h-4 w-4" /> : <Eye className="inline h-4 w-4" />} <span className="ml-1">{visible ? "隐藏金额" : "显示金额"}</span></button>
      </div>
    </section>
    <section className="mt-6 grid gap-4 sm:grid-cols-3">
      <InsightCard label="期间净收入" value={mask(formatCny(netIncome / 100))} tone={netIncome >= 0 ? "amount-income" : "amount-expense"} />
      <InsightCard label="储蓄率" value={visible ? savingsRate === null ? "收入为 0" : `${(savingsRate * 100).toFixed(1)}%` : "••••••"} tone="amount-gold" />
      <InsightCard label="近六期净值变化" value={mask(`${netWorthChange >= 0 ? "+" : ""}${formatCny(netWorthChange)}`)} tone={netWorthChange >= 0 ? "amount-income" : "amount-expense"} />
    </section>
    <section className="mt-4 grid gap-4 sm:grid-cols-2"><InsightCard label="财富/投资收入" value={mask(formatCny(investmentIncome / 100))} tone="amount-income" /><InsightCard label="负债率" value={visible ? assets > 0 ? `${(liabilities / assets * 100).toFixed(1)}%` : "暂无资产" : "••••••"} tone="amount-expense" /></section>
    <AssetAllocation accounts={accounts} balances={balances} visible={visible} />
    <section className="mt-6 grid gap-6 xl:grid-cols-2"><AssetComposition accounts={accounts} balances={balances} visible={visible} /><LiabilitiesTrend rows={rows} visible={visible} /></section>
    <NetWorthChart rows={rows} visible={visible} />
  </>;
}

function InsightCard({ label, value, tone }: { label: string; value: string; tone: string }) {
  return <div className="rounded-2xl border border-line bg-panel p-4"><div className="text-xs uppercase tracking-[0.18em] text-stone">{label}</div><div className={`mt-2 text-xl font-semibold ${tone}`}>{value}</div></div>;
}

function AssetAllocation({ accounts, balances, visible }: { accounts: AccountView[]; balances: Record<string, number>; visible: boolean }) {
  const bucket = (match: (account: AccountView) => boolean) => accounts.filter(match).reduce((sum, account) => sum + (balances[account.account] ?? 0), 0);
  const cash = bucket((a) => a.account.startsWith("Assets:") && a.group === "cash");
  const wealth = bucket((a) => a.account.includes(":Wealth"));
  const fund = bucket((a) => a.account.includes(":Fund"));
  const housing = bucket((a) => a.account.includes(":HousingFund"));
  const otherAssets = Object.entries(balances).filter(([account]) => account.startsWith("Assets:") && !accounts.some((a) => a.account === account && (a.group === "cash" || a.account.includes(":Wealth") || a.account.includes(":Fund") || a.account.includes(":HousingFund")))).reduce((sum, [, value]) => sum + value, 0);
  const liabilities = Object.entries(balances).filter(([a]) => a.startsWith("Liabilities:")).reduce((s, [, v]) => s + Math.abs(v), 0);
  const totalAssets = Math.max(1, cash + wealth + fund + housing + otherAssets);
  const rows = [{ label: "现金", value: cash }, { label: "理财", value: wealth }, { label: "基金", value: fund }, { label: "公积金", value: housing }, { label: "其他资产", value: otherAssets }, { label: "负债", value: -liabilities }];
  return <section className="card mt-6 p-4"><h2 className="font-serif text-2xl">资产配置</h2><div className="mt-4 space-y-3">{rows.map((row) => { const pct = row.value / totalAssets * 100; return <div key={row.label}><div className="flex justify-between text-sm"><span>{row.label}</span><strong>{Math.round(pct)}%{visible ? ` · ${formatCompactCny(row.value / 100)}` : ""}</strong></div><div className="mt-1 h-2 overflow-hidden rounded-xl bg-line"><div className={row.value < 0 ? "h-full bg-[var(--danger)]" : "h-full bg-brand"} style={{ width: `${Math.min(Math.abs(pct), 100)}%` }} /></div></div>; })}</div><p className="mt-3 text-xs text-stone">隐私模式下只显示配置百分比，不显示具体金额。</p></section>;
}

function AssetComposition({ accounts, balances, visible }: { accounts: AccountView[]; balances: Record<string, number>; visible: boolean }) {
  const rows = accounts.filter((account) => account.account.startsWith("Assets:")).map((account) => ({ name: account.label || account.account.split(":").at(-1) || account.account, value: Math.max(0, (balances[account.account] ?? 0) / 100) })).filter((row) => row.value > 0).sort((a, b) => b.value - a.value).slice(0, 8);
  return <section className="card p-4"><h2 className="font-serif text-2xl">当前资产明细</h2>{visible ? <div className="mt-4 h-72"><ResponsiveContainer width="100%" height="100%"><PieChart><Pie data={rows} dataKey="value" nameKey="name" innerRadius={56} outerRadius={92} paddingAngle={2}>{rows.map((_, index) => <Cell key={index} fill={COLORS[index % COLORS.length]} />)}</Pie><Tooltip formatter={(value) => formatCny(Number(value))} /><Legend /></PieChart></ResponsiveContainer></div> : <HiddenMoney />}</section>;
}

function LiabilitiesTrend({ rows, visible }: { rows: { date: string; 负债: number }[]; visible: boolean }) {
  return <section className="card p-4"><h2 className="font-serif text-2xl">负债趋势</h2>{visible ? <div className="mt-4 h-72"><ResponsiveContainer width="100%" height="100%"><AreaChart data={rows} margin={{ left: 8, right: 16, top: 8, bottom: 0 }}><CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" /><XAxis dataKey="date" minTickGap={18} /><YAxis width={56} tickFormatter={(value) => chartMoney(Number(value))} /><Tooltip formatter={(value) => formatCny(Number(value))} /><Area type="monotone" dataKey="负债" stroke="var(--chart-secondary)" fill="var(--chart-fill)" /></AreaChart></ResponsiveContainer></div> : <HiddenMoney />}</section>;
}

function chartMoney(value: number) {
  return new Intl.NumberFormat("en-US", { notation: "compact", compactDisplay: "short", maximumFractionDigits: 1 }).format(value);
}

function NetWorthChart({ rows, visible }: { rows: { date: string; 资产: number; 负债: number; 净资产: number }[]; visible: boolean }) {
  return <section className="card mt-6 p-4"><h2 className="font-serif text-2xl">净资产变化</h2>{visible ? <div className="mt-4 h-72 min-w-0"><ResponsiveContainer width="100%" height="100%"><LineChart data={rows} margin={{ left: 8, right: 16, top: 8, bottom: 0 }}><CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" /><XAxis dataKey="date" minTickGap={18} /><YAxis width={56} domain={["dataMin", "dataMax"]} tickFormatter={(value) => chartMoney(Number(value))} allowDataOverflow={false} /><Tooltip formatter={(value, name) => [formatCny(Number(value)), name]} /><Legend /><Line type="monotone" dataKey="净资产" stroke="var(--chart-primary)" strokeWidth={3} dot /><Line type="monotone" dataKey="资产" stroke="var(--chart-tertiary)" strokeWidth={2} dot={false} /><Line type="monotone" dataKey="负债" stroke="var(--chart-secondary)" strokeWidth={2} dot={false} /></LineChart></ResponsiveContainer></div> : <HiddenMoney />}</section>;
}

function HiddenMoney() {
  return <div className="mt-4 rounded-xl border border-line bg-panel p-6 text-center text-sm text-stone">此图包含具体金额，已隐藏。点击上方“显示金额”后查看。</div>;
}

type IncomeNode = NonNullable<IncomeStatementCache>["income"][number];
function sumTree(nodes: IncomeNode[], match: (account: string) => boolean): number {
  return nodes.reduce((sum, node) => sum + (match(`${node.account} ${node.label}`) ? node.amount : 0) + sumTree(node.children, match), 0);
}
