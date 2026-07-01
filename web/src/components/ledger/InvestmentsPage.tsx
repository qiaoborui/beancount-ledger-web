import { formatCny, formatCompactCny, formatMoney } from "@/lib/money";
import { ChevronDown, LineChart as LineChartIcon } from "lucide-react";
import { useMemo, useState, type ReactNode } from "react";
import { Line, LineChart, ResponsiveContainer, Tooltip, YAxis } from "recharts";
import type { CommodityPrice, InvestmentHolding, InvestmentLot, InvestmentPosition, InvestmentQuote, InvestmentSummary } from "./types";

type PricePoint = { date: string; price: number };
type MoneyValue = { value: number; currency: string };

export function InvestmentsPage({ investments }: { investments: InvestmentSummary | null }) {
  const holdings = useMemo(() => investmentHoldings(investments), [investments]);
  const [openHolding, setOpenHolding] = useState<string | null>(null);
  const positions = investments?.positions ?? [];
  const heldHoldings = holdings.filter((holding) => Math.abs(holding.totalQuantity) > 0);
  const latestDate = investments?.updatedAt || latestPriceDate(holdings);
  const accountCount = new Set(positions.map((position) => position.account)).size;
  const costSummary = summarizeHoldingCosts(heldHoldings);
  const profitSummary = summarizeHoldingProfit(heldHoldings);
  const holdingsWithCost = countHoldingsWithCost(heldHoldings);
  const holdingsWithProfit = countHoldingsWithProfit(heldHoldings);
  const lotCount = heldHoldings.reduce((total, holding) => total + (holding.lots?.length ?? 0), 0);

  return (
    <div className="space-y-6">
      <section className="overflow-hidden rounded-xl border border-line bg-panel">
        <div className="grid divide-y divide-line sm:grid-cols-2 sm:divide-x sm:divide-y-0 lg:grid-cols-4">
          <SummaryMetric label="持仓市值" value={formatCompactCny((investments?.totalMarketValueCny ?? 0) / 100)} detail={latestDate ? latestDate : "暂无价格"} tone="amount-gold" />
          <SummaryMetric label="折算成本" value={formatMoneyValue(costSummary)} detail={`${holdingsWithCost}/${heldHoldings.length} 有成本 · ${lotCount} 笔买入`} tone="text-warm" />
          <SummaryMetric label="账面盈亏" value={formatProfit(profitSummary)} detail={`${holdingsWithProfit}/${heldHoldings.length} 可计算`} tone={profitTone(profitSummary)} />
          <SummaryMetric label="持仓股票" value={`${heldHoldings.length}`} detail={`${accountCount} 个账户`} tone="text-olive" />
        </div>
      </section>

      <section className="overflow-hidden rounded-xl border border-line bg-panel">
        <div className="ledger-table-head hidden border-b border-line px-5 py-3 md:grid md:grid-cols-[minmax(180px,1.25fr)_0.58fr_0.72fr_0.72fr_0.72fr_0.72fr_0.72fr_40px] md:items-center md:gap-4">
          <div>股票</div>
          <div className="text-right">持有股数</div>
          <div className="text-right">平均成本</div>
          <div className="text-right">总成本</div>
          <div className="text-right">最新价</div>
          <div className="text-right">原币市值</div>
          <div className="text-right">账面盈亏</div>
          <div />
        </div>

        {holdings.length ? (
          <div className="divide-y divide-line">
            {holdings.map((holding) => {
              const expanded = openHolding === holding.commodity;
              return (
                <HoldingRow
                  key={holding.commodity}
                  holding={holding}
                  expanded={expanded}
                  onToggle={() => setOpenHolding((current) => current === holding.commodity ? null : holding.commodity)}
                />
              );
            })}
          </div>
        ) : <EmptyState text="暂无证券商品" />}
      </section>
    </div>
  );
}

