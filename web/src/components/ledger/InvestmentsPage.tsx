import { formatCny, formatCompactCny, formatCompactMoney, formatMoney } from "@/lib/money";
import { ChevronDown, LineChart as LineChartIcon } from "lucide-react";
import { useMemo, useState, type ReactNode } from "react";
import { Line, LineChart, ResponsiveContainer, Tooltip, YAxis } from "recharts";
import type { CommodityPrice, InvestmentHolding, InvestmentPosition, InvestmentQuote, InvestmentSummary } from "./types";

type PricePoint = { date: string; price: number };

export function InvestmentsPage({ investments }: { investments: InvestmentSummary | null }) {
  const holdings = useMemo(() => investmentHoldings(investments), [investments]);
  const [openHoldings, setOpenHoldings] = useState<Record<string, boolean>>({});
  const positions = investments?.positions ?? [];
  const heldHoldings = holdings.filter((holding) => Math.abs(holding.totalQuantity) > 0);
  const pricedHoldings = holdings.filter((holding) => holding.latestPrice);
  const latestDate = investments?.updatedAt || latestPriceDate(holdings);
  const accountCount = new Set(positions.map((position) => position.account)).size;

  return (
    <>
      <section className="card p-4">
        <div className="grid gap-3 md:grid-cols-[1.2fr_0.8fr_0.8fr]">
          <SummaryBlock label="持仓市值" value={formatCompactCny((investments?.totalMarketValueCny ?? 0) / 100)} detail={latestDate ? `价格更新 ${latestDate}` : "暂无价格"} tone="amount-gold" />
          <SummaryBlock label="持仓股票" value={`${heldHoldings.length}`} detail={`${accountCount} 个账户持有证券`} tone="text-olive" />
          <SummaryBlock label="股票池" value={`${holdings.length}`} detail={`${pricedHoldings.length} 个有价格曲线`} tone="text-olive" />
        </div>
      </section>

      <section className="card mt-6 overflow-hidden p-0">
        <div className="border-b border-line bg-paper px-4 py-4 sm:px-5">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h2 className="font-serif text-2xl">股票持仓</h2>
              <p className="mt-1 text-sm text-olive">按股票聚合持仓，同一只股票下展开查看账户拆分。</p>
            </div>
            <div className="inline-flex w-fit items-center gap-2 rounded-full border border-line bg-panel px-3 py-1 text-xs text-stone">
              <LineChartIcon className="h-3.5 w-3.5 text-brand" />
              price history
            </div>
          </div>
        </div>

        {holdings.length ? (
          <div className="divide-y divide-line">
            {holdings.map((holding) => {
              const expanded = openHoldings[holding.commodity] ?? holding.accountCount > 1;
              return (
                <HoldingRow
                  key={holding.commodity}
                  holding={holding}
                  expanded={expanded}
                  onToggle={() => setOpenHoldings((current) => ({ ...current, [holding.commodity]: !expanded }))}
                />
              );
            })}
          </div>
        ) : <EmptyState text="暂无证券商品" />}
      </section>
    </>
  );
}

