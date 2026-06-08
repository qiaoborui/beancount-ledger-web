import { useMemo, useState } from "react";
import { Eye, EyeOff } from "lucide-react";
import { Area, AreaChart, CartesianGrid, Cell, Legend, Line, LineChart, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { formatCompactValuation, formatValuation } from "@/lib/money";
import { Metric } from "./shared";
import type { AccountBalance, AccountView, IncomeStatementCache, NetWorthPoint, NetWorthWindows } from "./types";

const COLORS = [
  "var(--chart-palette-1)",
  "var(--chart-palette-2)",
  "var(--chart-palette-3)",
  "var(--chart-palette-4)",
  "var(--chart-palette-5)",
  "var(--chart-palette-6)",
];

type ChartRow = { date: string; 资产: number; 负债: number; 净资产: number };
type ViewMode = "daily" | "month-end";

export function NetWorthPage({ rows, monthEndRows, windows, accountBalances, accounts, incomeStatement, valuationCurrency, visible, onToggleVisible }: { rows: ChartRow[]; monthEndRows: NetWorthPoint[]; windows: NetWorthWindows | null; accountBalances: AccountBalance[]; accounts: AccountView[]; incomeStatement: IncomeStatementCache; valuationCurrency: string; visible: boolean; onToggleVisible: () => void }) {
  const [viewMode, setViewMode] = useState<ViewMode>("month-end");
  const displayCurrency = accountBalances.find((row) => row.valuationCurrency)?.valuationCurrency ?? valuationCurrency;
  const valuationBalances = useMemo(() => valuationByAccount(accountBalances), [accountBalances]);
  const assets = Object.entries(valuationBalances).filter(([a]) => a.startsWith("Assets:")).reduce((s, [, v]) => s + v, 0);
  const liabilities = Object.entries(valuationBalances).filter(([a]) => a.startsWith("Liabilities:")).reduce((s, [, v]) => s + Math.abs(v), 0);
  const currentNetWorth = assets - liabilities;
  const income = Math.abs(incomeStatement?.totalIncome ?? 0);
  const netIncome = incomeStatement?.netIncome ?? 0;
  const investmentIncome = sumTree(incomeStatement?.income ?? [], (account) => /Investment|Interest|Dividend|Wealth|理财|利息|股息/i.test(account));
  const savingsRate = income > 0 ? netIncome / income : null;
  const mask = (value: string) => visible ? value : "••••••";
  const monthEndChart = useMemo(() => monthEndRows.map((row) => ({ date: row.date.slice(0, 7), 资产: row.assets / 100, 负债: row.liabilities / 100, 净资产: row.netWorth / 100 })), [monthEndRows]);
  const chartRows = viewMode === "month-end" ? monthEndChart : rows;

  return <>
    <section className="card p-3 md:p-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="grid flex-1 grid-cols-3 divide-x divide-line text-center">
          <Metric label="资产" value={mask(formatCompactValuation(assets / 100, displayCurrency))} cls="amount-income text-base sm:text-lg" />
          <Metric label="负债" value={mask(formatCompactValuation(liabilities / 100, displayCurrency))} cls="amount-expense text-base sm:text-lg" />
          <Metric label="净资产" value={mask(formatCompactValuation(currentNetWorth / 100, displayCurrency))} cls="amount-gold text-base sm:text-lg" />
        </div>
        <button className="shrink-0 self-end rounded-xl border border-line bg-panel px-3 py-2 text-sm text-olive hover:bg-panel sm:self-auto" onClick={onToggleVisible}>{visible ? <EyeOff className="inline h-4 w-4" /> : <Eye className="inline h-4 w-4" />} <span className="ml-1">{visible ? "隐藏金额" : "显示金额"}</span></button>
      </div>
    </section>

    <section className="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
      <InsightCard label="月末/本期变化" value={mask(formatDelta(windows?.monthChange, displayCurrency))} tone={tone(windows?.monthChange)} detail={windows?.previousMonthEnd ? `对比 ${windows.previousMonthEnd.date}` : "暂无基准"} />
      <InsightCard label="近 6 月变化" value={mask(formatDelta(windows?.sixMonth.change, displayCurrency))} tone={tone(windows?.sixMonth.change)} detail={formatRatio(windows?.sixMonth.changeRatio)} />
      <InsightCard label="近 12 月变化" value={mask(formatDelta(windows?.twelveMonth.change, displayCurrency))} tone={tone(windows?.twelveMonth.change)} detail={formatRatio(windows?.twelveMonth.changeRatio)} />
      <InsightCard label="储蓄率" value={visible ? savingsRate === null ? "收入为 0" : `${(savingsRate * 100).toFixed(1)}%` : "••••••"} tone="amount-gold" detail={mask(`期间净收入 ${formatValuation(netIncome / 100, displayCurrency)}`)} />
    </section>

    <section className="mt-3 grid gap-3 sm:grid-cols-2"><InsightCard label="财富/投资收入" value={mask(formatValuation(investmentIncome / 100, displayCurrency))} tone="amount-income" /><InsightCard label="负债率" value={visible ? assets > 0 ? `${(liabilities / assets * 100).toFixed(1)}%` : "暂无资产" : "••••••"} tone="amount-expense" /></section>
    <AssetAllocation accounts={accounts} balances={valuationBalances} visible={visible} valuationCurrency={displayCurrency} />
    <section className="mt-6 grid gap-6 xl:grid-cols-2"><AssetComposition accounts={accounts} balances={valuationBalances} visible={visible} valuationCurrency={displayCurrency} /><LiabilitiesTrend rows={chartRows} visible={visible} valuationCurrency={displayCurrency} /></section>
    <NetWorthChart rows={chartRows} visible={visible} mode={viewMode} valuationCurrency={displayCurrency} onModeChange={setViewMode} />
  </>;
}

function valuationByAccount(rows: AccountBalance[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const row of rows) {
    if (row.valuationMissing) continue;
    out[row.account] = (out[row.account] ?? 0) + row.valuation;
  }
  return out;
}

function InsightCard({ label, value, tone, detail }: { label: string; value: string; tone: string; detail?: string }) {
  return <div className="rounded-2xl border border-line bg-panel p-3"><div className="text-[11px] uppercase tracking-[0.14em] text-stone">{label}</div><div className={`mt-1.5 text-lg font-semibold ${tone}`}>{value}</div>{detail && <div className="mt-0.5 text-xs text-stone">{detail}</div>}</div>;
}

function AssetAllocation({ accounts, balances, visible, valuationCurrency }: { accounts: AccountView[]; balances: Record<string, number>; visible: boolean; valuationCurrency: string }) {
  const knownAccounts = new Set(accounts.map((account) => account.account));
  const bucket = (match: (account: AccountView) => boolean) => accounts.filter((account) => account.account.startsWith("Assets:") && match(account)).reduce((sum, account) => sum + (balances[account.account] ?? 0), 0);
  const cash = bucket((account) => account.group === "cash");
  const wealth = bucket((account) => account.group === "wealth");
  const receivable = bucket((account) => account.group === "receivable");
  const otherAssets = Object.entries(balances).filter(([account]) => account.startsWith("Assets:") && !knownAccounts.has(account)).reduce((sum, [, value]) => sum + value, 0) + bucket((account) => !["cash", "wealth", "receivable"].includes(account.group));
  const liabilities = Object.entries(balances).filter(([a]) => a.startsWith("Liabilities:")).reduce((s, [, v]) => s + Math.abs(v), 0);
  const totalAssetsRaw = cash + wealth + receivable + otherAssets;
  const totalAssets = Math.max(1, totalAssetsRaw);
  const assetRows = [{ label: "现金", value: cash }, { label: "理财 / 投资", value: wealth }, { label: "应收", value: receivable }, { label: "其他资产", value: otherAssets }].filter((row) => row.value !== 0);
  const liabilityPct = liabilities / totalAssets * 100;
  return <section className="card mt-6 p-4"><h2 className="font-serif text-2xl">资产配置</h2><div className="mt-4 space-y-3">{assetRows.map((row) => { const pct = row.value / totalAssets * 100; return <div key={row.label}><div className="flex justify-between text-sm"><span>{row.label}</span><strong>{Math.round(pct)}%{visible ? ` · ${formatCompactValuation(row.value / 100, valuationCurrency)}` : ""}</strong></div><div className="mt-1 h-2 overflow-hidden rounded-xl bg-line"><div className="h-full bg-brand" style={{ width: `${Math.min(Math.abs(pct), 100)}%` }} /></div></div>; })}<div><div className="flex justify-between text-sm"><span>负债 / 总资产</span><strong>{Math.round(liabilityPct)}%{visible ? ` · ${formatCompactValuation(liabilities / 100, valuationCurrency)}` : ""}</strong></div><div className="mt-1 h-2 overflow-hidden rounded-xl bg-line"><div className="h-full bg-[var(--danger)]" style={{ width: `${Math.min(Math.abs(liabilityPct), 100)}%` }} /></div></div></div><p className="mt-3 text-xs text-stone">资产分类优先读取账户 metadata（如 group: \"wealth\"）；百分比为占总资产比例，负债单独按负债 / 总资产展示。隐私模式下只显示百分比。</p></section>;
}

function AssetComposition({ accounts, balances, visible, valuationCurrency }: { accounts: AccountView[]; balances: Record<string, number>; visible: boolean; valuationCurrency: string }) {
  const rows = accounts.filter((account) => account.account.startsWith("Assets:")).map((account) => ({ name: account.label || account.account.split(":").at(-1) || account.account, value: Math.max(0, (balances[account.account] ?? 0) / 100) })).filter((row) => row.value > 0).sort((a, b) => b.value - a.value).slice(0, 8);
  return <section className="card p-4"><h2 className="font-serif text-2xl">当前资产明细</h2>{visible ? <div className="ledger-chart mt-4 h-72"><ResponsiveContainer width="100%" height="100%"><PieChart><Pie data={rows} dataKey="value" nameKey="name" innerRadius={56} outerRadius={92} paddingAngle={2}>{rows.map((_, index) => <Cell key={index} fill={COLORS[index % COLORS.length]} />)}</Pie><Tooltip formatter={(value) => formatValuation(Number(value), valuationCurrency)} /><Legend /></PieChart></ResponsiveContainer></div> : <HiddenMoney />}</section>;
}

function LiabilitiesTrend({ rows, visible, valuationCurrency }: { rows: ChartRow[]; visible: boolean; valuationCurrency: string }) {
  return <section className="card p-4"><h2 className="font-serif text-2xl">负债趋势</h2>{visible ? <div className="ledger-chart mt-4 h-72"><ResponsiveContainer width="100%" height="100%"><AreaChart data={rows} margin={{ left: 8, right: 16, top: 8, bottom: 0 }}><CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" /><XAxis dataKey="date" minTickGap={18} /><YAxis width={56} tickFormatter={(value) => chartMoney(Number(value))} /><Tooltip formatter={(value) => formatValuation(Number(value), valuationCurrency)} /><Area type="monotone" dataKey="负债" stroke="var(--chart-secondary)" fill="var(--chart-fill)" /></AreaChart></ResponsiveContainer></div> : <HiddenMoney />}</section>;
}

function chartMoney(value: number) {
  return new Intl.NumberFormat("en-US", { notation: "compact", compactDisplay: "short", maximumFractionDigits: 1 }).format(value);
}

function NetWorthChart({ rows, visible, mode, valuationCurrency, onModeChange }: { rows: ChartRow[]; visible: boolean; mode: ViewMode; valuationCurrency: string; onModeChange: (mode: ViewMode) => void }) {
  return <section className="card mt-6 p-4"><div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"><div><h2 className="font-serif text-2xl">净资产变化</h2><p className="mt-1 text-sm text-olive">日视图看波动，月末视图看长期趋势。</p></div><div className="flex rounded-xl border border-line bg-panel p-1 text-sm"><button className={`rounded px-3 py-1 ${mode === "daily" ? "bg-brand text-paper" : "text-olive"}`} onClick={() => onModeChange("daily")}>日视图</button><button className={`rounded px-3 py-1 ${mode === "month-end" ? "bg-brand text-paper" : "text-olive"}`} onClick={() => onModeChange("month-end")}>月末视图</button></div></div>{visible ? <div className="ledger-chart mt-4 h-72 min-w-0"><ResponsiveContainer width="100%" height="100%"><LineChart data={rows} margin={{ left: 8, right: 16, top: 8, bottom: 0 }}><CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" /><XAxis dataKey="date" minTickGap={18} /><YAxis width={56} domain={["dataMin", "dataMax"]} tickFormatter={(value) => chartMoney(Number(value))} allowDataOverflow={false} /><Tooltip formatter={(value, name) => [formatValuation(Number(value), valuationCurrency), name]} /><Legend /><Line type="monotone" dataKey="净资产" stroke="var(--chart-primary)" strokeWidth={3} dot={mode === "month-end"} /><Line type="monotone" dataKey="资产" stroke="var(--chart-tertiary)" strokeWidth={2} dot={false} /><Line type="monotone" dataKey="负债" stroke="var(--chart-secondary)" strokeWidth={2} dot={false} /></LineChart></ResponsiveContainer></div> : <HiddenMoney />}</section>;
}

function HiddenMoney() {
  return <div className="mt-4 rounded-xl border border-line bg-panel p-6 text-center text-sm text-stone">此图包含具体金额，已隐藏。点击上方“显示金额”后查看。</div>;
}

function formatDelta(value: number | null | undefined, valuationCurrency: string) {
  if (value == null) return "暂无数据";
  return `${value >= 0 ? "+" : ""}${formatValuation(value / 100, valuationCurrency)}`;
}

function formatRatio(value: number | null | undefined) {
  if (value == null) return "暂无同比";
  return `${value >= 0 ? "+" : ""}${(value * 100).toFixed(1)}%`;
}

function tone(value: number | null | undefined) {
  return value == null ? "text-stone" : value >= 0 ? "amount-income" : "amount-expense";
}

type IncomeNode = NonNullable<IncomeStatementCache>["income"][number];
function sumTree(nodes: IncomeNode[], match: (account: string) => boolean): number {
  return nodes.reduce((sum, node) => sum + (match(`${node.account} ${node.label}`) ? node.amount : 0) + sumTree(node.children, match), 0);
}
