import { useMemo, useState, type ReactNode } from "react";
import { Eye, EyeOff } from "lucide-react";
import { Bar, BarChart, CartesianGrid, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { formatCompactValuation, formatValuation } from "@/lib/money";
import { formatAccountOptionLabel } from "./accountDisplay";
import type { AccountBalance, AccountView, NetWorthPoint, NetWorthWindows } from "./types";

type ChartRow = { date: string; 资产: number; 负债: number; 净资产: number };
type ViewMode = "daily" | "month-end";

export function NetWorthPage({ rows, monthEndRows, windows, accountBalances, accounts, valuationCurrency, visible, onToggleVisible }: { rows: ChartRow[]; monthEndRows: NetWorthPoint[]; windows: NetWorthWindows | null; accountBalances: AccountBalance[]; accounts: AccountView[]; valuationCurrency: string; visible: boolean; onToggleVisible: () => void }) {
  const [viewMode, setViewMode] = useState<ViewMode>("daily");
  const displayCurrency = accountBalances.find((row) => row.valuationCurrency)?.valuationCurrency ?? valuationCurrency;
  const valuationBalances = useMemo(() => valuationByAccount(accountBalances), [accountBalances]);
  const assets = Object.entries(valuationBalances).filter(([account]) => account.startsWith("Assets:")).reduce((sum, [, value]) => sum + value, 0);
  const liabilities = Object.entries(valuationBalances).filter(([account]) => account.startsWith("Liabilities:")).reduce((sum, [, value]) => sum + Math.abs(value), 0);
  const currentNetWorth = assets - liabilities;
  const debtRatio = assets > 0 ? liabilities / assets : null;
  const allocation = assetAllocation(accounts, valuationBalances);
  const assetAccounts = assetAccountRows(accounts, valuationBalances);
  const topThreeAssets = assetAccounts.slice(0, 3).reduce((sum, row) => sum + row.value, 0);
  const concentration = assets > 0 ? topThreeAssets / assets : null;
  const monthEndChart = useMemo(() => monthEndRows.map((row) => ({ date: row.date.slice(0, 7), 资产: row.assets / 100, 负债: row.liabilities / 100, 净资产: row.netWorth / 100 })), [monthEndRows]);
  const canUseMonthEnd = monthEndChart.length > 1;
  const chartRows = viewMode === "month-end" && canUseMonthEnd ? monthEndChart : rows;
  const mask = (value: string) => visible ? value : "••••••";

  return <div className="asset-workbench bg-panel">
    <section data-asset-section="position" className="border-b border-line">
      <AssetSectionIntro
        title="当前头寸"
        detail="这里只回答现在拥有什么、欠了多少，以及净资产处在什么位置。"
        action={<button type="button" className="inline-flex h-9 items-center gap-2 rounded-md border border-line bg-panel px-3 text-sm text-olive hover:bg-tag focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand" onClick={onToggleVisible} aria-label={visible ? "隐藏资产金额" : "显示资产金额"}>{visible ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}<span>{visible ? "隐藏金额" : "显示金额"}</span></button>}
      />
      <div className="grid gap-px bg-line sm:grid-cols-2 xl:grid-cols-4">
        <PositionMetric label="总资产" value={mask(formatValuation(assets / 100, displayCurrency))} detail={`${assetAccounts.length} 个有余额资产账户`} />
        <PositionMetric label="总负债" value={mask(formatValuation(liabilities / 100, displayCurrency))} detail="按负债账户绝对值汇总" />
        <PositionMetric label="净资产" value={mask(formatValuation(currentNetWorth / 100, displayCurrency))} detail="总资产减总负债" alert={visible && currentNetWorth < 0} primary />
        <PositionMetric label="负债率" value={visible ? debtRatio == null ? "暂无资产" : `${(debtRatio * 100).toFixed(1)}%` : "••••••"} detail="负债占总资产比例" alert={visible && debtRatio != null && debtRatio > 0.5} />
      </div>
      <div className="grid gap-px border-t border-line bg-line sm:grid-cols-2 xl:grid-cols-4">
        <WindowMetric label="本期变化" value={mask(formatDelta(windows?.monthChange, displayCurrency))} detail={windows?.previousMonthEnd ? `对比 ${windows.previousMonthEnd.date}` : "暂无月末基准"} />
        <WindowMetric label="近 6 月" value={mask(formatDelta(windows?.sixMonth.change, displayCurrency))} detail={visible ? formatRatio(windows?.sixMonth.changeRatio) : "变化率已隐藏"} />
        <WindowMetric label="近 12 月" value={mask(formatDelta(windows?.twelveMonth.change, displayCurrency))} detail={visible ? formatRatio(windows?.twelveMonth.changeRatio) : "变化率已隐藏"} />
        <WindowMetric label="前三账户集中度" value={visible ? concentration == null ? "暂无资产" : `${(concentration * 100).toFixed(1)}%` : "••••••"} detail="用于判断资产是否过度集中" />
      </div>
    </section>

    <section data-asset-section="structure" className="border-b border-line">
      <AssetSectionIntro title="资产结构" detail="先按用途看资产分层，再查看具体账户集中在哪里。" />
      <div className="grid border-t border-line xl:grid-cols-[minmax(18rem,0.75fr)_minmax(0,1.25fr)]">
        <AssetPanel title="用途分层" detail="现金、投资、应收与其他资产" className="border-b border-line xl:border-b-0 xl:border-r">
          <AssetAllocation rows={allocation} liabilities={liabilities} assets={assets} visible={visible} valuationCurrency={displayCurrency} />
        </AssetPanel>
        <AssetPanel title="账户集中度" detail={`按估值金额展示前 ${Math.min(assetAccounts.length, 8)} 个资产账户`}>
          <AssetComposition rows={assetAccounts} visible={visible} valuationCurrency={displayCurrency} />
        </AssetPanel>
      </div>
    </section>

    <section data-asset-section="movement">
      <AssetSectionIntro title="净值变化" detail="资产页只保留一张核心趋势图，用同一时间轴观察资产、负债和净资产。" />
      <div className="border-t border-line">
        <NetWorthChart rows={chartRows} visible={visible} mode={viewMode} canUseMonthEnd={canUseMonthEnd} valuationCurrency={displayCurrency} onModeChange={setViewMode} />
      </div>
    </section>
  </div>;
}

function AssetSectionIntro({ title, detail, action }: { title: string; detail: string; action?: ReactNode }) {
  return <div className="flex min-h-24 items-start justify-between gap-5 px-4 py-5 md:px-6 xl:px-8"><div className="min-w-0"><h2 className="text-lg font-semibold tracking-[-0.018em] text-ink">{title}</h2><p className="mt-1 text-sm leading-5 text-stone">{detail}</p></div>{action}</div>;
}

function PositionMetric({ label, value, detail, alert = false, primary = false }: { label: string; value: string; detail: string; alert?: boolean; primary?: boolean }) {
  return <div className={`min-w-0 bg-panel px-4 py-4 md:px-5 xl:px-6 ${primary ? "sm:col-span-2 xl:col-span-1" : ""}`}><div className="text-[11px] font-semibold text-stone">{label}</div><div data-asset-position-value="true" className={`mt-2 max-w-full whitespace-nowrap font-semibold tracking-[-0.03em] tabular-nums ${amountSizeClass(value)} ${alert ? "amount-danger" : "text-ink"}`} title={value}>{value}</div><div className="mt-3 text-xs text-stone">{detail}</div></div>;
}

function WindowMetric({ label, value, detail }: { label: string; value: string; detail: string }) {
  return <div className="min-w-0 bg-panel px-4 py-3.5 md:px-6"><div className="text-[11px] font-semibold text-stone">{label}</div><div className="mt-1 whitespace-nowrap text-base font-semibold tabular-nums text-ink">{value}</div><div className="mt-1.5 text-xs text-stone">{detail}</div></div>;
}

function AssetPanel({ title, detail, className = "", children }: { title: string; detail: string; className?: string; children: ReactNode }) {
  return <section className={`min-w-0 bg-panel ${className}`}><div className="min-h-[4.5rem] border-b border-line px-4 py-3.5 md:px-6"><h3 className="text-base font-semibold tracking-[-0.015em] text-ink">{title}</h3><p className="mt-1.5 text-xs leading-5 text-stone">{detail}</p></div>{children}</section>;
}

function valuationByAccount(rows: AccountBalance[]): Record<string, number> {
  const output: Record<string, number> = {};
  for (const row of rows) {
    if (row.valuationMissing) continue;
    output[row.account] = (output[row.account] ?? 0) + row.valuation;
  }
  return output;
}

function assetAllocation(accounts: AccountView[], balances: Record<string, number>) {
  const knownAccounts = new Set(accounts.map((account) => account.account));
  const bucket = (match: (account: AccountView) => boolean) => accounts.filter((account) => account.account.startsWith("Assets:") && match(account)).reduce((sum, account) => sum + (balances[account.account] ?? 0), 0);
  const cash = bucket((account) => account.group === "cash");
  const wealth = bucket((account) => account.group === "wealth");
  const receivable = bucket((account) => account.group === "receivable");
  const other = Object.entries(balances).filter(([account]) => account.startsWith("Assets:") && !knownAccounts.has(account)).reduce((sum, [, value]) => sum + value, 0) + bucket((account) => !["cash", "wealth", "receivable"].includes(account.group));
  return [{ label: "现金与活期", value: cash }, { label: "理财与投资", value: wealth }, { label: "应收款项", value: receivable }, { label: "其他资产", value: other }].filter((row) => row.value !== 0);
}

function assetAccountRows(accounts: AccountView[], balances: Record<string, number>) {
  const accountByName = new Map(accounts.map((account) => [account.account, account]));
  return Object.entries(balances)
    .filter(([account]) => account.startsWith("Assets:"))
    .map(([accountName, balance]) => {
      const account = accountByName.get(accountName);
      return { account: accountName, label: account ? formatAccountOptionLabel(account.account, account.label, account.alias) : accountName.split(":").at(-1) || accountName, value: Math.max(0, balance) };
    })
    .filter((row) => row.value > 0)
    .sort((left, right) => right.value - left.value);
}

function AssetAllocation({ rows, liabilities, assets, visible, valuationCurrency }: { rows: { label: string; value: number }[]; liabilities: number; assets: number; visible: boolean; valuationCurrency: string }) {
  const totalAssets = Math.max(1, assets);
  const debtRatio = liabilities / totalAssets;
  return <div className="divide-y divide-line">
    {rows.length ? rows.map((row) => {
      const ratio = row.value / totalAssets;
      return <div key={row.label} className="px-4 py-3 md:px-6"><div className="flex items-center justify-between gap-3"><span className="text-sm text-ink">{row.label}</span><span className="whitespace-nowrap text-sm font-semibold tabular-nums text-ink">{visible ? `${(ratio * 100).toFixed(1)}% · ${formatCompactValuation(row.value / 100, valuationCurrency)}` : "••••••"}</span></div><div className="mt-2 h-1 bg-line"><div className="h-full bg-brand" style={{ width: visible ? `${Math.min(Math.max(ratio * 100, 2), 100)}%` : "0%" }} /></div></div>;
    }) : <ChartEmpty text="暂无可展示的资产分层" />}
    <div className="px-4 py-3 md:px-6"><div className="flex items-center justify-between gap-3"><span className="text-sm text-ink">负债 / 总资产</span><span className="whitespace-nowrap text-sm font-semibold tabular-nums text-ink">{visible ? `${(debtRatio * 100).toFixed(1)}% · ${formatCompactValuation(liabilities / 100, valuationCurrency)}` : "••••••"}</span></div><div className="mt-2 h-1 bg-line"><div className={`h-full ${debtRatio > 0.5 ? "bg-[var(--danger)]" : "bg-stone"}`} style={{ width: visible ? `${Math.min(Math.max(debtRatio * 100, liabilities ? 2 : 0), 100)}%` : "0%" }} /></div></div>
  </div>;
}

function AssetComposition({ rows, visible, valuationCurrency }: { rows: { account: string; label: string; value: number }[]; visible: boolean; valuationCurrency: string }) {
  const chartRows = rows.slice(0, 8).map((row) => ({ name: row.label, value: row.value / 100 }));
  if (!visible) return <HiddenMoney />;
  if (!chartRows.length) return <ChartEmpty text="暂无可展示的资产余额" />;
  return <div className="ledger-chart h-[19rem] px-2 pb-3 pt-2 md:h-[22rem]"><ResponsiveContainer width="100%" height="100%"><BarChart layout="vertical" data={chartRows} margin={{ left: 8, right: 20, top: 6, bottom: 0 }} barCategoryGap="34%"><CartesianGrid stroke="var(--chart-grid)" strokeOpacity={0.72} horizontal={false} /><XAxis type="number" tick={chartTick} tickLine={false} axisLine={{ stroke: "var(--line)" }} tickFormatter={chartMoney} /><YAxis type="category" dataKey="name" width={112} tick={chartTick} tickLine={false} axisLine={false} tickFormatter={compactAssetLabel} /><Tooltip contentStyle={chartTooltipStyle} cursor={{ fill: "var(--tag)" }} formatter={(value) => [formatValuation(Number(value), valuationCurrency), "资产"]} /><Bar dataKey="value" fill="var(--chart-primary)" radius={0} maxBarSize={12} /></BarChart></ResponsiveContainer></div>;
}

function NetWorthChart({ rows, visible, mode, canUseMonthEnd, valuationCurrency, onModeChange }: { rows: ChartRow[]; visible: boolean; mode: ViewMode; canUseMonthEnd: boolean; valuationCurrency: string; onModeChange: (mode: ViewMode) => void }) {
  const effectiveMode = mode === "month-end" && canUseMonthEnd ? "month-end" : "daily";
  return <section className="bg-panel"><div className="flex flex-col gap-3 border-b border-line px-4 py-3 sm:flex-row sm:items-center sm:justify-between md:px-6 xl:px-8"><div className="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-stone"><ChartKey label="净资产" className="bg-brand" /><ChartKey label="总资产" className="bg-ink" /><ChartKey label="总负债" className="bg-stone" dashed /></div><div className="inline-flex self-start border border-line bg-panel p-0.5 text-xs"><button type="button" className={`px-3 py-1.5 ${effectiveMode === "daily" ? "bg-brand text-primary-foreground" : "text-olive hover:bg-tag"}`} onClick={() => onModeChange("daily")}>日视图</button><button type="button" className={`px-3 py-1.5 ${effectiveMode === "month-end" ? "bg-brand text-primary-foreground" : "text-olive hover:bg-tag"} disabled:cursor-not-allowed disabled:opacity-45`} onClick={() => onModeChange("month-end")} disabled={!canUseMonthEnd}>月末视图</button></div></div>{visible ? rows.length ? <div className="ledger-chart h-[20rem] min-w-0 px-2 pb-3 pt-2 md:h-[24rem]"><ResponsiveContainer width="100%" height="100%"><LineChart data={rows} margin={{ left: 8, right: 16, top: 8, bottom: 0 }}><CartesianGrid stroke="var(--chart-grid)" strokeOpacity={0.72} vertical={false} /><XAxis dataKey="date" minTickGap={18} tick={chartTick} tickLine={false} axisLine={{ stroke: "var(--line)" }} /><YAxis width={60} domain={["dataMin", "dataMax"]} tick={chartTick} tickLine={false} axisLine={false} tickFormatter={(value) => chartMoney(Number(value))} allowDataOverflow={false} /><Tooltip contentStyle={chartTooltipStyle} formatter={(value, name) => [formatValuation(Number(value), valuationCurrency), name]} /><Line type="linear" dataKey="净资产" stroke="var(--chart-primary)" strokeWidth={2} dot={false} activeDot={{ r: 3, strokeWidth: 0 }} /><Line type="linear" dataKey="资产" stroke="var(--ink)" strokeWidth={1.4} dot={false} activeDot={{ r: 3, strokeWidth: 0 }} /><Line type="linear" dataKey="负债" stroke="var(--stone)" strokeWidth={1.3} strokeDasharray="5 4" dot={false} activeDot={{ r: 3, strokeWidth: 0 }} /></LineChart></ResponsiveContainer></div> : <ChartEmpty text="暂无净资产趋势数据" /> : <HiddenMoney />}</section>;
}

function ChartKey({ label, className, dashed = false }: { label: string; className: string; dashed?: boolean }) {
  return <span className="inline-flex items-center gap-1.5"><span className={`h-px w-5 ${className} ${dashed ? "border-t border-dashed border-stone bg-transparent" : ""}`} />{label}</span>;
}

function chartMoney(value: number) {
  return new Intl.NumberFormat("en-US", { notation: "compact", compactDisplay: "short", maximumFractionDigits: 1 }).format(value);
}

function ChartEmpty({ text }: { text: string }) {
  return <div className="grid min-h-48 place-items-center px-4 text-sm text-stone">{text}</div>;
}

function HiddenMoney() {
  return <div className="grid min-h-48 place-items-center px-6 text-center text-sm text-stone">此区域包含具体金额，点击“显示金额”后查看。</div>;
}

function compactAssetLabel(value: string) {
  return value.length > 16 ? `${value.slice(0, 15)}…` : value;
}

const chartTick = { fill: "var(--stone)", fontSize: 11 };
const chartTooltipStyle = { background: "var(--ivory)", border: "1px solid var(--line)", borderRadius: 4, color: "var(--ink)", boxShadow: "0 10px 28px oklch(0.20 0.012 255 / 0.14)" };

function formatDelta(value: number | null | undefined, valuationCurrency: string) {
  if (value == null) return "暂无数据";
  return `${value >= 0 ? "+" : ""}${formatValuation(value / 100, valuationCurrency)}`;
}

function formatRatio(value: number | null | undefined) {
  if (value == null) return "暂无变化率";
  return `${value >= 0 ? "+" : ""}${(value * 100).toFixed(1)}%`;
}

function amountSizeClass(value: string) {
  if (value.length > 20) return "text-[0.78rem] sm:text-sm";
  if (value.length > 16) return "text-sm sm:text-base";
  if (value.length > 12) return "text-base sm:text-lg";
  return "text-[clamp(1.15rem,2vw,1.75rem)]";
}
