import { AlertTriangle, Coins } from "lucide-react";
import { useMemo } from "react";
import { Line, LineChart, ResponsiveContainer, Tooltip, YAxis } from "recharts";
import type { AccountBalance, AccountView, Price } from "./types";

type RateSource = "base" | "direct" | "inverse" | "bridge";
type RateInfo = { rate: number; date: string | null; source: RateSource } | null;
type RatePoint = { date: string; rate: number };

export function CurrencyPage({
  commodities,
  prices,
  accountBalances,
  accounts,
  valuationCurrency,
  onValuationCurrencyChange,
}: {
  commodities: string[];
  prices: Price[];
  accountBalances: AccountBalance[];
  accounts: AccountView[];
  valuationCurrency: string;
  sensitiveUnlocked: boolean;
  onUnlockSensitive: () => void;
  onValuationCurrencyChange: (currency: string) => void;
}) {
  const currencyOptions = useMemo(() => currencyUniverse(commodities, prices, accountBalances, accounts, valuationCurrency), [accountBalances, accounts, commodities, prices, valuationCurrency]);
  const latestPriceDate = prices.reduce<string | null>((latest, price) => latest == null || price.date > latest ? price.date : latest, null);

  const rows = useMemo(() => currencyOptions.map((currency) => {
    const rate = latestRate(currency, valuationCurrency, prices);
    return {
      currency,
      rate,
      history: rateHistory(currency, valuationCurrency, prices).slice(-90),
    };
  }), [currencyOptions, prices, valuationCurrency]);

  const missingRateCount = rows.filter((row) => row.currency !== valuationCurrency && !row.rate).length;
  return <div className="space-y-4">
    <section className="card p-4 md:p-5">
      <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div className="min-w-0">
          <div className="inline-flex items-center gap-2 rounded-full border border-line bg-paper px-3 py-1 text-xs uppercase text-stone">
            <Coins className="h-3.5 w-3.5 text-brand" />
            fx rates
          </div>
          <h2 className="mt-3 font-serif text-3xl font-medium text-ink">当前汇率</h2>
          <p className="mt-2 text-sm leading-6 text-olive">
            以 <strong className="text-ink">{valuationCurrency}</strong> 为估值口径，展示每个币种的最新换算和历史曲线。
            {latestPriceDate ? <span className="text-stone"> 最新价格日期 {latestPriceDate}。</span> : <span className="text-stone"> 暂无价格记录。</span>}
          </p>
        </div>
        <div className="min-w-0">
          <div className="mb-2 text-xs uppercase text-stone">估值币种</div>
          <div className="flex max-w-full gap-2 overflow-x-auto pb-1">
            {currencyOptions.map((currency) => {
              const active = currency === valuationCurrency;
              return <button key={currency} type="button" className={`shrink-0 rounded-xl border px-3 py-2 text-sm font-medium transition-colors ${active ? "border-brand bg-[var(--selected-bg)] text-ink ring-1 ring-brand/20" : "border-line bg-paper text-olive hover:bg-tag"}`} onClick={() => onValuationCurrencyChange(currency)} aria-pressed={active}>
                {currency}
              </button>;
            })}
          </div>
        </div>
      </div>
    </section>

    {missingRateCount > 0 && <section className="rounded-2xl border border-[var(--warning)]/40 bg-[var(--warning)]/10 p-4 text-sm leading-6 text-olive">
      <AlertTriangle className="mr-2 inline h-4 w-4 text-[var(--warning)]" />
      {missingRateCount} 个币种缺少到 {valuationCurrency} 的价格，无法生成当前汇率。
    </section>}

    <section className="card overflow-hidden p-0">
      <div className="hidden grid-cols-[120px_minmax(220px,1fr)_120px_minmax(220px,0.9fr)] gap-4 border-b border-line bg-paper px-5 py-3 text-xs uppercase text-stone md:grid">
        <div>币种</div>
        <div>当前汇率</div>
        <div className="text-right">最近变化</div>
        <div>曲线</div>
      </div>
      <div className="divide-y divide-line">
        {rows.length === 0 ? <div className="p-5 text-sm text-stone">暂无可展示币种。</div> : rows.map((row) => <CurrencyRateRow key={row.currency} row={row} valuationCurrency={valuationCurrency} />)}
      </div>
    </section>
  </div>;
}

