import { useMemo, useState, type ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { Eye, EyeOff } from "lucide-react";
import { Bar, BarChart, CartesianGrid, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { formatCompactValuation, formatValuation } from "@/lib/money";
import { formatAccountOptionLabel } from "./accountDisplay";
import { PeriodComparisonRows } from "./PeriodComparisonRows";
import type { AccountBalance, AccountView, MetricPeriodComparisons, NetWorthPoint, NetWorthWindows } from "./types";

type ChartRow = { date: string; assets: number; liabilities: number; netWorth: number };
type ViewMode = "daily" | "month-end";

export function NetWorthPage({ rows, monthEndRows, windows, accountBalances, accounts, comparisons = null, valuationCurrency, visible, onToggleVisible }: { rows: ChartRow[]; monthEndRows: NetWorthPoint[]; windows: NetWorthWindows | null; accountBalances: AccountBalance[]; accounts: AccountView[]; comparisons?: MetricPeriodComparisons | null; valuationCurrency: string; visible: boolean; onToggleVisible: () => void }) {
  const { t } = useTranslation();
  const [viewMode, setViewMode] = useState<ViewMode>("daily");
  const displayCurrency = accountBalances.find((row) => row.valuationCurrency)?.valuationCurrency ?? valuationCurrency;
  const valuationBalances = useMemo(() => valuationByAccount(accountBalances), [accountBalances]);
  const assets = Object.entries(valuationBalances).filter(([account]) => account.startsWith("Assets:")).reduce((sum, [, value]) => sum + value, 0);
  const liabilities = Object.entries(valuationBalances).filter(([account]) => account.startsWith("Liabilities:")).reduce((sum, [, value]) => sum + Math.abs(value), 0);
  const currentNetWorth = assets - liabilities;
  const debtRatio = assets > 0 ? liabilities / assets : null;
  const allocation = assetAllocation(accounts, valuationBalances, t);
  const assetAccounts = assetAccountRows(accounts, valuationBalances);
  const topThreeAssets = assetAccounts.slice(0, 3).reduce((sum, row) => sum + row.value, 0);
  const concentration = assets > 0 ? topThreeAssets / assets : null;
  const monthEndChart = useMemo(() => monthEndRows.map((row) => ({ date: row.date.slice(0, 7), assets: row.assets / 100, liabilities: row.liabilities / 100, netWorth: row.netWorth / 100 })), [monthEndRows]);
  const canUseMonthEnd = monthEndChart.length > 1;
  const chartRows = viewMode === "month-end" && canUseMonthEnd ? monthEndChart : rows;
  const mask = (value: string) => visible ? value : "••••••";

  return <div className="asset-workbench bg-panel">
    <section data-asset-section="position" className="border-b border-line">
      <AssetSectionIntro
        title={t("netWorth.currentPosition")}
        detail={t("netWorth.currentPositionDetail")}
        action={<button type="button" className="inline-flex h-9 items-center gap-2 rounded-md border border-line bg-panel px-3 text-sm text-olive hover:bg-tag focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand" onClick={onToggleVisible} aria-label={visible ? t("netWorth.hideAssetAmounts") : t("netWorth.showAssetAmounts")}>{visible ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}<span>{visible ? t("netWorth.hideAmounts") : t("netWorth.showAmounts")}</span></button>}
      />
      <div className="grid gap-px bg-line sm:grid-cols-2 xl:grid-cols-4">
        <PositionMetric label={t("netWorth.totalAssets")} value={mask(formatValuation(assets / 100, displayCurrency))} detail={<><div>{t("netWorth.assetAccountsCount", { count: assetAccounts.length })}</div>{comparisons && <PeriodComparisonRows comparisons={comparisons} metric="totalAssets" currency={displayCurrency} hidden={!visible} />}</>} />
        <PositionMetric label={t("netWorth.totalLiabilities")} value={mask(formatValuation(liabilities / 100, displayCurrency))} detail={t("netWorth.liabilitiesAbsolute")} />
        <PositionMetric label={t("netWorth.netWorth")} value={mask(formatValuation(currentNetWorth / 100, displayCurrency))} detail={t("netWorth.assetsMinusLiabilities")} alert={visible && currentNetWorth < 0} primary />
        <PositionMetric label={t("netWorth.debtRatio")} value={visible ? debtRatio == null ? t("netWorth.noAssets") : `${(debtRatio * 100).toFixed(1)}%` : "••••••"} detail={t("netWorth.liabilitiesToAssets")} alert={visible && debtRatio != null && debtRatio > 0.5} />
      </div>
      <div className="grid gap-px border-t border-line bg-line sm:grid-cols-2 xl:grid-cols-4">
        <WindowMetric label={t("netWorth.periodChange")} value={mask(formatDelta(windows?.monthChange, displayCurrency, t))} detail={windows?.previousMonthEnd ? t("netWorth.compareTo", { date: windows.previousMonthEnd.date }) : t("netWorth.noMonthEndBaseline")} />
        <WindowMetric label={t("netWorth.last6Months")} value={mask(formatDelta(windows?.sixMonth.change, displayCurrency, t))} detail={visible ? formatRatio(windows?.sixMonth.changeRatio, t) : t("netWorth.changeRateHidden")} />
        <WindowMetric label={t("netWorth.last12Months")} value={mask(formatDelta(windows?.twelveMonth.change, displayCurrency, t))} detail={visible ? formatRatio(windows?.twelveMonth.changeRatio, t) : t("netWorth.changeRateHidden")} />
        <WindowMetric label={t("netWorth.top3Concentration")} value={visible ? concentration == null ? t("netWorth.noAssets") : `${(concentration * 100).toFixed(1)}%` : "••••••"} detail={t("netWorth.concentrationPurpose")} />
      </div>
    </section>

    <section data-asset-section="structure" className="border-b border-line">
      <AssetSectionIntro title={t("netWorth.assetStructure")} detail={t("netWorth.assetStructureDetail")} />
      <div className="grid border-t border-line xl:grid-cols-[minmax(18rem,0.75fr)_minmax(0,1.25fr)]">
        <AssetPanel title={t("netWorth.usageLayers")} detail={t("netWorth.usageLayersDetail")} className="border-b border-line xl:border-b-0 xl:border-r">
          <AssetAllocation rows={allocation} liabilities={liabilities} assets={assets} visible={visible} valuationCurrency={displayCurrency} t={t} />
        </AssetPanel>
        <AssetPanel title={t("netWorth.accountConcentration")} detail={t("netWorth.topAssetAccounts", { count: Math.min(assetAccounts.length, 8) })}>
          <AssetComposition rows={assetAccounts} visible={visible} valuationCurrency={displayCurrency} t={t} />
        </AssetPanel>
      </div>
    </section>

    <section data-asset-section="movement">
      <AssetSectionIntro title={t("netWorth.netWorthChange")} detail={t("netWorth.netWorthChangeDetail")} />
      <div className="border-t border-line">
        <NetWorthChart rows={chartRows} visible={visible} mode={viewMode} canUseMonthEnd={canUseMonthEnd} valuationCurrency={displayCurrency} onModeChange={setViewMode} t={t} />
      </div>
    </section>
  </div>;
}

function AssetSectionIntro({ title, detail, action }: { title: string; detail: string; action?: ReactNode }) {
  return <div className="flex min-h-24 items-start justify-between gap-5 px-4 py-5 md:px-6 xl:px-8"><div className="min-w-0"><h2 className="text-lg font-semibold tracking-[-0.018em] text-ink">{title}</h2><p className="mt-1 text-sm leading-5 text-stone">{detail}</p></div>{action}</div>;
}

function PositionMetric({ label, value, detail, alert = false, primary = false }: { label: string; value: string; detail: ReactNode; alert?: boolean; primary?: boolean }) {
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

function assetAllocation(accounts: AccountView[], balances: Record<string, number>, t: (key: string) => string) {
  const knownAccounts = new Set(accounts.map((account) => account.account));
  const bucket = (match: (account: AccountView) => boolean) => accounts.filter((account) => account.account.startsWith("Assets:") && match(account)).reduce((sum, account) => sum + (balances[account.account] ?? 0), 0);
  const cash = bucket((account) => account.group === "cash");
  const wealth = bucket((account) => account.group === "wealth");
  const receivable = bucket((account) => account.group === "receivable");
  const other = Object.entries(balances).filter(([account]) => account.startsWith("Assets:") && !knownAccounts.has(account)).reduce((sum, [, value]) => sum + value, 0) + bucket((account) => !["cash", "wealth", "receivable"].includes(account.group));
  return [
    { label: t("netWorth.cashAndDeposits"), value: cash },
    { label: t("netWorth.wealthAndInvestments"), value: wealth },
    { label: t("netWorth.receivables"), value: receivable },
    { label: t("netWorth.otherAssets"), value: other },
  ].filter((row) => row.value !== 0);
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

function AssetAllocation({ rows, liabilities, assets, visible, valuationCurrency, t }: { rows: { label: string; value: number }[]; liabilities: number; assets: number; visible: boolean; valuationCurrency: string; t: (key: string) => string }) {
  const totalAssets = Math.max(1, assets);
  const debtRatio = liabilities / totalAssets;
  return <div className="divide-y divide-line">
    {rows.length ? rows.map((row) => {
      const ratio = row.value / totalAssets;
      return <div key={row.label} className="px-4 py-3 md:px-6"><div className="flex items-center justify-between gap-3"><span className="text-sm text-ink">{row.label}</span><span className="whitespace-nowrap text-sm font-semibold tabular-nums text-ink">{visible ? `${(ratio * 100).toFixed(1)}% · ${formatCompactValuation(row.value / 100, valuationCurrency)}` : "••••••"}</span></div><div className="mt-2 h-1 bg-line"><div className="h-full bg-brand" style={{ width: visible ? `${Math.min(Math.max(ratio * 100, 2), 100)}%` : "0%" }} /></div></div>;
    }) : <ChartEmpty text={t("netWorth.noAssetLayers")} />}
    <div className="px-4 py-3 md:px-6"><div className="flex items-center justify-between gap-3"><span className="text-sm text-ink">{t("netWorth.liabilitiesOverAssets")}</span><span className="whitespace-nowrap text-sm font-semibold tabular-nums text-ink">{visible ? `${(debtRatio * 100).toFixed(1)}% · ${formatCompactValuation(liabilities / 100, valuationCurrency)}` : "••••••"}</span></div><div className="mt-2 h-1 bg-line"><div className={`h-full ${debtRatio > 0.5 ? "bg-[var(--danger)]" : "bg-stone"}`} style={{ width: visible ? `${Math.min(Math.max(debtRatio * 100, liabilities ? 2 : 0), 100)}%` : "0%" }} /></div></div>
  </div>;
}

function AssetComposition({ rows, visible, valuationCurrency, t }: { rows: { account: string; label: string; value: number }[]; visible: boolean; valuationCurrency: string; t: (key: string) => string }) {
  const chartRows = rows.slice(0, 8).map((row) => ({ name: row.label, value: row.value / 100 }));
  if (!visible) return <HiddenMoney t={t} />;
  if (!chartRows.length) return <ChartEmpty text={t("netWorth.noAssetBalances")} />;
  return <div className="ledger-chart h-[19rem] px-2 pb-3 pt-2 md:h-[22rem]"><ResponsiveContainer width="100%" height="100%"><BarChart layout="vertical" data={chartRows} margin={{ left: 8, right: 20, top: 6, bottom: 0 }} barCategoryGap="34%"><CartesianGrid stroke="var(--chart-grid)" strokeOpacity={0.72} horizontal={false} /><XAxis type="number" tick={chartTick} tickLine={false} axisLine={{ stroke: "var(--line)" }} tickFormatter={chartMoney} /><YAxis type="category" dataKey="name" width={112} tick={chartTick} tickLine={false} axisLine={false} tickFormatter={compactAssetLabel} /><Tooltip contentStyle={chartTooltipStyle} cursor={{ fill: "var(--tag)" }} formatter={(value) => [formatValuation(Number(value), valuationCurrency), t("netWorth.assetsSeries")]} /><Bar dataKey="value" fill="var(--chart-primary)" radius={0} maxBarSize={12} /></BarChart></ResponsiveContainer></div>;
}

function NetWorthChart({ rows, visible, mode, canUseMonthEnd, valuationCurrency, onModeChange, t }: { rows: ChartRow[]; visible: boolean; mode: ViewMode; canUseMonthEnd: boolean; valuationCurrency: string; onModeChange: (mode: ViewMode) => void; t: (key: string) => string }) {
  const effectiveMode = mode === "month-end" && canUseMonthEnd ? "month-end" : "daily";
  const seriesNames: Record<string, string> = {
    netWorth: t("netWorth.netWorthSeries"),
    assets: t("netWorth.assetsSeries"),
    liabilities: t("netWorth.liabilitiesSeries"),
  };
  return <section className="bg-panel"><div className="flex flex-col gap-3 border-b border-line px-4 py-3 sm:flex-row sm:items-center sm:justify-between md:px-6 xl:px-8"><div className="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-stone"><ChartKey label={t("netWorth.netWorthSeries")} className="bg-brand" /><ChartKey label={t("netWorth.assetsSeries")} className="bg-ink" /><ChartKey label={t("netWorth.liabilitiesSeries")} className="bg-stone" dashed /></div><div className="inline-flex self-start border border-line bg-panel p-0.5 text-xs"><button type="button" className={`px-3 py-1.5 ${effectiveMode === "daily" ? "bg-brand text-primary-foreground" : "text-olive hover:bg-tag"}`} onClick={() => onModeChange("daily")}>{t("netWorth.dailyView")}</button><button type="button" className={`px-3 py-1.5 ${effectiveMode === "month-end" ? "bg-brand text-primary-foreground" : "text-olive hover:bg-tag"} disabled:cursor-not-allowed disabled:opacity-45`} onClick={() => onModeChange("month-end")} disabled={!canUseMonthEnd}>{t("netWorth.monthEndView")}</button></div></div>{visible ? rows.length ? <div className="ledger-chart h-[20rem] min-w-0 px-2 pb-3 pt-2 md:h-[24rem]"><ResponsiveContainer width="100%" height="100%"><LineChart data={rows} margin={{ left: 8, right: 16, top: 8, bottom: 0 }}><CartesianGrid stroke="var(--chart-grid)" strokeOpacity={0.72} vertical={false} /><XAxis dataKey="date" minTickGap={18} tick={chartTick} tickLine={false} axisLine={{ stroke: "var(--line)" }} /><YAxis width={60} domain={["dataMin", "dataMax"]} tick={chartTick} tickLine={false} axisLine={false} tickFormatter={(value) => chartMoney(Number(value))} allowDataOverflow={false} /><Tooltip contentStyle={chartTooltipStyle} formatter={(value, name) => [formatValuation(Number(value), valuationCurrency), seriesNames[String(name)] ?? String(name)]} /><Line type="linear" dataKey="netWorth" stroke="var(--chart-primary)" strokeWidth={2} dot={false} activeDot={{ r: 3, strokeWidth: 0 }} /><Line type="linear" dataKey="assets" stroke="var(--ink)" strokeWidth={1.4} dot={false} activeDot={{ r: 3, strokeWidth: 0 }} /><Line type="linear" dataKey="liabilities" stroke="var(--stone)" strokeWidth={1.3} strokeDasharray="5 4" dot={false} activeDot={{ r: 3, strokeWidth: 0 }} /></LineChart></ResponsiveContainer></div> : <ChartEmpty text={t("netWorth.noNetWorthTrend")} /> : <HiddenMoney t={t} />}</section>;
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

function HiddenMoney({ t }: { t: (key: string) => string }) {
  return <div className="grid min-h-48 place-items-center px-6 text-center text-sm text-stone">{t("netWorth.hiddenMoney")}</div>;
}

function compactAssetLabel(value: string) {
  return value.length > 16 ? `${value.slice(0, 15)}…` : value;
}

const chartTick = { fill: "var(--stone)", fontSize: 11 };
const chartTooltipStyle = { background: "var(--ivory)", border: "1px solid var(--line)", borderRadius: 4, color: "var(--ink)", boxShadow: "0 10px 28px oklch(0.20 0.012 255 / 0.14)" };

function formatDelta(value: number | null | undefined, valuationCurrency: string, t: (key: string) => string) {
  if (value == null) return t("netWorth.noData");
  return `${value >= 0 ? "+" : ""}${formatValuation(value / 100, valuationCurrency)}`;
}

function formatRatio(value: number | null | undefined, t: (key: string) => string) {
  if (value == null) return t("netWorth.noChangeRate");
  return `${value >= 0 ? "+" : ""}${(value * 100).toFixed(1)}%`;
}

function amountSizeClass(value: string) {
  if (value.length > 20) return "text-[0.78rem] sm:text-sm";
  if (value.length > 16) return "text-sm sm:text-base";
  if (value.length > 12) return "text-base sm:text-lg";
  return "text-[clamp(1.15rem,2vw,1.75rem)]";
}
