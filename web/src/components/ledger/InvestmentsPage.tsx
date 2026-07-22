import { formatCny, formatCompactCny, formatMoney } from "@/lib/money";
import { ChevronDown, LineChart as LineChartIcon, Search, SlidersHorizontal } from "lucide-react";
import { useMemo, useState, type ReactNode } from "react";
import { Area, AreaChart, CartesianGrid, Line, LineChart, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { ResponsiveValueRow } from "./shared";
import type { CommodityPrice, InvestmentHolding, InvestmentLot, InvestmentPosition, InvestmentQuote, InvestmentRealizedTrade, InvestmentSummary } from "./types";

type PricePoint = { date: string; price: number };
type PortfolioPoint = { date: string; value: number };
type MoneyValue = { value: number; currency: string };
type InstitutionOption = { key: string; label: string; holdingCount: number; positionCount: number; totalMarketValueCny: number };
type InstitutionGroup = InstitutionOption & { holdings: InvestmentHolding[] };
type SortKey = "market" | "profit" | "change";
type HoldingView = "open" | "closed";

const allocationColors = ["var(--chart-palette-1)", "var(--chart-palette-2)", "var(--chart-palette-4)", "var(--chart-palette-5)", "var(--chart-palette-6)"];
const regionAccountSegments = new Set(["CN", "HK", "US", "JP", "SG", "EU", "UK", "TW"]);
const commonInstitutionLabels: Record<string, string> = {
  Broker: "券商",
  CMB: "招商证券",
  HSBC: "汇丰",
  ZABank: "众安银行",
  ZA: "众安",
};

export function InvestmentsPage({ investments }: { investments: InvestmentSummary | null }) {
  const holdings = useMemo(() => investmentHoldings(investments), [investments]);
  const closedHoldings = useMemo(() => investmentClosedHoldings(investments), [investments]);
  const institutionGroups = useMemo(() => investmentInstitutionGroups(holdings), [holdings]);
  const closedInstitutionGroups = useMemo(() => investmentInstitutionGroups(closedHoldings), [closedHoldings]);
  const institutionOptions = useMemo(() => mergeInstitutionOptions(institutionGroups, closedInstitutionGroups), [institutionGroups, closedInstitutionGroups]);
  const [selectedInstitution, setSelectedInstitution] = useState("all");
  const [holdingView, setHoldingView] = useState<HoldingView>("open");
  const [query, setQuery] = useState("");
  const [sortKey, setSortKey] = useState<SortKey>("market");
  const [openHolding, setOpenHolding] = useState<string | null | undefined>(undefined);

  const scopedOpenGroups = useMemo(() => {
    if (selectedInstitution === "all") return institutionGroups;
    return institutionGroups.filter((group) => group.key === selectedInstitution);
  }, [institutionGroups, selectedInstitution]);
  const scopedClosedGroups = useMemo(() => {
    if (selectedInstitution === "all") return closedInstitutionGroups;
    return closedInstitutionGroups.filter((group) => group.key === selectedInstitution);
  }, [closedInstitutionGroups, selectedInstitution]);
  const scopedGroups = holdingView === "closed" ? scopedClosedGroups : scopedOpenGroups;
  const heldHoldings = useMemo(() => scopedOpenGroups.flatMap((group) => group.holdings).filter((holding) => Math.abs(holding.totalQuantity) > 0), [scopedOpenGroups]);
  const realizedHoldings = useMemo(() => [...scopedOpenGroups, ...scopedClosedGroups].flatMap((group) => group.holdings).filter((holding) => (holding.realizedTrades?.length ?? 0) > 0), [scopedOpenGroups, scopedClosedGroups]);
  const visibleGroups = useMemo(() => scopedGroups.map((group) => ({
    ...group,
    holdings: sortHoldings(filterHoldings(group.holdings, query), sortKey),
  })).filter((group) => group.holdings.length > 0), [scopedGroups, query, sortKey]);
  const visibleHoldingCount = visibleGroups.reduce((total, group) => total + group.holdings.length, 0);
  const openHoldingCount = scopedOpenGroups.reduce((total, group) => total + group.holdings.length, 0);
  const closedHoldingCount = scopedClosedGroups.reduce((total, group) => total + group.holdings.length, 0);

  const totalMarketValueCny = sumCnyValues(heldHoldings, "totalMarketValueCny");
  const latestDate = latestPriceDate(heldHoldings) || investments?.updatedAt || "";
  const costSummary = summarizeHoldingCosts(heldHoldings);
  const profitSummary = summarizeHoldingProfit(heldHoldings);
  const realizedSummary = summarizeRealizedProfit(realizedHoldings);
  const dailySummary = summarizeDailyChange(heldHoldings);
  const portfolioSeries = useMemo(() => portfolioPriceSeries(heldHoldings, 30), [heldHoldings]);
  const allocationRows = useMemo(() => selectedInstitution === "all"
    ? scopedOpenGroups.map((group) => ({ label: group.label, value: group.totalMarketValueCny }))
    : heldHoldings.map((holding) => ({ label: holding.commodity, value: holding.totalMarketValueCny ?? 0 })), [heldHoldings, scopedOpenGroups, selectedInstitution]);
  const defaultOpenHolding = visibleGroups[0]?.holdings[0] ? `${visibleGroups[0].key}:${visibleGroups[0].holdings[0].commodity}` : null;
  const activeOpenHolding = openHolding === undefined ? defaultOpenHolding : openHolding;

  return (
    <div className="space-y-4 sm:space-y-5">
      <InstitutionTabs options={institutionOptions} selected={selectedInstitution} onChange={setSelectedInstitution} />

      <PortfolioOverview
        totalMarketValueCny={totalMarketValueCny}
        latestDate={latestDate}
        costSummary={costSummary}
        profitSummary={profitSummary}
        realizedSummary={realizedSummary}
        dailySummary={dailySummary}
        holdingCount={heldHoldings.length}
        closedHoldingCount={closedHoldingCount}
        institutionCount={selectedInstitution === "all" ? institutionOptions.length : (scopedOpenGroups.length || scopedClosedGroups.length ? 1 : 0)}
        series={portfolioSeries}
      />

      <AllocationBar rows={allocationRows} totalMarketValueCny={totalMarketValueCny} mode={selectedInstitution === "all" ? "institution" : "security"} />

      <section className="overflow-hidden rounded-[14px] border border-line bg-panel">
        <div className="flex flex-col gap-3 border-b border-line px-4 py-4 sm:px-5 lg:flex-row lg:items-center lg:justify-between">
          <div>
            <div className="flex items-center gap-2">
              <h2 className="font-serif text-xl font-medium text-ink">持仓明细</h2>
              <span className="ledger-chip rounded-full px-2 py-1 text-xs">{visibleHoldingCount} 只</span>
            </div>
            <p className="mt-1 text-xs text-stone">{holdingView === "closed" ? "已清仓列表展示卖出后的已实现盈亏。" : "按机构账户分组，市值统一折算为 CNY，今日涨跌按最新两条证券价格估算。"}</p>
          </div>
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            <HoldingViewTabs view={holdingView} openCount={openHoldingCount} closedCount={closedHoldingCount} onChange={setHoldingView} />
            <label className="relative min-w-0 sm:w-56">
              <span className="sr-only">搜索持仓</span>
              <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-stone" />
              <input
                type="search"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="搜索股票或代码"
                className="h-10 w-full rounded-[10px] border border-line bg-paper pl-9 pr-3 text-sm text-ink outline-none transition-colors placeholder:text-stone focus:border-brand focus:ring-2 focus:ring-[var(--focus-ring)]"
              />
            </label>
            <label className="relative">
              <span className="sr-only">持仓排序</span>
              <SlidersHorizontal className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-stone" />
              <select
                value={sortKey}
                onChange={(event) => setSortKey(event.target.value as SortKey)}
                className="h-10 w-full appearance-none rounded-[10px] border border-line bg-paper pl-9 pr-8 text-sm text-olive outline-none transition-colors focus:border-brand focus:ring-2 focus:ring-[var(--focus-ring)] sm:w-36"
              >
                <option value="market">按市值排序</option>
                <option value="profit">按收益率排序</option>
                <option value="change">按今日涨跌</option>
              </select>
            </label>
          </div>
        </div>

        <div className="ledger-table-head hidden border-b border-line px-5 py-3 md:grid md:grid-cols-[minmax(190px,1.25fr)_0.92fr_0.9fr_0.78fr_0.72fr_0.94fr_92px_36px] md:items-center md:gap-4">
          <div>股票</div>
          <div className="text-right">市值 / 仓位</div>
          <div className="text-right">持有 / 现价</div>
          <div className="text-right">平均成本</div>
          <div className="text-right">今日涨跌</div>
          <div className="text-right">{holdingView === "closed" ? "已实现盈亏" : "未实现盈亏"}</div>
          <div className="text-right">90 日走势</div>
          <div />
        </div>

        {visibleGroups.length ? (
          <div className="divide-y divide-line">
            {visibleGroups.map((group) => (
              <InstitutionHoldingsGroup
                key={group.key}
                group={group}
                portfolioValueCny={totalMarketValueCny}
                view={holdingView}
                openHolding={activeOpenHolding}
                onToggleHolding={(rowKey) => setOpenHolding((current) => (current ?? defaultOpenHolding) === rowKey ? null : rowKey)}
              />
            ))}
          </div>
        ) : <EmptyState text={query ? "没有匹配的持仓" : holdingView === "closed" ? "暂无已清仓证券" : "暂无证券商品"} />}
      </section>
    </div>
  );
}

function InstitutionTabs({ options, selected, onChange }: { options: InstitutionOption[]; selected: string; onChange: (account: string) => void }) {
  if (options.length <= 1) return null;
  return (
    <nav className="flex gap-2 overflow-x-auto pb-1" aria-label="持仓机构">
      <InstitutionTab label="全部机构" detail={`${options.length}`} active={selected === "all"} onClick={() => onChange("all")} />
      {options.map((option) => (
        <InstitutionTab key={option.key} label={option.label} detail={`${option.holdingCount} 只`} active={selected === option.key} onClick={() => onChange(option.key)} />
      ))}
    </nav>
  );
}

function InstitutionTab({ label, detail, active, onClick }: { label: string; detail?: string; active: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={`flex h-10 shrink-0 items-center gap-2 rounded-[10px] border px-3 text-sm font-medium transition-[background-color,border-color,color,transform] active:scale-95 ${active ? "border-brand bg-brand text-paper" : "border-line bg-panel text-olive [@media(hover:hover)]:hover:bg-tag [@media(hover:hover)]:hover:text-brand"}`}
    >
      <span>{label}</span>
      {detail && <span className={`rounded-full px-1.5 py-0.5 text-[10px] ${active ? "bg-paper/15 text-paper" : "bg-paper text-stone"}`}>{detail}</span>}
    </button>
  );
}

function HoldingViewTabs({ view, openCount, closedCount, onChange }: { view: HoldingView; openCount: number; closedCount: number; onChange: (view: HoldingView) => void }) {
  return (
    <div className="flex rounded-[10px] border border-line bg-paper p-1 text-xs">
      <button type="button" onClick={() => onChange("open")} className={`rounded-md px-2.5 py-1.5 transition-[background-color,color,transform] active:scale-95 ${view === "open" ? "bg-brand text-paper" : "text-stone [@media(hover:hover)]:hover:bg-tag [@media(hover:hover)]:hover:text-brand"}`}>当前持仓 {openCount}</button>
      <button type="button" onClick={() => onChange("closed")} className={`rounded-md px-2.5 py-1.5 transition-[background-color,color,transform] active:scale-95 ${view === "closed" ? "bg-brand text-paper" : "text-stone [@media(hover:hover)]:hover:bg-tag [@media(hover:hover)]:hover:text-brand"}`}>已清仓 {closedCount}</button>
    </div>
  );
}

function PortfolioOverview({ totalMarketValueCny, latestDate, costSummary, profitSummary, realizedSummary, dailySummary, holdingCount, closedHoldingCount, institutionCount, series }: { totalMarketValueCny: number; latestDate: string; costSummary: MoneyValue | null; profitSummary: MoneyValue | null; realizedSummary: MoneyValue | null; dailySummary: MoneyValue | null; holdingCount: number; closedHoldingCount: number; institutionCount: number; series: PortfolioPoint[] }) {
  const profitRatio = ratioFromMoney(profitSummary, costSummary);
  const dailyRatio = totalMarketValueCny > 0 && dailySummary?.currency === "CNY" ? dailySummary.value / (totalMarketValueCny / 100 - dailySummary.value) : null;
  return (
    <section className="overflow-hidden rounded-[14px] border border-line bg-panel">
      <div className="grid min-w-0 lg:grid-cols-[minmax(0,1.1fr)_minmax(360px,0.9fr)]">
        <div className="min-w-0 px-4 py-5 sm:px-6 sm:py-6">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="ledger-label">持仓总资产</span>
            <span className="text-xs text-stone">{latestDate ? `价格更新于 ${latestDate}` : "暂无价格"}</span>
          </div>
          <div className="amount-gold mt-2 font-serif text-3xl font-medium tracking-[-0.012em] sm:text-4xl">{formatCny(totalMarketValueCny / 100)}</div>
          <div className="mt-5 grid gap-x-8 gap-y-4 sm:grid-cols-2 xl:grid-cols-4">
            <OverviewMetric label="今日收益" value={formatProfit(dailySummary)} detail={dailySummary ? `${formatRatio(dailyRatio)} · 按最新两条价格估算` : "价格历史不足"} tone={profitTone(dailySummary)} />
            <OverviewMetric label="未实现盈亏" value={formatProfit(profitSummary)} detail={holdingCount ? `${formatRatio(profitRatio)} · 当前持仓` : "暂无当前持仓"} tone={profitTone(profitSummary)} />
            <OverviewMetric label="已实现盈亏" value={formatProfit(realizedSummary)} detail={realizedSummary ? "来自卖出和清仓记录" : "暂无卖出记录"} tone={profitTone(realizedSummary)} />
            <OverviewMetric label="持仓范围" value={`${holdingCount} / ${closedHoldingCount}`} detail={`${institutionCount} 个机构账户 · 当前 / 已清仓`} tone="text-olive" />
          </div>
        </div>
        <div className="min-w-0 border-t border-line bg-paper/55 px-4 py-4 sm:px-6 lg:border-l lg:border-t-0">
          <div className="flex items-center justify-between gap-3">
            <div>
              <div className="text-sm font-medium text-ink">近 30 个价格点</div>
              <div className="mt-1 text-xs text-stone">按当前仓位与证券价格估算，不包含汇率波动</div>
            </div>
            <LineChartIcon className="h-5 w-5 text-brand" />
          </div>
          <div className="mt-3 h-40 min-w-0">
            {series.length >= 2 ? <PortfolioChart rows={series} /> : <EmptyInline text="价格历史不足" />}
          </div>
        </div>
      </div>
    </section>
  );
}

function OverviewMetric({ label, value, detail, tone }: { label: string; value: string; detail: string; tone: string }) {
  return (
    <div className="min-w-0">
      <div className="ledger-label">{label}</div>
      <div className={`mt-1 truncate text-lg font-semibold tabular-nums ${tone}`}>{value}</div>
      <div className="mt-0.5 truncate text-xs text-stone">{detail}</div>
    </div>
  );
}

function PortfolioChart({ rows }: { rows: PortfolioPoint[] }) {
  return (
    <div className="ledger-chart h-full min-w-0">
      <ResponsiveContainer width="100%" height="100%">
        <AreaChart data={rows} margin={{ left: 0, right: 4, top: 8, bottom: 0 }}>
          <defs>
            <linearGradient id="investmentPortfolioFill" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="var(--chart-primary)" stopOpacity={0.24} />
              <stop offset="100%" stopColor="var(--chart-primary)" stopOpacity={0.02} />
            </linearGradient>
          </defs>
          <YAxis hide domain={["dataMin", "dataMax"]} />
          <XAxis hide dataKey="date" />
          <Tooltip
            formatter={(value) => [formatCny(Number(value)), "估算市值"]}
            labelFormatter={(label) => String(label)}
            contentStyle={{ borderColor: "var(--line)", background: "var(--ivory)", color: "var(--ink)", borderRadius: 10 }}
          />
          <Area type="monotone" dataKey="value" stroke="var(--chart-primary)" strokeWidth={2.25} fill="url(#investmentPortfolioFill)" dot={false} activeDot={{ r: 4 }} isAnimationActive={false} />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}

function AllocationBar({ rows, totalMarketValueCny, mode }: { rows: { label: string; value: number }[]; totalMarketValueCny: number; mode: "institution" | "security" }) {
  const sortedRows = rows
    .filter((row) => row.value > 0)
    .sort((left, right) => right.value - left.value);
  if (!sortedRows.length || totalMarketValueCny <= 0) return null;
  const visibleRows = sortedRows.slice(0, 4);
  const visibleValue = visibleRows.reduce((total, row) => total + row.value, 0);
  const allocationRows = visibleRows.map((row, index) => ({ ...row, color: allocationColors[index] }));
  if (visibleValue < totalMarketValueCny) allocationRows.push({ label: "其他", value: totalMarketValueCny - visibleValue, color: allocationColors[4] });
  return (
    <section className="rounded-[14px] border border-line bg-panel px-4 py-4 sm:px-5">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:gap-6">
        <div className="shrink-0">
          <div className="text-sm font-medium text-ink">仓位分布</div>
          <div className="mt-0.5 text-xs text-stone">{mode === "institution" ? "按机构账户" : "按股票"} · 按折算市值</div>
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex h-2.5 overflow-hidden rounded-full bg-paper">
            {allocationRows.map((row) => <div key={row.label} style={{ width: `${row.value / totalMarketValueCny * 100}%`, background: row.color }} />)}
          </div>
          <div className="mt-3 flex flex-wrap gap-x-5 gap-y-2">
            {allocationRows.map((row) => (
              <div key={row.label} className="flex items-center gap-2 text-xs">
                <span className="h-2 w-2 rounded-full" style={{ background: row.color }} />
                <span className="font-medium text-olive">{row.label}</span>
                <span className="tabular-nums text-stone">{(row.value / totalMarketValueCny * 100).toFixed(1)}%</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}

function InstitutionHoldingsGroup({ group, portfolioValueCny, view, openHolding, onToggleHolding }: { group: InstitutionGroup; portfolioValueCny: number; view: HoldingView; openHolding: string | null; onToggleHolding: (rowKey: string) => void }) {
  const profitSummary = summarizeHoldingProfit(group.holdings);
  const realizedSummary = summarizeRealizedProfit(group.holdings);
  return (
    <section>
      <div className="flex flex-col gap-2 border-b border-line bg-paper/70 px-4 py-3 sm:px-5 md:flex-row md:items-center md:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="truncate text-sm font-semibold text-ink">{group.label}</h3>
            <span className="ledger-chip rounded-full px-2 py-0.5 text-[11px]">{group.holdingCount} 只股票</span>
            <span className="ledger-chip rounded-full px-2 py-0.5 text-[11px]">{group.positionCount} 个账户</span>
          </div>
          <div className="mt-1 truncate text-xs text-stone">{group.key}</div>
        </div>
        <div className="grid grid-cols-2 gap-4 text-right sm:flex sm:items-end sm:gap-6">
          <StackedMetric primary={view === "closed" ? formatProfit(realizedSummary) : formatCnyValue(group.totalMarketValueCny)} secondary={view === "closed" ? "已实现盈亏" : "机构市值"} tone={view === "closed" ? profitTone(realizedSummary) : "text-warm"} />
          <StackedMetric primary={view === "closed" ? `${group.holdingCount} 只` : formatProfit(profitSummary)} secondary={view === "closed" ? "已清仓" : "未实现盈亏"} tone={view === "closed" ? "text-olive" : profitTone(profitSummary)} />
        </div>
      </div>
      <div className="divide-y divide-line">
        {group.holdings.map((holding) => {
          const rowKey = `${group.key}:${holding.commodity}`;
          const expanded = openHolding === rowKey;
          return (
            <HoldingRow
              key={rowKey}
              holding={holding}
              portfolioValueCny={portfolioValueCny}
              view={view}
              expanded={expanded}
              onToggle={() => onToggleHolding(rowKey)}
            />
          );
        })}
      </div>
    </section>
  );
}

function HoldingRow({ holding, portfolioValueCny, view, expanded, onToggle }: { holding: InvestmentHolding; portfolioValueCny: number; view: HoldingView; expanded: boolean; onToggle: () => void }) {
  const points = pricePoints(holding.priceHistory);
  const sparklinePoints = points.slice(-90);
  const dailyChange = latestPriceChange(points);
  const profit = view === "closed" ? holdingRealizedProfit(holding) : holdingProfit(holding);
  const profitRatio = view === "closed" ? holdingRealizedProfitRatio(holding) : holdingProfitRatio(holding);
  const positionRatio = portfolioValueCny > 0 ? (holding.totalMarketValueCny ?? 0) / portfolioValueCny : null;

  return (
    <article className={expanded ? "bg-[var(--selected-bg)]" : "bg-panel"}>
      <div className="px-4 py-4 sm:px-5">
        <div className="hidden gap-4 md:grid md:grid-cols-[minmax(190px,1.25fr)_0.92fr_0.9fr_0.78fr_0.72fr_0.94fr_92px_36px] md:items-center">
          <SecurityName symbol={holding.commodity} name={holding.commodityName} accountCount={holding.accountCount} />
          <StackedMetric primary={formatCnyValue(holding.totalMarketValueCny)} secondary={formatUnsignedRatio(positionRatio)} tone="text-warm" />
          <StackedMetric primary={formatQuantity(holding.totalQuantity)} secondary={formatPrice(holding.latestPrice)} tone="text-warm" />
          <StackedMetric primary={formatCostPrice(holding.averageCost, holding.costCurrency)} secondary={formatMarketValue(holding.totalCostValue, holding.costCurrency)} tone="text-warm" />
          <StackedMetric primary={formatPriceChange(dailyChange)} secondary={holding.latestPrice?.date ?? "暂无"} tone={changeTone(dailyChange)} />
          <StackedMetric primary={formatProfit(profit)} secondary={formatRatio(profitRatio)} tone={profitTone(profit)} />
          <div className="h-10 min-w-0"><PriceSparkline points={sparklinePoints} currency={holding.latestPrice?.currency ?? ""} compact /></div>
          <ExpandButton symbol={holding.commodity} expanded={expanded} onClick={onToggle} />
        </div>

        <div className="md:hidden">
          <div className="flex items-start justify-between gap-3">
            <SecurityName symbol={holding.commodity} name={holding.commodityName} accountCount={holding.accountCount} />
            <ExpandButton symbol={holding.commodity} expanded={expanded} onClick={onToggle} />
          </div>
          <div className="mt-4 grid grid-cols-2 gap-x-5 gap-y-4">
            <MobileMetric label="市值 / 仓位" value={formatCnyValue(holding.totalMarketValueCny)} detail={formatUnsignedRatio(positionRatio)} />
            <MobileMetric label={view === "closed" ? "已实现盈亏" : "未实现盈亏"} value={formatProfit(profit)} detail={formatRatio(profitRatio)} tone={profitTone(profit)} />
            <MobileMetric label="持有 / 现价" value={formatQuantity(holding.totalQuantity)} detail={formatPrice(holding.latestPrice)} />
            <MobileMetric label="今日涨跌" value={formatPriceChange(dailyChange)} detail={holding.latestPrice?.date ?? "暂无"} tone={changeTone(dailyChange)} />
          </div>
          <button type="button" className="mt-4 flex h-10 w-full items-center justify-center gap-2 rounded-[10px] border border-line bg-paper text-sm font-medium text-olive transition-[background-color,transform] active:scale-95 [@media(hover:hover)]:hover:bg-tag" onClick={onToggle} aria-expanded={expanded}>
            {expanded ? "收起持仓详情" : "查看持仓详情与买入批次"}
            <ChevronDown className={`h-4 w-4 transition-transform ${expanded ? "rotate-180" : ""}`} />
          </button>
        </div>
      </div>

      {expanded && <HoldingDetail holding={holding} points={points} />}
    </article>
  );
}

function HoldingDetail({ holding, points }: { holding: InvestmentHolding; points: PricePoint[] }) {
  const lots = holding.lots ?? [];
  const positions = holding.positions ?? [];
  const realizedTrades = holding.realizedTrades ?? [];
  return (
    <div className="border-t border-line bg-paper/80 px-4 py-5 sm:px-5">
      <div className="grid gap-5 xl:grid-cols-[minmax(0,1.35fr)_minmax(280px,0.65fr)]">
        <PricePanel holding={holding} points={points} />
        <AccountDistribution positions={positions} holding={holding} />
      </div>
      <div className="mt-5">
        <InvestmentLots lots={lots} />
      </div>
      <div className="mt-5">
        <InvestmentRealizedTrades trades={realizedTrades} />
      </div>
    </div>
  );
}

function PricePanel({ holding, points }: { holding: InvestmentHolding; points: PricePoint[] }) {
  const [range, setRange] = useState<30 | 90 | 365>(90);
  const visiblePoints = points.slice(-range);
  const change = rangePriceChange(visiblePoints);
  return (
    <section className="min-w-0 rounded-xl border border-line bg-panel p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2 text-sm font-medium text-ink"><LineChartIcon className="h-4 w-4 text-brand" />价格走势</div>
          <div className="mt-2 flex items-baseline gap-2">
            <span className="text-xl font-semibold tabular-nums text-warm">{formatPrice(holding.latestPrice)}</span>
            <span className={`text-sm font-medium tabular-nums ${changeTone(change)}`}>{formatPriceChange(change)}</span>
          </div>
        </div>
        <div className="flex rounded-[10px] border border-line bg-paper p-1 text-xs">
          {([{ label: "1月", value: 30 }, { label: "3月", value: 90 }, { label: "1年", value: 365 }] as const).map((option) => (
            <button key={option.value} type="button" onClick={() => setRange(option.value)} className={`rounded-md px-2.5 py-1.5 transition-[background-color,color,transform] active:scale-95 ${range === option.value ? "bg-brand text-paper" : "text-stone [@media(hover:hover)]:hover:bg-tag [@media(hover:hover)]:hover:text-brand"}`}>{option.label}</button>
          ))}
        </div>
      </div>
      <div className="mt-4 h-52 min-w-0">
        {visiblePoints.length >= 2 ? <DetailedPriceChart points={visiblePoints} currency={holding.latestPrice?.currency ?? ""} averageCost={holding.averageCost} /> : <EmptyInline text="暂无足够价格历史" />}
      </div>
      <div className="mt-3 flex flex-wrap gap-x-5 gap-y-2 text-xs text-stone">
        <span>最新价格 {holding.latestPrice?.date ?? "暂无"}</span>
        <span>平均成本 {formatCostPrice(holding.averageCost, holding.costCurrency)}</span>
        <span>原币市值 {formatMarketValue(holding.totalMarketValue, holding.marketCurrency)}</span>
      </div>
    </section>
  );
}

function DetailedPriceChart({ points, currency, averageCost }: { points: PricePoint[]; currency: string; averageCost?: number }) {
  return (
    <div className="ledger-chart h-full min-w-0">
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={points} margin={{ left: 2, right: 8, top: 8, bottom: 0 }}>
          <CartesianGrid vertical={false} stroke="var(--chart-grid)" strokeOpacity={0.72} />
          <XAxis dataKey="date" tick={{ fill: "var(--stone)", fontSize: 10 }} tickLine={false} axisLine={false} minTickGap={28} tickFormatter={(value) => String(value).slice(5)} />
          <YAxis width={48} domain={["dataMin", "dataMax"]} tick={{ fill: "var(--stone)", fontSize: 10 }} tickLine={false} axisLine={false} tickFormatter={(value) => new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 }).format(Number(value))} />
          <Tooltip
            formatter={(value) => [formatMoney(Number(value), currency || "CNY"), "价格"]}
            labelFormatter={(label) => String(label)}
            contentStyle={{ borderColor: "var(--line)", background: "var(--ivory)", color: "var(--ink)", borderRadius: 10 }}
          />
          {averageCost != null && <ReferenceLine y={averageCost} stroke="var(--warning)" strokeDasharray="5 4" label={{ value: "平均成本", position: "insideTopRight", fill: "var(--warning)", fontSize: 10 }} />}
          <Line type="monotone" dataKey="price" stroke="var(--chart-primary)" strokeWidth={2.4} dot={false} activeDot={{ r: 4 }} isAnimationActive={false} />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}

function AccountDistribution({ positions, holding }: { positions: InvestmentPosition[]; holding: InvestmentHolding }) {
  const totalValue = positions.reduce((total, position) => total + (position.marketValueCny ?? 0), 0);
  return (
    <section className="rounded-xl border border-line bg-panel p-4">
      <div className="flex items-center justify-between gap-3">
        <h3 className="text-sm font-semibold text-ink">账户分布</h3>
        <span className="ledger-label">{positions.length || holding.accountCount} 个账户</span>
      </div>
      {positions.length ? (
        <div className="mt-3 divide-y divide-line">
          {positions.map((position) => (
            <div key={`${position.account}:${position.commodity}`} className="py-3 first:pt-0 last:pb-0">
              <ResponsiveValueRow label={position.accountLabel} labelClassName="truncate text-sm font-medium text-olive" value={formatCnyValue(position.marketValueCny)} valueClassName="text-sm font-semibold text-warm" valueTitle={formatCnyValue(position.marketValueCny)} detail={position.account} detailClassName="truncate text-xs text-stone" />
              <ResponsiveValueRow className="mt-2" label={`${formatQuantity(position.quantity)} 股`} labelClassName="text-xs text-stone" value={`成本 ${formatCostPrice(position.averageCost, position.costCurrency)}`} valueClassName="text-xs text-stone" valueTitle={`成本 ${formatCostPrice(position.averageCost, position.costCurrency)}`} detail={totalValue > 0 ? `${(Number(position.marketValueCny ?? 0) / totalValue * 100).toFixed(1)}% 仓位` : "暂无仓位比例"} detailClassName="text-xs text-stone/70" />
            </div>
          ))}
        </div>
      ) : <div className="mt-3"><EmptyInline text="暂无账户拆分" /></div>}
    </section>
  );
}

function InvestmentLots({ lots }: { lots: InvestmentLot[] }) {
  return (
    <section>
      <div className="flex items-center justify-between gap-3">
        <h3 className="text-sm font-semibold text-ink">买入批次</h3>
        <span className="ledger-label">{lots.length} 笔</span>
      </div>
      {lots.length ? (
        <div className="mt-2 overflow-x-auto rounded-xl border border-line bg-panel">
          <table className="w-full min-w-[760px] border-separate border-spacing-0 text-sm">
            <thead className="ledger-table-head">
              <tr>
                <TableHead align="left">买入日期</TableHead>
                <TableHead align="left">账户</TableHead>
                <TableHead>股数</TableHead>
                <TableHead>成本价</TableHead>
                <TableHead>总成本</TableHead>
              </tr>
            </thead>
            <tbody>
              {lots.map((lot, index) => (
                <tr key={`${lot.date}:${lot.account}:${lot.commodity}:${index}`}>
                  <TableCell align="left" strong>{lot.date}</TableCell>
                  <TableCell align="left">
                    <div className="max-w-72 truncate text-olive">{lot.accountLabel}</div>
                    <div className="max-w-72 truncate text-xs text-stone">{lot.account}</div>
                  </TableCell>
                  <TableCell>{formatQuantity(lot.quantity)}</TableCell>
                  <TableCell>{formatCostPrice(lot.unitCost, lot.costCurrency)}</TableCell>
                  <TableCell strong>{formatMarketValue(lot.costValue, lot.costCurrency)}</TableCell>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : <div className="mt-2"><EmptyInline text="暂无买入批次" /></div>}
    </section>
  );
}

function InvestmentRealizedTrades({ trades }: { trades: InvestmentRealizedTrade[] }) {
  if (!trades.length) return null;
  return (
    <section>
      <div className="flex items-center justify-between gap-3">
        <h3 className="text-sm font-semibold text-ink">卖出记录</h3>
        <span className="ledger-label">{trades.length} 笔</span>
      </div>
      <div className="mt-2 overflow-x-auto rounded-xl border border-line bg-panel">
        <table className="w-full min-w-[860px] border-separate border-spacing-0 text-sm">
          <thead className="ledger-table-head">
            <tr>
              <TableHead align="left">卖出日期</TableHead>
              <TableHead align="left">账户</TableHead>
              <TableHead>股数</TableHead>
              <TableHead>卖出收入</TableHead>
              <TableHead>结转成本</TableHead>
              <TableHead>已实现盈亏</TableHead>
            </tr>
          </thead>
          <tbody>
            {trades.map((trade, index) => (
              <tr key={`${trade.date}:${trade.account}:${trade.commodity}:${index}`}>
                <TableCell align="left" strong>{trade.date}</TableCell>
                <TableCell align="left">
                  <div className="max-w-72 truncate text-olive">{trade.accountLabel}</div>
                  <div className="max-w-72 truncate text-xs text-stone">{trade.account}</div>
                </TableCell>
                <TableCell>{formatQuantity(trade.quantity)}</TableCell>
                <TableCell>{formatMarketValue(trade.proceedsValue, trade.proceedsCurrency)}</TableCell>
                <TableCell>{formatMarketValue(trade.costValue, trade.costCurrency)}</TableCell>
                <TableCell strong><span className={profitTone(realizedTradeProfit(trade))}>{formatProfit(realizedTradeProfit(trade))}</span></TableCell>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function PriceSparkline({ points, currency, compact = false }: { points: PricePoint[]; currency: string; compact?: boolean }) {
  const change = rangePriceChange(points);
  if (points.length < 2) return <div className="grid h-full place-items-center text-[10px] text-stone">暂无</div>;
  return (
    <div className="ledger-chart h-full min-w-0">
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={points} margin={{ left: 2, right: 2, top: compact ? 5 : 8, bottom: compact ? 5 : 8 }}>
          <YAxis hide domain={["dataMin", "dataMax"]} />
          {!compact && <Tooltip formatter={(value) => [formatMoney(Number(value), currency || "CNY"), "价格"]} labelFormatter={(label) => String(label)} contentStyle={{ borderColor: "var(--line)", background: "var(--ivory)", color: "var(--ink)", borderRadius: 10 }} />}
          <Line type="monotone" dataKey="price" stroke={change != null && change < 0 ? "var(--danger)" : "var(--success)"} strokeWidth={compact ? 1.8 : 2.25} dot={false} activeDot={compact ? false : { r: 4 }} isAnimationActive={false} />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}

function SecurityName({ symbol, name, accountCount }: { symbol: string; name: string; accountCount: number }) {
  return (
    <div className="flex min-w-0 items-center gap-3">
      <span className="grid h-10 w-10 shrink-0 place-items-center rounded-[10px] bg-brand text-xs font-semibold tracking-wide text-paper">{symbol.slice(0, 3)}</span>
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <div className="truncate text-base font-semibold leading-tight text-ink">{symbol}</div>
          {accountCount > 1 && <span className="ledger-chip shrink-0 rounded-full px-1.5 py-0.5 text-[10px]">{accountCount} 户</span>}
        </div>
        <div className="mt-1 truncate text-xs text-stone">{name}</div>
      </div>
    </div>
  );
}

function StackedMetric({ primary, secondary, tone }: { primary: string; secondary: string; tone: string }) {
  return <div className="min-w-0 text-right"><div className={`truncate text-sm font-semibold tabular-nums ${tone}`}>{primary}</div><div className="mt-1 truncate text-xs tabular-nums text-stone">{secondary}</div></div>;
}

function MobileMetric({ label, value, detail, tone = "text-warm" }: { label: string; value: string; detail: string; tone?: string }) {
  return <div className="min-w-0"><div className="ledger-label">{label}</div><div className={`mt-1 truncate text-sm font-semibold tabular-nums ${tone}`}>{value}</div><div className="mt-1 truncate text-xs tabular-nums text-stone">{detail}</div></div>;
}

function ExpandButton({ symbol, expanded, onClick }: { symbol: string; expanded: boolean; onClick: () => void }) {
  return (
    <button type="button" className="grid h-9 w-9 shrink-0 place-items-center rounded-[10px] border border-line bg-paper text-stone transition-[background-color,color,transform] active:scale-95 [@media(hover:hover)]:hover:bg-tag [@media(hover:hover)]:hover:text-brand" onClick={onClick} aria-expanded={expanded} aria-label={`${expanded ? "收起" : "展开"} ${symbol} 持仓详情`}>
      <ChevronDown className={`h-4 w-4 transition-transform ${expanded ? "rotate-180" : ""}`} />
    </button>
  );
}

function TableHead({ children, align = "right" }: { children: string; align?: "left" | "right" }) {
  return <th className={`border-b border-line px-3 py-2 font-medium ${align === "left" ? "text-left" : "text-right"}`}>{children}</th>;
}

function TableCell({ children, align = "right", strong = false }: { children: ReactNode; align?: "left" | "right"; strong?: boolean }) {
  return <td className={`border-b border-line px-3 py-3 align-middle tabular-nums ${align === "left" ? "text-left" : "text-right"} ${strong ? "font-semibold text-olive" : "text-warm"}`}>{children}</td>;
}

function EmptyState({ text }: { text: string }) {
  return <div className="m-4 rounded-xl border border-line bg-paper p-8 text-center text-sm text-stone">{text}</div>;
}

function EmptyInline({ text }: { text: string }) {
  return <div className="grid h-full min-h-20 place-items-center rounded-[10px] border border-dashed border-line bg-paper px-3 py-4 text-xs text-stone">{text}</div>;
}

function investmentHoldings(investments: InvestmentSummary | null): InvestmentHolding[] {
  if (!investments) return [];
  if (investments.holdings?.length) {
    const positionsByCommodity = new Map<string, InvestmentPosition[]>();
    for (const position of investments.positions ?? []) {
      positionsByCommodity.set(position.commodity, [...(positionsByCommodity.get(position.commodity) ?? []), position]);
    }
    return investments.holdings
      .map((holding) => {
        if (holding.positions?.length) return holding;
        const positions = positionsByCommodity.get(holding.commodity) ?? [];
        if (!positions.length) return holding;
        return {
          ...holding,
          accountCount: positions.length,
          positions,
          lots: holding.lots?.length ? holding.lots : positions.flatMap((position) => position.lots ?? []),
        };
      })
      .filter(isVisibleHolding);
  }
  return legacyHoldings(investments.positions ?? [], investments.quotes ?? []);
}

function investmentClosedHoldings(investments: InvestmentSummary | null): InvestmentHolding[] {
  return (investments?.closedHoldings ?? []).filter(isClosedHolding);
}

function legacyHoldings(positions: InvestmentPosition[], quotes: InvestmentQuote[]): InvestmentHolding[] {
  const quoteMap = new Map(quotes.map((quote) => [quote.commodity, quote]));
  const byCommodity = new Map<string, InvestmentPosition[]>();
  for (const position of positions) byCommodity.set(position.commodity, [...(byCommodity.get(position.commodity) ?? []), position]);
  return [...byCommodity.entries()].map(([commodity, rows]) => {
    const quote = quoteMap.get(commodity);
    const totalQuantity = rows.reduce((total, row) => total + row.quantity, 0);
    const totalMarketValueCny = sumOptionalNumbers(rows.map((row) => row.marketValueCny));
    const totalMarketValue = sumSameCurrency(rows, "marketValue", "marketCurrency");
    const totalCostValueCny = sumOptionalNumbers(rows.map((row) => row.costValueCny));
    const totalCostValue = sumSameCurrency(rows, "costValue", "costCurrency");
    const costCurrency = sameString(rows.map((row) => row.costCurrency));
    return {
      commodity,
      commodityName: rows[0]?.commodityName || quote?.commodityName || commodity,
      latestPrice: rows[0]?.latestPrice || quote?.latestPrice,
      priceHistory: [],
      totalQuantity,
      averageCost: totalCostValue != null && totalQuantity !== 0 ? totalCostValue / totalQuantity : undefined,
      totalCostValue,
      costCurrency,
      totalCostValueCny,
      totalMarketValue,
      marketCurrency: sameString(rows.map((row) => row.marketCurrency)),
      totalMarketValueCny: totalMarketValueCny ?? quote?.marketValueCny,
      accountCount: rows.length,
      positions: rows,
      lots: rows.flatMap((row) => row.lots ?? []),
    };
  }).filter(isVisibleHolding).sort((left, right) => (right.totalMarketValueCny ?? 0) - (left.totalMarketValueCny ?? 0) || left.commodity.localeCompare(right.commodity));
}

function holdingForPositions(holding: InvestmentHolding, positions: InvestmentPosition[]): InvestmentHolding | null {
  if (!positions.length) return null;
  const accountSet = new Set(positions.map((position) => position.account));
  const realizedTrades = (holding.realizedTrades ?? []).filter((trade) => accountSet.has(trade.account));
  const realizedCny = sumOptionalNumbers(realizedTrades.map((trade) => trade.realizedPnlCny));
  const realizedSameCurrency = sumSameRealizedCurrency(realizedTrades);
  const totalQuantity = positions.reduce((total, position) => total + position.quantity, 0);
  const totalCostValue = sumSameCurrency(positions, "costValue", "costCurrency");
  return {
    ...holding,
    totalQuantity,
    averageCost: totalCostValue != null && totalQuantity !== 0 ? totalCostValue / totalQuantity : undefined,
    totalCostValue,
    costCurrency: sameString(positions.map((position) => position.costCurrency)),
    totalCostValueCny: sumOptionalNumbers(positions.map((position) => position.costValueCny)),
    totalMarketValue: sumSameCurrency(positions, "marketValue", "marketCurrency"),
    marketCurrency: sameString(positions.map((position) => position.marketCurrency)),
    totalMarketValueCny: sumOptionalNumbers(positions.map((position) => position.marketValueCny)),
    accountCount: new Set(positions.map((position) => position.account)).size,
    positions,
    lots: positions.flatMap((position) => position.lots ?? []),
    realizedTrades,
    realizedPnl: realizedSameCurrency?.value,
    realizedCurrency: realizedSameCurrency?.currency,
    realizedPnlCny: realizedCny,
  };
}

function investmentInstitutionGroups(holdings: InvestmentHolding[]): InstitutionGroup[] {
  const groups = new Map<string, { label: string; holdings: InvestmentHolding[] }>();
  for (const holding of holdings) {
    const positions = holding.positions ?? [];
    if (!positions.length) {
      const key = "unassigned";
      const group = groups.get(key) ?? { label: "未分组账户", holdings: [] };
      group.holdings.push(holding);
      groups.set(key, group);
      continue;
    }
    const positionsByInstitution = new Map<string, InvestmentPosition[]>();
    for (const position of positions) {
      const key = institutionKey(position.account);
      positionsByInstitution.set(key, [...(positionsByInstitution.get(key) ?? []), position]);
    }
    for (const [key, rows] of positionsByInstitution) {
      const scoped = holdingForPositions(holding, rows);
      if (!scoped) continue;
      const group = groups.get(key) ?? { label: institutionLabel(rows[0]?.account ?? key), holdings: [] };
      group.holdings.push(scoped);
      groups.set(key, group);
    }
  }
  return [...groups.entries()].map(([key, group]) => {
    const visibleHoldings = sortHoldings(group.holdings.filter(isDisplayableHolding), "market");
    return {
      key,
      label: group.label,
      holdings: visibleHoldings,
      holdingCount: visibleHoldings.length,
      positionCount: new Set(visibleHoldings.flatMap((holding) => (holding.positions ?? []).map((position) => position.account))).size,
      totalMarketValueCny: sumCnyValues(visibleHoldings, "totalMarketValueCny"),
    };
  }).filter((group) => group.holdings.length > 0).sort((left, right) => right.totalMarketValueCny - left.totalMarketValueCny || left.label.localeCompare(right.label, "zh-CN"));
}

function mergeInstitutionOptions(...groupsList: InstitutionGroup[][]): InstitutionOption[] {
  const byKey = new Map<string, InstitutionOption>();
  for (const groups of groupsList) {
    for (const group of groups) {
      const current = byKey.get(group.key) ?? { key: group.key, label: group.label, holdingCount: 0, positionCount: 0, totalMarketValueCny: 0 };
      current.holdingCount += group.holdingCount;
      current.positionCount += group.positionCount;
      current.totalMarketValueCny += group.totalMarketValueCny;
      byKey.set(group.key, current);
    }
  }
  return [...byKey.values()].sort((left, right) => right.totalMarketValueCny - left.totalMarketValueCny || left.label.localeCompare(right.label, "zh-CN"));
}

function institutionKey(account: string) {
  const parts = account.split(":").filter(Boolean);
  if (parts[0] === "Assets") {
    if (parts.length >= 3 && regionAccountSegments.has(parts[1] ?? "")) return parts.slice(0, 3).join(":");
    if (parts.length >= 2) return parts.slice(0, 2).join(":");
  }
  return parts.slice(0, Math.min(parts.length, 3)).join(":") || account;
}

function institutionLabel(account: string) {
  const parts = institutionKey(account).split(":");
  const segment = parts.at(-1) || account;
  return commonInstitutionLabels[segment] ?? segment.replace(/([a-z])([A-Z])/g, "$1 $2");
}

function filterHoldings(holdings: InvestmentHolding[], query: string) {
  const normalized = query.trim().toLocaleLowerCase();
  if (!normalized) return holdings;
  return holdings.filter((holding) => {
    const accountText = (holding.positions ?? []).map((position) => `${position.accountLabel} ${position.account}`).join(" ");
    return `${holding.commodity} ${holding.commodityName} ${accountText}`.toLocaleLowerCase().includes(normalized);
  });
}

function sortHoldings(holdings: InvestmentHolding[], sortKey: SortKey) {
  return [...holdings].sort((left, right) => {
    if (sortKey === "profit") return profitSortValue(right) - profitSortValue(left) || marketSortValue(right) - marketSortValue(left);
    if (sortKey === "change") return (latestPriceChange(pricePoints(right.priceHistory)) ?? -Infinity) - (latestPriceChange(pricePoints(left.priceHistory)) ?? -Infinity) || marketSortValue(right) - marketSortValue(left);
    return marketSortValue(right) - marketSortValue(left) || left.commodity.localeCompare(right.commodity);
  });
}

function isVisibleHolding(holding: InvestmentHolding) {
  return holding.commodity.trim() !== "" && Math.abs(holding.totalQuantity) > 0;
}

function isClosedHolding(holding: InvestmentHolding) {
  return holding.commodity.trim() !== "" && Math.abs(holding.totalQuantity) <= 0.00000001 && (holding.realizedTrades?.length ?? 0) > 0;
}

function isDisplayableHolding(holding: InvestmentHolding) {
  return isVisibleHolding(holding) || isClosedHolding(holding);
}

function pricePoints(history?: CommodityPrice[] | null): PricePoint[] {
  return (history ?? []).map((price) => ({ date: price.date, price: price.amount })).sort((left, right) => left.date.localeCompare(right.date));
}

function latestPriceChange(points: PricePoint[]) {
  return points.length < 2 ? null : priceRatio(points.at(-2)?.price, points.at(-1)?.price);
}

function rangePriceChange(points: PricePoint[]) {
  return points.length < 2 ? null : priceRatio(points[0]?.price, points.at(-1)?.price);
}

function priceRatio(first?: number, last?: number) {
  if (!first || last == null) return null;
  return (last - first) / first;
}

function portfolioPriceSeries(holdings: InvestmentHolding[], limit: number): PortfolioPoint[] {
  const rows = holdings.flatMap((holding) => {
    const history = pricePoints(holding.priceHistory);
    const latestPrice = holding.latestPrice?.amount;
    if (!history.length || !latestPrice || holding.totalMarketValueCny == null) return [];
    return [{ holding, history, latestPrice }];
  });
  if (!rows.length || rows.length !== holdings.length) return [];
  const dates = [...new Set(rows.flatMap((row) => row.history.map((point) => point.date)))].sort().slice(-limit);
  return dates.flatMap((date) => {
    let value = 0;
    let covered = 0;
    for (const row of rows) {
      const point = latestPointAt(row.history, date);
      if (!point) continue;
      value += (row.holding.totalMarketValueCny ?? 0) / 100 * point.price / row.latestPrice;
      covered++;
    }
    return covered === rows.length ? [{ date, value }] : [];
  });
}

function latestPointAt(points: PricePoint[], date: string) {
  for (let index = points.length - 1; index >= 0; index--) {
    if ((points[index]?.date ?? "") <= date) return points[index];
  }
  return null;
}

function holdingProfit(holding: InvestmentHolding): MoneyValue | null {
  if (holding.totalMarketValueCny != null && holding.totalCostValueCny != null) return { value: (holding.totalMarketValueCny - holding.totalCostValueCny) / 100, currency: "CNY" };
  if (holding.totalMarketValue == null || holding.totalCostValue == null || !holding.marketCurrency || holding.marketCurrency !== holding.costCurrency) return null;
  return { value: holding.totalMarketValue - holding.totalCostValue, currency: holding.marketCurrency };
}

function holdingProfitRatio(holding: InvestmentHolding) {
  if (holding.totalMarketValueCny != null && holding.totalCostValueCny) return (holding.totalMarketValueCny - holding.totalCostValueCny) / holding.totalCostValueCny;
  if (holding.totalMarketValue != null && holding.totalCostValue) return (holding.totalMarketValue - holding.totalCostValue) / holding.totalCostValue;
  return null;
}

function realizedTradeProfit(trade: InvestmentRealizedTrade): MoneyValue | null {
  if (trade.realizedPnlCny != null) return { value: trade.realizedPnlCny / 100, currency: "CNY" };
  if (trade.realizedPnl == null || !trade.realizedCurrency) return null;
  return { value: trade.realizedPnl, currency: trade.realizedCurrency };
}

function holdingRealizedProfit(holding: InvestmentHolding): MoneyValue | null {
  if (holding.realizedPnlCny != null) return { value: holding.realizedPnlCny / 100, currency: "CNY" };
  if (holding.realizedPnl == null || !holding.realizedCurrency) return summarizeRealizedProfitFromTrades(holding.realizedTrades ?? []);
  return { value: holding.realizedPnl, currency: holding.realizedCurrency };
}

function holdingRealizedProfitRatio(holding: InvestmentHolding) {
  const profit = holdingRealizedProfit(holding);
  if (!profit || profit.currency === "CNY") return null;
  const cost = sumSameRealizedCost(holding.realizedTrades ?? []);
  if (!cost || cost.currency !== profit.currency || cost.value === 0) return null;
  return profit.value / cost.value;
}

function summarizeHoldingCosts(holdings: InvestmentHolding[]): MoneyValue | null {
  const cnyCents = holdings.reduce((total, holding) => holding.totalCostValueCny == null ? total : total + holding.totalCostValueCny, 0);
  const cnyCount = holdings.filter((holding) => holding.totalCostValueCny != null).length;
  const costCount = countHoldingsWithCost(holdings);
  if (cnyCount > 0 && cnyCount === costCount) return { value: cnyCents / 100, currency: "CNY" };
  const totals = new Map<string, number>();
  for (const holding of holdings) {
    if (holding.totalCostValue == null || !holding.costCurrency) continue;
    totals.set(holding.costCurrency, (totals.get(holding.costCurrency) ?? 0) + holding.totalCostValue);
  }
  if (totals.size !== 1) return null;
  const [[currency, value]] = [...totals.entries()];
  return { value, currency };
}

function summarizeHoldingProfit(holdings: InvestmentHolding[]): MoneyValue | null {
  const cnyProfits = holdings.flatMap((holding) => holding.totalMarketValueCny != null && holding.totalCostValueCny != null ? [(holding.totalMarketValueCny - holding.totalCostValueCny) / 100] : []);
  if (cnyProfits.length > 0 && cnyProfits.length === countHoldingsWithProfit(holdings)) return { value: cnyProfits.reduce((total, value) => total + value, 0), currency: "CNY" };
  const totals = new Map<string, number>();
  for (const holding of holdings) {
    const profit = holdingProfit(holding);
    if (!profit) continue;
    totals.set(profit.currency, (totals.get(profit.currency) ?? 0) + profit.value);
  }
  if (totals.size !== 1) return null;
  const [[currency, value]] = [...totals.entries()];
  return { value, currency };
}

function summarizeRealizedProfit(holdings: InvestmentHolding[]): MoneyValue | null {
  const cnyProfits = holdings.flatMap((holding) => holding.realizedPnlCny != null ? [holding.realizedPnlCny / 100] : []);
  const realizedCount = holdings.filter((holding) => holdingRealizedProfit(holding) != null).length;
  if (cnyProfits.length > 0 && cnyProfits.length === realizedCount) return { value: cnyProfits.reduce((total, value) => total + value, 0), currency: "CNY" };
  const totals = new Map<string, number>();
  for (const holding of holdings) {
    const profit = holdingRealizedProfit(holding);
    if (!profit) continue;
    totals.set(profit.currency, (totals.get(profit.currency) ?? 0) + profit.value);
  }
  if (totals.size !== 1) return null;
  const [[currency, value]] = [...totals.entries()];
  return { value, currency };
}

function summarizeRealizedProfitFromTrades(trades: InvestmentRealizedTrade[]): MoneyValue | null {
  const cnyProfits = trades.flatMap((trade) => trade.realizedPnlCny != null ? [trade.realizedPnlCny / 100] : []);
  const realizedCount = trades.filter((trade) => realizedTradeProfit(trade) != null).length;
  if (cnyProfits.length > 0 && cnyProfits.length === realizedCount) return { value: cnyProfits.reduce((total, value) => total + value, 0), currency: "CNY" };
  return sumSameRealizedCurrency(trades);
}

function summarizeDailyChange(holdings: InvestmentHolding[]): MoneyValue | null {
  const estimates = holdings.flatMap((holding) => {
    const change = latestPriceChange(pricePoints(holding.priceHistory));
    if (change == null || change <= -1 || holding.totalMarketValueCny == null) return [];
    const currentValue = holding.totalMarketValueCny / 100;
    return [currentValue - currentValue / (1 + change)];
  });
  if (!estimates.length || estimates.length !== holdings.length) return null;
  return { value: estimates.reduce((total, value) => total + value, 0), currency: "CNY" };
}

function countHoldingsWithCost(holdings: InvestmentHolding[]) {
  return holdings.filter((holding) => holding.totalCostValueCny != null || (holding.totalCostValue != null && Boolean(holding.costCurrency))).length;
}

function countHoldingsWithProfit(holdings: InvestmentHolding[]) {
  return holdings.filter((holding) => (holding.totalMarketValueCny != null && holding.totalCostValueCny != null) || holdingProfit(holding) != null).length;
}

function sumCnyValues(holdings: InvestmentHolding[], key: "totalMarketValueCny" | "totalCostValueCny") {
  return holdings.reduce((total, holding) => total + (holding[key] ?? 0), 0);
}

function sumOptionalNumbers(values: (number | undefined)[]) {
  const present = values.filter((value): value is number => value != null);
  return present.length === values.length && present.length ? present.reduce((total, value) => total + value, 0) : undefined;
}

function sumSameCurrency<T extends InvestmentPosition>(rows: T[], valueKey: "marketValue" | "costValue", currencyKey: "marketCurrency" | "costCurrency") {
  const currency = sameString(rows.map((row) => row[currencyKey]));
  if (!currency || rows.some((row) => row[valueKey] == null)) return undefined;
  return rows.reduce((total, row) => total + Number(row[valueKey] ?? 0), 0);
}

function sumSameRealizedCurrency(trades: InvestmentRealizedTrade[]): MoneyValue | null {
  const currency = sameString(trades.map((trade) => trade.realizedCurrency));
  if (!currency || trades.some((trade) => trade.realizedPnl == null)) return null;
  return { value: trades.reduce((total, trade) => total + Number(trade.realizedPnl ?? 0), 0), currency };
}

function sumSameRealizedCost(trades: InvestmentRealizedTrade[]): MoneyValue | null {
  const currency = sameString(trades.map((trade) => trade.costCurrency));
  if (!currency || trades.some((trade) => trade.costValue == null)) return null;
  return { value: trades.reduce((total, trade) => total + Number(trade.costValue ?? 0), 0), currency };
}

function sameString(values: (string | undefined)[]) {
  const present = values.filter((value): value is string => Boolean(value));
  return present.length === values.length && new Set(present).size === 1 ? present[0] : undefined;
}

function ratioFromMoney(profit: MoneyValue | null, cost: MoneyValue | null) {
  if (!profit || !cost || profit.currency !== cost.currency || cost.value === 0) return null;
  return profit.value / cost.value;
}

function marketSortValue(holding: InvestmentHolding) {
  return holding.totalMarketValueCny ?? 0;
}

function profitSortValue(holding: InvestmentHolding) {
  return holdingProfitRatio(holding) ?? holdingRealizedProfitRatio(holding) ?? holdingRealizedProfit(holding)?.value ?? -Infinity;
}

function formatQuantity(value: number) {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 6 }).format(value);
}

function formatPrice(price?: CommodityPrice) {
  if (!price) return "暂无";
  return formatUnitMoney(price.amount, price.currency);
}

function formatCostPrice(value?: number, currency?: string) {
  if (value == null || !currency) return "暂无";
  return formatUnitMoney(value, currency);
}

function formatMarketValue(value?: number, currency?: string) {
  if (value == null || !currency) return "暂无";
  return formatMoney(value, currency);
}

function formatCnyValue(value?: number) {
  if (value == null) return "暂无";
  return formatCny(value / 100);
}

function formatMoneyValue(value: MoneyValue | null) {
  if (!value) return "暂无";
  return formatMoney(value.value, value.currency);
}

function formatUnitMoney(value: number, currency: string) {
  try {
    return new Intl.NumberFormat("zh-CN", { style: "currency", currency, minimumFractionDigits: 2, maximumFractionDigits: 6 }).format(value);
  } catch {
    return `${value.toFixed(6).replace(/\.?0+$/, "")} ${currency}`;
  }
}

function formatProfit(value: MoneyValue | null) {
  if (!value) return "暂无";
  const sign = value.value > 0 ? "+" : "";
  return `${sign}${formatMoney(value.value, value.currency)}`;
}

function formatPriceChange(change: number | null) {
  if (change == null) return "暂无";
  const sign = change > 0 ? "+" : "";
  return `${sign}${(change * 100).toFixed(2)}%`;
}

function formatRatio(value: number | null) {
  if (value == null || !Number.isFinite(value)) return "暂无比例";
  const sign = value > 0 ? "+" : "";
  return `${sign}${(value * 100).toFixed(2)}%`;
}

function formatUnsignedRatio(value: number | null) {
  if (value == null || !Number.isFinite(value)) return "暂无比例";
  return `${(value * 100).toFixed(2)}%`;
}

function profitTone(value: MoneyValue | null) {
  if (!value) return "text-stone";
  if (value.value > 0) return "amount-income";
  if (value.value < 0) return "amount-expense";
  return "text-stone";
}

function changeTone(value: number | null) {
  if (value == null) return "text-stone";
  if (value > 0) return "amount-income";
  if (value < 0) return "amount-expense";
  return "text-stone";
}

function latestPriceDate(holdings: InvestmentHolding[]) {
  return holdings.reduce((latest, holding) => {
    const date = holding.latestPrice?.date ?? "";
    return date > latest ? date : latest;
  }, "");
}