function CurrencyRateRow({ row, valuationCurrency }: { row: { currency: string; rate: RateInfo; history: RatePoint[] }; valuationCurrency: string }) {
  const change = rateChange(row.history);
  return <article className="grid gap-4 bg-panel p-4 md:grid-cols-[120px_minmax(220px,1fr)_120px_minmax(220px,0.9fr)] md:items-center md:px-5">
    <div className="flex items-center justify-between gap-3 md:block">
      <div className="font-serif text-2xl font-medium text-ink">{row.currency}</div>
      <RateSourceBadge currency={row.currency} valuationCurrency={valuationCurrency} rate={row.rate} />
    </div>
    <div className="min-w-0">
      <div className="text-xl font-semibold tabular-nums text-ink md:text-2xl">{rateValue(row.currency, valuationCurrency, row.rate)}</div>
      <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-stone">
        <span>{rateDate(row.rate)}</span>
        <span className="hidden md:inline">·</span>
        <span>{rateSourceLabel(row.rate)}</span>
      </div>
    </div>
    <div className={`text-sm font-medium tabular-nums md:text-right ${changeTone(change)}`}>{formatRateChange(change)}</div>
    <div className="h-24 min-w-0 md:h-20">
      {row.history.length >= 2 ? <RateSparkline points={row.history} valuationCurrency={valuationCurrency} currency={row.currency} /> : <div className="grid h-full place-items-center rounded-xl border border-dashed border-line bg-paper text-xs text-stone">暂无曲线</div>}
    </div>
  </article>;
}

function RateSparkline({ points, currency, valuationCurrency }: { points: RatePoint[]; currency: string; valuationCurrency: string }) {
  return <div className="ledger-chart h-full min-w-0">
    <ResponsiveContainer width="100%" height="100%">
      <LineChart data={points} margin={{ left: 4, right: 4, top: 8, bottom: 8 }}>
        <YAxis hide domain={["dataMin", "dataMax"]} />
        <Tooltip
          formatter={(value) => [`${formatRateNumber(Number(value))} ${valuationCurrency}`, `1 ${currency}`]}
          labelFormatter={(label) => String(label)}
          contentStyle={{ borderColor: "var(--line)", background: "var(--panel)", color: "var(--ink)", borderRadius: 12 }}
        />
        <Line type="monotone" dataKey="rate" stroke="var(--chart-primary)" strokeWidth={2.5} dot={false} activeDot={{ r: 4 }} isAnimationActive={false} />
      </LineChart>
    </ResponsiveContainer>
  </div>;
}

function RateSourceBadge({ currency, valuationCurrency, rate }: { currency: string; valuationCurrency: string; rate: RateInfo }) {
  if (currency === valuationCurrency) return <span className="rounded-full bg-brand px-2.5 py-1 text-xs font-medium text-paper">基准</span>;
  if (!rate) return <span className="rounded-full bg-[var(--danger)]/10 px-2.5 py-1 text-xs font-medium text-[var(--danger)]">缺汇率</span>;
  return <span className="rounded-full bg-tag px-2.5 py-1 text-xs font-medium text-olive">{rateSourceLabel(rate)}</span>;
}

function rateValue(currency: string, valuationCurrency: string, rate: RateInfo) {
  if (currency === valuationCurrency) return `1 ${currency} = 1 ${valuationCurrency}`;
  if (!rate) return `缺少 ${currency}/${valuationCurrency}`;
  return `1 ${currency} = ${formatRateNumber(rate.rate)} ${valuationCurrency}`;
}

function rateDate(rate: RateInfo) {
  if (!rate) return "没有可用价格";
  if (!rate.date) return "当前基准";
  return rate.date;
}

function rateSourceLabel(rate: RateInfo) {
  if (!rate) return "无法估值";
  if (rate.source === "base") return "同币种";
  if (rate.source === "bridge") return "交叉汇率";
  if (rate.source === "inverse") return "反向价格";
  return "直接价格";
}

function rateChange(points: RatePoint[]) {
  if (points.length < 2) return null;
  const previous = points[points.length - 2]?.rate;
  const current = points[points.length - 1]?.rate;
  if (!previous || current == null) return null;
  return (current - previous) / previous;
}