function HoldingRow({ holding, expanded, onToggle }: { holding: InvestmentHolding; expanded: boolean; onToggle: () => void }) {
  const points = pricePoints(holding.priceHistory).slice(-90);
  const lots = holding.lots ?? [];
  const positions = holding.positions ?? [];
  const profit = holdingProfit(holding);

  return (
    <article className="bg-panel">
      <div className="px-4 py-4 sm:px-5">
        <div className="grid gap-4 md:grid-cols-[minmax(180px,1.25fr)_0.58fr_0.72fr_0.72fr_0.72fr_0.72fr_0.72fr_40px] md:items-center">
          <div className="min-w-0">
            <SecurityName symbol={holding.commodity} name={holding.commodityName} />
            <div className="mt-2 flex flex-wrap gap-2 text-xs text-stone">
              <Badge>{lots.length ? `最近买入 ${lots[0]?.date}` : "暂无买入批次"}</Badge>
              <Badge>{holding.accountCount} 个账户</Badge>
            </div>
          </div>

          <RowMetric label="持有股数" value={formatQuantity(holding.totalQuantity)} />
          <RowMetric label="平均成本" value={formatCostPrice(holding.averageCost, holding.costCurrency)} />
          <RowMetric label="总成本" value={formatMarketValue(holding.totalCostValue, holding.costCurrency)} />
          <RowMetric label="最新价" value={formatPrice(holding.latestPrice)} />
          <RowMetric label="原币市值" value={formatMarketValue(holding.totalMarketValue, holding.marketCurrency)} />
          <RowMetric label="账面盈亏" value={formatProfit(profit)} tone={profitTone(profit)} />

          <button type="button" className="hidden h-10 w-10 items-center justify-center rounded-lg border border-line bg-paper text-stone transition-[background-color,transform] active:scale-95 [@media(hover:hover)]:hover:bg-tag md:flex" onClick={onToggle} aria-expanded={expanded} aria-label={`${holding.commodity} 买入批次`}>
            <ChevronDown className={`h-4 w-4 transition-transform ${expanded ? "rotate-180" : ""}`} />
          </button>
        </div>

        <button type="button" className="mt-4 flex h-10 w-full items-center justify-center gap-2 rounded-lg border border-line bg-paper text-sm font-medium text-olive transition-[background-color,transform] active:scale-95 [@media(hover:hover)]:hover:bg-tag md:hidden" onClick={onToggle} aria-expanded={expanded}>
          买入批次
          <ChevronDown className={`h-4 w-4 transition-transform ${expanded ? "rotate-180" : ""}`} />
        </button>
      </div>

      {expanded && (
        <div className="border-t border-line bg-paper px-4 py-4 sm:px-5">
          <div className="grid gap-5 xl:grid-cols-[minmax(0,1fr)_260px]">
            <div className="min-w-0 space-y-5">
              <InvestmentLots lots={lots} />
              {positions.length ? <PositionBreakdown positions={positions} /> : null}
            </div>
            <PricePanel holding={holding} points={points} />
          </div>
        </div>
      )}
    </article>
  );
}

function InvestmentLots({ lots }: { lots: InvestmentLot[] }) {
  return (
    <section>
      <SectionHeader title="买入批次" meta={`${lots.length} 笔`} />
      {lots.length ? (
        <div className="mt-2 overflow-x-auto rounded-lg border border-line bg-panel">
          <table className="w-full min-w-[720px] border-separate border-spacing-0 text-sm">
            <thead className="ledger-table-head">
              <tr>
                <TableHead align="left">买入日期</TableHead>
                <TableHead align="left">账户</TableHead>
                <TableHead>股数</TableHead>
                <TableHead>成本价</TableHead>
                <TableHead>成本</TableHead>
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
      ) : <EmptyInline text="暂无买入批次" />}
    </section>
  );
}

