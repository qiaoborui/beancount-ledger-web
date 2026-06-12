import { formatCny, formatCompactCny, formatCompactMoney, formatMoney } from "@/lib/money";
import type { ReactNode } from "react";
import type { CommodityPrice, InvestmentPosition, InvestmentQuote, InvestmentSummary } from "./types";

export function InvestmentsPage({ investments }: { investments: InvestmentSummary | null }) {
  const positions = investments?.positions ?? [];
  const quotes = investments?.quotes ?? [];
  const pricedQuotes = quotes.filter((quote) => quote.latestPrice);
  const heldSymbols = positions.filter((position) => Math.abs(position.quantity) > 0).length;
  const latestDate = investments?.updatedAt || latestPriceDate(quotes);

  return (
    <>
      <section className="card p-4">
        <div className="grid gap-3 md:grid-cols-[1.2fr_0.8fr_0.8fr]">
          <SummaryBlock label="持仓市值" value={formatCompactCny((investments?.totalMarketValueCny ?? 0) / 100)} detail={latestDate ? `价格更新 ${latestDate}` : "暂无价格"} tone="amount-gold" />
          <SummaryBlock label="持仓标的" value={`${heldSymbols}`} detail={`${positions.length} 个账户持仓`} tone="text-olive" />
          <SummaryBlock label="行情标的" value={`${pricedQuotes.length}`} detail={`${quotes.length} 个商品定义`} tone="text-olive" />
        </div>
      </section>

      <section className="card mt-6 p-4">
        <div className="flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <h2 className="font-serif text-2xl">当前持仓</h2>
            <p className="mt-1 text-sm text-olive">按折算市值排序，价格使用最新 price 指令。</p>
          </div>
          <div className="text-xs uppercase tracking-[0.2em] text-stone">positions</div>
        </div>
        {positions.length ? (
          <>
            <div className="mt-4 space-y-3 md:hidden">
              {positions.map((position) => <PositionCard key={`${position.account}:${position.commodity}`} position={position} />)}
            </div>
            <div className="mt-4 hidden overflow-x-auto md:block">
              <table className="w-full min-w-[760px] border-separate border-spacing-0 text-sm">
                <thead className="text-xs uppercase tracking-[0.14em] text-stone">
                  <tr>
                    <TableHead align="left">标的</TableHead>
                    <TableHead align="left">账户</TableHead>
                    <TableHead>数量</TableHead>
                    <TableHead>最新价</TableHead>
                    <TableHead>市值</TableHead>
                    <TableHead>CNY 折算</TableHead>
                  </tr>
                </thead>
                <tbody>
                  {positions.map((position) => (
                    <tr key={`${position.account}:${position.commodity}`} className="border-b border-line">
                      <TableCell align="left"><SecurityName symbol={position.commodity} name={position.commodityName} /></TableCell>
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
          </>
        ) : <EmptyState text="暂无证券持仓" />}
      </section>

      <section className="card mt-6 p-4">
        <div className="flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <h2 className="font-serif text-2xl">行情清单</h2>
            <p className="mt-1 text-sm text-olive">来自 commodities.bean 与 prices.bean。</p>
          </div>
          <div className="text-xs uppercase tracking-[0.2em] text-stone">quotes</div>
        </div>
        {quotes.length ? (
          <div className="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {quotes.map((quote) => <QuoteCard key={quote.commodity} quote={quote} />)}
          </div>
        ) : <EmptyState text="暂无证券商品" />}
      </section>
    </>
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

function PositionCard({ position }: { position: InvestmentPosition }) {
  return (
    <div className="rounded-2xl border border-line bg-panel p-4">
      <div className="flex items-start justify-between gap-3">
        <SecurityName symbol={position.commodity} name={position.commodityName} />
        <div className="amount-gold shrink-0 text-right text-lg font-semibold">{formatCnyValue(position.marketValueCny)}</div>
      </div>
      <div className="mt-3 grid grid-cols-2 gap-3 text-sm">
        <Fact label="数量" value={formatQuantity(position.quantity)} />
        <Fact label="最新价" value={formatPrice(position.latestPrice)} />
        <Fact label="原币市值" value={formatMarketValue(position.marketValue, position.marketCurrency)} />
        <Fact label="价格日" value={position.latestPrice?.date ?? "暂无"} />
      </div>
      <div className="mt-3 truncate text-xs text-stone">{position.accountLabel} · {position.account}</div>
    </div>
  );
}

function QuoteCard({ quote }: { quote: InvestmentQuote }) {
  return (
    <div className="rounded-2xl border border-line bg-panel p-4">
      <div className="flex items-start justify-between gap-3">
        <SecurityName symbol={quote.commodity} name={quote.commodityName} />
        <div className="text-right">
          <div className="font-medium text-olive">{formatPrice(quote.latestPrice)}</div>
          <div className="mt-0.5 text-xs text-stone">{quote.latestPrice?.date ?? "暂无价格"}</div>
        </div>
      </div>
      <div className="mt-4 grid grid-cols-3 gap-2 text-sm">
        <Fact label="持仓数" value={`${quote.positionCount}`} />
        <Fact label="份额" value={formatQuantity(quote.positionQuantity)} />
        <Fact label="CNY" value={formatCnyValue(quote.marketValueCny)} />
      </div>
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

function Fact({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0 rounded-xl border border-line bg-paper px-3 py-2">
      <div className="text-xs text-stone">{label}</div>
      <div className="mt-1 truncate text-right font-medium text-olive [font-variant-numeric:tabular-nums]">{value}</div>
    </div>
  );
}

function TableHead({ children, align = "right" }: { children: string; align?: "left" | "right" }) {
  return <th className={`border-b border-line px-3 py-2 font-medium ${align === "left" ? "text-left" : "text-right"}`}>{children}</th>;
}

function TableCell({ children, align = "right", strong = false }: { children: ReactNode; align?: "left" | "right"; strong?: boolean }) {
  return <td className={`border-b border-line px-3 py-3 align-middle [font-variant-numeric:tabular-nums] ${align === "left" ? "text-left" : "text-right"} ${strong ? "font-semibold text-olive" : "text-warm"}`}>{children}</td>;
}

function EmptyState({ text }: { text: string }) {
  return <div className="mt-4 rounded-2xl border border-line bg-panel p-6 text-center text-sm text-stone">{text}</div>;
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

function latestPriceDate(quotes: InvestmentQuote[]) {
  return quotes.reduce((latest, quote) => {
    const date = quote.latestPrice?.date ?? "";
    return date > latest ? date : latest;
  }, "");
}