function formatRateChange(change: number | null) {
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

function currencyUniverse(commodities: string[], prices: Price[], balances: AccountBalance[], accounts: AccountView[], valuationCurrency: string) {
  const monetary = monetaryCommoditySet(prices, valuationCurrency);
  const seen = new Set<string>([valuationCurrency, "CNY"]);
  for (const commodity of commodities) if (monetary.has(commodity)) seen.add(commodity);
  for (const price of prices) {
    if (monetary.has(price.currency)) seen.add(price.currency);
    if (monetary.has(price.quoteCurrency)) seen.add(price.quoteCurrency);
  }
  for (const balance of balances) if (monetary.has(balance.currency)) seen.add(balance.currency);
  for (const account of accounts) if (monetary.has(account.currency)) seen.add(account.currency);
  return [...seen].sort((a, b) => a === valuationCurrency ? -1 : b === valuationCurrency ? 1 : a.localeCompare(b));
}

function monetaryCommoditySet(prices: Price[], valuationCurrency: string) {
  const seen = new Set(["CNY", "USD", "HKD", "GBP", "EUR", "JPY", valuationCurrency]);
  for (const price of prices) {
    if (price.quoteCurrency) seen.add(price.quoteCurrency);
    if (price.quoteCurrency === "CNY" || price.currency === "CNY") seen.add(price.currency);
  }
  return seen;
}

function latestRate(currency: string, targetCurrency: string, prices: Price[]): RateInfo {
  if (currency === targetCurrency) return { rate: 1, date: null, source: "base" };
  const pair = pairRate(currency, targetCurrency, prices);
  if (pair) return pair;
  if (currency === "CNY" || targetCurrency === "CNY") return null;
  const currencyToCny = pairRate(currency, "CNY", prices);
  const targetToCny = pairRate(targetCurrency, "CNY", prices);
  if (!currencyToCny || !targetToCny || targetToCny.rate === 0) return null;
  return {
    rate: currencyToCny.rate / targetToCny.rate,
    date: latestDate(currencyToCny.date, targetToCny.date),
    source: "bridge",
  };
}

function rateHistory(currency: string, targetCurrency: string, prices: Price[]): RatePoint[] {
  if (currency === targetCurrency) {
    const dates = [...new Set(prices.map((price) => price.date))].sort();
    return (dates.length ? dates : ["current"]).map((date) => ({ date, rate: 1 }));
  }
  return [...new Set(prices.map((price) => price.date))]
    .sort()
    .map((date) => {
      const rate = rateAtDate(currency, targetCurrency, prices, date);
      return rate ? { date, rate: rate.rate } : null;
    })
    .filter((point): point is RatePoint => point != null);
}

function rateAtDate(currency: string, targetCurrency: string, prices: Price[], date: string): RateInfo {
  const pair = pairRateAtDate(currency, targetCurrency, prices, date);
  if (pair) return pair;
  if (currency === "CNY" || targetCurrency === "CNY") return null;
  const currencyToCny = pairRateAtDate(currency, "CNY", prices, date);
  const targetToCny = pairRateAtDate(targetCurrency, "CNY", prices, date);
  if (!currencyToCny || !targetToCny || targetToCny.rate === 0) return null;
  return {
    rate: currencyToCny.rate / targetToCny.rate,
    date: latestDate(currencyToCny.date, targetToCny.date),
    source: "bridge",
  };
}

function pairRate(currency: string, targetCurrency: string, prices: Price[]): RateInfo {
  const direct = latestPair(currency, targetCurrency, prices);
  if (direct) return { rate: direct.amount / 100, date: direct.date, source: "direct" };
  const inverse = latestPair(targetCurrency, currency, prices);
  if (!inverse || inverse.amount === 0) return null;
  return { rate: 100 / inverse.amount, date: inverse.date, source: "inverse" };
}

function pairRateAtDate(currency: string, targetCurrency: string, prices: Price[], date: string): RateInfo {
  const direct = latestPairAtOrBefore(currency, targetCurrency, prices, date);
  if (direct) return { rate: direct.amount / 100, date: direct.date, source: "direct" };
  const inverse = latestPairAtOrBefore(targetCurrency, currency, prices, date);
  if (!inverse || inverse.amount === 0) return null;
  return { rate: 100 / inverse.amount, date: inverse.date, source: "inverse" };
}

function latestPair(currency: string, quoteCurrency: string, prices: Price[]) {
  return prices.reduce<Price | null>((latest, price) => {
    if (price.currency !== currency || price.quoteCurrency !== quoteCurrency) return latest;
    if (latest == null || price.date >= latest.date) return price;
    return latest;
  }, null);
}

function latestPairAtOrBefore(currency: string, quoteCurrency: string, prices: Price[], date: string) {
  return prices.reduce<Price | null>((latest, price) => {
    if (price.currency !== currency || price.quoteCurrency !== quoteCurrency || price.date > date) return latest;
    if (latest == null || price.date >= latest.date) return price;
    return latest;
  }, null);
}

function latestDate(a: string | null, b: string | null) {
  if (!a) return b;
  if (!b) return a;
  return a > b ? a : b;
}

function formatRateNumber(value: number) {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: value >= 1 ? 4 : 6, minimumFractionDigits: value >= 1 ? 2 : 4 }).format(value);
}