function HoldingRow({ holding, expanded, onToggle }: { holding: InvestmentHolding; expanded: boolean; onToggle: () => void }) {
  const points = pricePoints(holding.priceHistory).slice(-120);
  const change = priceChange(points);
  return (
    <article className="bg-panel px-4 py-4 sm:px-5">
      <div className="grid gap-4 md:grid-cols-[minmax(160px,1.1fr)_minmax(140px,0.8fr)_minmax(140px,0.8fr)_minmax(220px,1.2fr)_40px] md:items-center">
        <div className="min-w-0">
          <SecurityName symbol={holding.commodity} name={holding.commodityName} />
          <div className="mt-2 flex flex-wrap gap-2 text-xs text-stone">
            <Badge>{holding.accountCount > 0 ? `${holding.accountCount} 个账户` : "仅价格记录"}</Badge>
            <Badge>{holding.latestPrice?.date ?? "暂无价格"}</Badge>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-3 md:block">
          <Fact label="总份额" value={formatQuantity(holding.totalQuantity)} />
          <Fact label="最新价" value={formatPrice(holding.latestPrice)} />
        </div>

        <div className="grid grid-cols-2 gap-3 md:block">
          <Fact label="原币市值" value={formatMarketValue(holding.totalMarketValue, holding.marketCurrency)} />
          <Fact label="CNY 折算" value={formatCnyValue(holding.totalMarketValueCny)} strong />
        </div>

        <div className="min-w-0">
          <div className="mb-2 flex items-center justify-between gap-3 text-xs text-stone">
            <span>价格曲线</span>
            <span className={`tabular-nums ${changeTone(change)}`}>{formatPriceChange(change)}</span>
          </div>
          <div className="h-24 min-w-0 md:h-20">
            {points.length >= 2 ? <PriceSparkline points={points} currency={holding.latestPrice?.currency ?? ""} /> : <div className="grid h-full place-items-center rounded-xl border border-dashed border-line bg-paper text-xs text-stone">暂无曲线</div>}
          </div>
        </div>

        <button type="button" className="hidden h-10 w-10 items-center justify-center rounded-xl border border-line bg-paper text-stone transition-colors hover:bg-tag md:flex" onClick={onToggle} aria-expanded={expanded} aria-label={`${holding.commodity} 账户明细`}>
          <ChevronDown className={`h-4 w-4 transition-transform ${expanded ? "rotate-180" : ""}`} />
        </button>
      </div>

      <button type="button" className="mt-4 flex h-10 w-full items-center justify-center gap-2 rounded-xl border border-line bg-paper text-sm font-medium text-olive transition-colors hover:bg-tag md:hidden" onClick={onToggle} aria-expanded={expanded}>
        账户明细
        <ChevronDown className={`h-4 w-4 transition-transform ${expanded ? "rotate-180" : ""}`} />
      </button>

      {expanded && (
        <div className="mt-4 rounded-2xl border border-line bg-paper p-3">
          {holding.positions.length ? <PositionBreakdown positions={holding.positions} /> : <div className="p-3 text-sm text-stone">暂无账户持仓。</div>}
        </div>
      )}
    </article>
  );
}