function PositionBreakdown({ positions }: { positions: InvestmentPosition[] }) {
  return (
    <section>
      <SectionHeader title="账户拆分" meta={`${positions.length} 个账户`} />
      <div className="mt-2 overflow-x-auto rounded-lg border border-line bg-panel">
        <table className="w-full min-w-[860px] border-separate border-spacing-0 text-sm">
          <thead className="ledger-table-head">
            <tr>
              <TableHead align="left">账户</TableHead>
              <TableHead>股数</TableHead>
              <TableHead>平均成本</TableHead>
              <TableHead>总成本</TableHead>
              <TableHead>原币市值</TableHead>
              <TableHead>CNY 折算</TableHead>
            </tr>
          </thead>
          <tbody>
            {positions.map((position) => (
              <tr key={`${position.account}:${position.commodity}`}>
                <TableCell align="left">
                  <div className="max-w-72 truncate text-olive">{position.accountLabel}</div>
                  <div className="max-w-72 truncate text-xs text-stone">{position.account}</div>
                </TableCell>
                <TableCell>{formatQuantity(position.quantity)}</TableCell>
                <TableCell>{formatCostPrice(position.averageCost, position.costCurrency)}</TableCell>
                <TableCell>{formatMarketValue(position.costValue, position.costCurrency)}</TableCell>
                <TableCell>{formatMarketValue(position.marketValue, position.marketCurrency)}</TableCell>
                <TableCell strong>{formatCnyValue(position.marketValueCny)}</TableCell>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function PricePanel({ holding, points }: { holding: InvestmentHolding; points: PricePoint[] }) {
  const change = priceChange(points);
  return (
    <aside className="min-w-0">
      <SectionHeader title="价格" meta={holding.latestPrice?.date ?? "暂无"} />
      <div className="mt-2 rounded-lg border border-line bg-panel p-3">
        <div className="flex items-center justify-between gap-3 text-sm">
          <div className="inline-flex items-center gap-2 text-stone">
            <LineChartIcon className="h-4 w-4 text-brand" />
            <span>{formatPrice(holding.latestPrice)}</span>
          </div>
          <span className={`tabular-nums ${profitTone(change == null ? null : { value: change, currency: "%" })}`}>{formatPriceChange(change)}</span>
        </div>
        <div className="mt-3 h-28 min-w-0">
          {points.length >= 2 ? <PriceSparkline points={points} currency={holding.latestPrice?.currency ?? ""} /> : <EmptyInline text="暂无曲线" />}
        </div>
      </div>
    </aside>
  );
}

function PriceSparkline({ points, currency }: { points: PricePoint[]; currency: string }) {
  return (
    <div className="ledger-chart h-full min-w-0">
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={points} margin={{ left: 4, right: 4, top: 8, bottom: 8 }}>
          <YAxis hide domain={["dataMin", "dataMax"]} />
          <Tooltip
            formatter={(value) => [formatMoney(Number(value), currency || "CNY"), "价格"]}
            labelFormatter={(label) => String(label)}
            contentStyle={{ borderColor: "var(--line)", background: "var(--panel)", color: "var(--ink)", borderRadius: 8 }}
          />
          <Line type="monotone" dataKey="price" stroke="var(--chart-primary)" strokeWidth={2.25} dot={false} activeDot={{ r: 4 }} isAnimationActive={false} />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}

function SummaryMetric({ label, value, detail, tone }: { label: string; value: string; detail: string; tone: string }) {
  return (
    <div className="min-w-0 px-4 py-4 sm:px-5">
      <div className="ledger-label">{label}</div>
      <div className={`mt-1 truncate text-2xl font-medium tabular-nums ${tone}`}>{value}</div>
      <div className="mt-1 truncate text-xs text-stone">{detail}</div>
    </div>
  );
}

function RowMetric({ label, value, tone = "text-warm" }: { label: string; value: string; tone?: string }) {
  return (
    <div className="grid min-w-0 grid-cols-[88px_1fr] items-baseline gap-3 md:block">
      <div className="ledger-label md:hidden">{label}</div>
      <div className={`truncate text-right font-medium tabular-nums ${tone}`}>{value}</div>
    </div>
  );
}

function SectionHeader({ title, meta }: { title: string; meta: string }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <h3 className="text-sm font-semibold text-ink">{title}</h3>
      <span className="ledger-label shrink-0">{meta}</span>
    </div>
  );
}

function SecurityName({ symbol, name }: { symbol: string; name: string }) {
  return (
    <div className="min-w-0">
      <div className="text-lg font-semibold leading-tight text-ink">{symbol}</div>
      <div className="mt-1 truncate text-xs text-stone">{name}</div>
    </div>
  );
}

function Badge({ children }: { children: ReactNode }) {
  return <span className="ledger-chip rounded-md px-2 py-1">{children}</span>;
}

function TableHead({ children, align = "right" }: { children: string; align?: "left" | "right" }) {
  return <th className={`border-b border-line px-3 py-2 font-medium ${align === "left" ? "text-left" : "text-right"}`}>{children}</th>;
}

function TableCell({ children, align = "right", strong = false }: { children: ReactNode; align?: "left" | "right"; strong?: boolean }) {
  return <td className={`border-b border-line px-3 py-3 align-middle tabular-nums ${align === "left" ? "text-left" : "text-right"} ${strong ? "font-semibold text-olive" : "text-warm"}`}>{children}</td>;
}

function EmptyState({ text }: { text: string }) {
  return <div className="m-4 rounded-lg border border-line bg-paper p-6 text-center text-sm text-stone">{text}</div>;
}

function EmptyInline({ text }: { text: string }) {
  return <div className="grid h-full min-h-20 place-items-center rounded-lg border border-dashed border-line bg-paper px-3 py-4 text-xs text-stone">{text}</div>;
}

function investmentHoldings(investments: InvestmentSummary | null): InvestmentHolding[] {
  if (!investments) return [];
  if (investments.holdings?.length) return investments.holdings.filter(isVisibleHolding);
  return legacyHoldings(investments.positions ?? [], investments.quotes ?? []);
}

function legacyHoldings(positions: InvestmentPosition[], quotes: InvestmentQuote[]): InvestmentHolding[] {
  const byCommodity = new Map<string, InvestmentHolding>();
  for (const quote of quotes) {
    byCommodity.set(quote.commodity, {
      commodity: quote.commodity,
      commodityName: quote.commodityName,
      latestPrice: quote.latestPrice,
      priceHistory: quote.latestPrice ? [quote.latestPrice] : [],
      totalQuantity: quote.positionQuantity,
      marketCurrency: quote.latestPrice?.currency,
      totalMarketValueCny: quote.marketValueCny,
      accountCount: quote.positionCount,
      positions: [],
      lots: [],
    });
  }
  for (const position of positions) {
    const current = byCommodity.get(position.commodity) ?? {
      commodity: position.commodity,
      commodityName: position.commodityName,
      latestPrice: position.latestPrice,
      priceHistory: position.latestPrice ? [position.latestPrice] : [],
      totalQuantity: 0,
      marketCurrency: position.marketCurrency,
      accountCount: 0,
      positions: [],
      lots: [],
    };
    current.positions = current.positions ?? [];
    current.positions.push(position);
    current.lots = [...(current.lots ?? []), ...(position.lots ?? [])];
    current.totalQuantity += position.quantity;
    current.accountCount = current.positions.length;
    if (position.marketValue != null && position.marketCurrency) {
      current.marketCurrency = position.marketCurrency;
      current.totalMarketValue = (current.totalMarketValue ?? 0) + position.marketValue;
    }
    if (position.costValue != null && position.costCurrency) {
      if (!current.costCurrency || current.costCurrency === position.costCurrency) {
        current.costCurrency = position.costCurrency;
        current.totalCostValue = (current.totalCostValue ?? 0) + position.costValue;
        current.averageCost = current.totalQuantity ? current.totalCostValue / current.totalQuantity : undefined;
      } else {
        current.costCurrency = undefined;
        current.totalCostValue = undefined;
        current.averageCost = undefined;
      }
    }
    if (position.costValueCny != null) current.totalCostValueCny = (current.totalCostValueCny ?? 0) + position.costValueCny;
    byCommodity.set(position.commodity, current);
  }
  return [...byCommodity.values()].filter(isVisibleHolding).sort((left, right) => (right.totalMarketValueCny ?? 0) - (left.totalMarketValueCny ?? 0) || left.commodity.localeCompare(right.commodity));
}

function isVisibleHolding(holding: InvestmentHolding) {
  return holding.commodity.trim() !== "" && Math.abs(holding.totalQuantity) > 0;
}

function pricePoints(history?: CommodityPrice[] | null): PricePoint[] {
  return (history ?? []).map((price) => ({ date: price.date, price: price.amount }));
}

function priceChange(points: PricePoint[]) {
  if (points.length < 2) return null;
  const first = points[0]?.price;
  const last = points[points.length - 1]?.price;
  if (!first || last == null) return null;
  return (last - first) / first;
}

function holdingProfit(holding: InvestmentHolding): MoneyValue | null {
  if (holding.totalMarketValue == null || holding.totalCostValue == null || !holding.marketCurrency || holding.marketCurrency !== holding.costCurrency) {
    return null;
  }
  return { value: holding.totalMarketValue - holding.totalCostValue, currency: holding.marketCurrency };
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

function countHoldingsWithCost(holdings: InvestmentHolding[]) {
  return holdings.filter((holding) => holding.totalCostValueCny != null || (holding.totalCostValue != null && Boolean(holding.costCurrency))).length;
}

function countHoldingsWithProfit(holdings: InvestmentHolding[]) {
  return holdings.filter((holding) => (holding.totalMarketValueCny != null && holding.totalCostValueCny != null) || holdingProfit(holding) != null).length;
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

function profitTone(value: MoneyValue | null) {
  if (!value) return "text-stone";
  if (value.value > 0) return "amount-income";
  if (value.value < 0) return "amount-expense";
  return "text-stone";
}

function latestPriceDate(holdings: InvestmentHolding[]) {
  return holdings.reduce((latest, holding) => {
    const date = holding.latestPrice?.date ?? "";
    return date > latest ? date : latest;
  }, "");
}