function PositionBreakdown({ positions }: { positions: InvestmentPosition[] }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[620px] border-separate border-spacing-0 text-sm">
        <thead className="text-xs uppercase tracking-[0.14em] text-stone">
          <tr>
            <TableHead align="left">账户</TableHead>
            <TableHead>份额</TableHead>
            <TableHead>最新价</TableHead>
            <TableHead>原币市值</TableHead>
            <TableHead>CNY 折算</TableHead>
          </tr>
        </thead>
        <tbody>
          {positions.map((position) => (
            <tr key={`${position.account}:${position.commodity}`} className="border-b border-line">
              <TableCell align="left"><div className="max-w-72 truncate text-olive">{position.accountLabel}</div><div className="max-w-72 truncate text-xs text-stone">{position.account}</div></TableCell>
              <TableCell>{formatQuantity(position.quantity)}</TableCell>
              <TableCell>{formatPrice(position.latestPrice)}</TableCell>
              <TableCell>{formatMarketValue(position.marketValue, position.marketCurrency)}</TableCell>
              <TableCell strong>{formatCnyValue(position.marketValueCny)}</TableCell>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
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
            contentStyle={{ borderColor: "var(--line)", background: "var(--panel)", color: "var(--ink)", borderRadius: 12 }}
          />
          <Line type="monotone" dataKey="price" stroke="var(--chart-primary)" strokeWidth={2.5} dot={false} activeDot={{ r: 4 }} isAnimationActive={false} />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}

function SummaryBlock({ label, value, detail, tone }: { label: string; value: string; detail: string; tone: string }) {
  return (
    <div className="rounded-2xl border border-line bg-panel p-4">
      <div className="text-[11px] uppercase tracking-[0.14em] text-stone">{label}</div>
      <div className={`mt-2 truncate font-serif text-3xl font-medium ${tone}`}>{value}</div>
      <div className="mt-1 text-xs text-stone">{detail}</div>
    </div>
  );
}

function SecurityName({ symbol, name }: { symbol: string; name: string }) {
  return (
    <div className="min-w-0">
      <div className="font-semibold text-ink">{symbol}</div>
      <div className="mt-0.5 truncate text-xs text-stone">{name}</div>
    </div>
  );
}

function Fact({ label, value, strong = false }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="min-w-0 md:mb-2 md:last:mb-0">
      <div className="text-xs text-stone">{label}</div>
      <div className={`mt-1 truncate text-right font-medium [font-variant-numeric:tabular-nums] md:text-left ${strong ? "text-olive" : "text-warm"}`}>{value}</div>
    </div>
  );
}

function Badge({ children }: { children: ReactNode }) {
  return <span className="rounded-full border border-line bg-paper px-2.5 py-1">{children}</span>;
}

function TableHead({ children, align = "right" }: { children: string; align?: "left" | "right" }) {
  return <th className={`border-b border-line px-3 py-2 font-medium ${align === "left" ? "text-left" : "text-right"}`}>{children}</th>;
}

function TableCell({ children, align = "right", strong = false }: { children: ReactNode; align?: "left" | "right"; strong?: boolean }) {
  return <td className={`border-b border-line px-3 py-3 align-middle [font-variant-numeric:tabular-nums] ${align === "left" ? "text-left" : "text-right"} ${strong ? "font-semibold text-olive" : "text-warm"}`}>{children}</td>;
}

function EmptyState({ text }: { text: string }) {
  return <div className="m-4 rounded-2xl border border-line bg-panel p-6 text-center text-sm text-stone">{text}</div>;
}

function investmentHoldings(investments: InvestmentSummary | null): InvestmentHolding[] {
  if (!investments) return [];
  if (investments.holdings?.length) return investments.holdings;
  return legacyHoldings(investments.positions, investments.quotes);
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
    };
    current.positions.push(position);
    current.totalQuantity += position.quantity;
    current.accountCount = current.positions.length;
    byCommodity.set(position.commodity, current);
  }
  return [...byCommodity.values()].sort((left, right) => (right.totalMarketValueCny ?? 0) - (left.totalMarketValueCny ?? 0) || left.commodity.localeCompare(right.commodity));
}

function pricePoints(history: CommodityPrice[]): PricePoint[] {
  return history.map((price) => ({ date: price.date, price: price.amount }));
}

function priceChange(points: PricePoint[]) {
  if (points.length < 2) return null;
  const first = points[0]?.price;
  const last = points[points.length - 1]?.price;
  if (!first || last == null) return null;
  return (last - first) / first;
}

function formatQuantity(value: number) {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 6 }).format(value);
}

function formatPrice(price?: CommodityPrice) {
  if (!price) return "暂无";
  return formatMoney(price.amount, price.currency);
}

function formatMarketValue(value?: number, currency?: string) {
  if (value == null || !currency) return "暂无";
  return formatCompactMoney(value, currency);
}

function formatCnyValue(value?: number) {
  if (value == null) return "暂无";
  return formatCny(value / 100);
}

function formatPriceChange(change: number | null) {
  if (change == null) return "暂无变化";
  const sign = change > 0 ? "+" : "";
  return `${sign}${(change * 100).toFixed(2)}%`;
}

function changeTone(change: number | null) {
  if (change == null) return "text-stone";
  if (change > 0) return "amount-income";
  if (change < 0) return "amount-expense";
  return "text-stone";
}

function latestPriceDate(holdings: InvestmentHolding[]) {
  return holdings.reduce((latest, holding) => {
    const date = holding.latestPrice?.date ?? "";
    return date > latest ? date : latest;
  }, "");
}
