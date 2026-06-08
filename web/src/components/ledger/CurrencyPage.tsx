import { AlertTriangle, ArrowRightLeft, Coins, LockKeyhole, WalletCards } from "lucide-react";
import { useMemo } from "react";
import { formatMoney, formatValuation } from "@/lib/money";
import type { AccountBalance, AccountView, Price } from "./types";

type RateSource = "base" | "direct" | "inverse" | "bridge";
type RateInfo = { rate: number; date: string | null; source: RateSource } | null;

export function CurrencyPage({
  commodities,
  prices,
  accountBalances,
  accounts,
  valuationCurrency,
  sensitiveUnlocked,
  onUnlockSensitive,
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
  const accountMap = useMemo(() => new Map(accounts.map((account) => [account.account, account])), [accounts]);
  const currencyOptions = useMemo(() => currencyUniverse(commodities, prices, accountBalances, accounts, valuationCurrency), [accountBalances, accounts, commodities, prices, valuationCurrency]);
  const latestPriceDate = prices.reduce<string | null>((latest, price) => latest == null || price.date > latest ? price.date : latest, null);
  const balanceSummary = useMemo(() => summarizeBalances(accountBalances), [accountBalances]);

  const rows = useMemo(() => currencyOptions.map((currency) => {
    const balances = balanceSummary.get(currency);
    const accountCount = accounts.filter((account) => account.currency === currency).length;
    const rate = latestRate(currency, valuationCurrency, prices);
    return {
      currency,
      accountCount,
      nativeAmount: balances?.amount ?? 0,
      valuation: balances?.valuation ?? 0,
      missingValuations: balances?.missing ?? 0,
      balanceRows: balances?.rows ?? [],
      rate,
    };
  }), [accountBalances, accounts, balanceSummary, currencyOptions, prices, valuationCurrency]);

  const missingRateCount = rows.filter((row) => row.currency !== valuationCurrency && !row.rate).length;
  const missingValuationCount = rows.reduce((sum, row) => sum + row.missingValuations, 0);
  const latestPrices = [...prices].sort((a, b) => b.date.localeCompare(a.date)).slice(0, 12);

  return <div className="space-y-6">
    <section className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_340px]">
      <div className="card overflow-hidden p-5 md:p-6">
        <div className="flex flex-col gap-5 md:flex-row md:items-start md:justify-between">
          <div className="min-w-0">
            <div className="inline-flex items-center gap-2 rounded-full border border-line bg-paper px-3 py-1 text-xs uppercase tracking-[0.18em] text-stone">
              <Coins className="h-3.5 w-3.5 text-brand" />
              commodity book
            </div>
            <h2 className="mt-4 font-serif text-3xl font-medium text-ink md:text-4xl">多币种台账</h2>
            <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">当前以 <strong className="text-ink">{valuationCurrency}</strong> 汇总估值，原币余额按账户币种保留。</p>
          </div>
          <div className="grid min-w-0 grid-cols-2 gap-2 sm:grid-cols-4 lg:w-96 lg:grid-cols-2">
            <CurrencyStat label="币种" value={`${currencyOptions.length}`} />
            <CurrencyStat label="价格记录" value={`${prices.length}`} />
            <CurrencyStat label="最新价格" value={latestPriceDate ?? "无"} />
            <CurrencyStat label="缺失估值" value={`${missingRateCount + missingValuationCount}`} tone={missingRateCount + missingValuationCount > 0 ? "text-[var(--danger)]" : "text-ink"} />
          </div>
        </div>
        <div className="mt-6 flex flex-wrap gap-2">
          {currencyOptions.map((currency) => {
            const active = currency === valuationCurrency;
            return <button key={currency} type="button" className={`rounded-xl border px-3 py-2 text-sm font-medium ${active ? "border-brand bg-[var(--selected-bg)] text-ink ring-1 ring-brand/20" : "border-line bg-paper text-olive hover:bg-tag"}`} onClick={() => onValuationCurrencyChange(currency)} aria-pressed={active}>
              {currency}
            </button>;
          })}
        </div>
      </div>

      <div className="card p-5 md:p-6">
        <div className="flex items-center gap-3">
          <span className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-[var(--selected-bg)] text-brand"><ArrowRightLeft className="h-5 w-5" /></span>
          <div>
            <h3 className="font-serif text-2xl font-medium">估值口径</h3>
            <p className="text-sm text-stone">设置会同步影响总览、预算和净资产。</p>
          </div>
        </div>
        <div className="mt-5 rounded-2xl border border-line bg-paper p-4">
          <div className="text-xs uppercase tracking-[0.18em] text-stone">valuation currency</div>
          <div className="mt-2 font-serif text-4xl font-medium text-brand">{valuationCurrency}</div>
          <div className="mt-3 text-sm leading-6 text-olive">{latestPriceDate ? `最新价格日期 ${latestPriceDate}` : "没有价格记录时只会显示同币种估值。"}</div>
        </div>
      </div>
    </section>

    {(missingRateCount > 0 || missingValuationCount > 0) && <section className="rounded-2xl border border-[var(--warning)]/40 bg-[var(--warning)]/10 p-4 text-sm leading-6 text-olive">
      <AlertTriangle className="mr-2 inline h-4 w-4 text-[var(--warning)]" />
      {missingRateCount > 0 ? `${missingRateCount} 个币种缺少到 ${valuationCurrency} 的价格。` : ""}
      {missingValuationCount > 0 ? ` ${missingValuationCount} 条账户余额无法估值。` : ""}
    </section>}

    <section className="grid gap-3 lg:grid-cols-2 2xl:grid-cols-3">
      {rows.map((row) => <article key={row.currency} className="card p-4">
        <div className="flex items-start justify-between gap-3">
          <div>
            <div className="font-serif text-3xl font-medium text-ink">{row.currency}</div>
            <div className="mt-1 text-xs text-stone">{row.accountCount} 个账户 · {row.balanceRows.length} 条余额</div>
          </div>
          <RateBadge currency={row.currency} valuationCurrency={valuationCurrency} rate={row.rate} />
        </div>
        <div className="mt-5 grid grid-cols-2 gap-3">
          <CurrencyMetric label="原币余额" value={sensitiveUnlocked ? formatMoney(row.nativeAmount / 100, row.currency) : "••••••"} />
          <CurrencyMetric label={`折合 ${valuationCurrency}`} value={sensitiveUnlocked ? formatValuation(row.valuation / 100, valuationCurrency) : "••••••"} />
        </div>
        <div className="mt-4 rounded-xl border border-line bg-paper px-3 py-2 text-sm text-olive">
          {rateLine(row.currency, valuationCurrency, row.rate)}
        </div>
      </article>)}
    </section>

    <section className="grid gap-6 xl:grid-cols-[minmax(0,1.2fr)_minmax(360px,0.8fr)]">
      <div className="card overflow-hidden p-5 md:p-6">
        <div className="flex items-center gap-3">
          <span className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-[var(--selected-bg)] text-brand"><WalletCards className="h-5 w-5" /></span>
          <div>
            <h3 className="font-serif text-2xl font-medium">账户原币余额</h3>
            <p className="text-sm text-stone">按账户和币种展开。</p>
          </div>
        </div>
        {!sensitiveUnlocked ? <div className="mt-5 rounded-2xl border border-line bg-paper p-5 text-sm leading-6 text-olive">
          <LockKeyhole className="mr-2 inline h-4 w-4 text-brand" />
          账户余额已隐藏。
          <button type="button" className="ml-3 inline-flex items-center gap-1 rounded-xl border border-line bg-panel px-3 py-1.5 text-sm text-brand hover:bg-tag" onClick={onUnlockSensitive}>
            <LockKeyhole className="h-3.5 w-3.5" />
            解锁查看
          </button>
        </div> : <div className="mt-5 overflow-hidden rounded-2xl border border-line">
          {accountBalances.length === 0 ? <div className="bg-paper p-5 text-sm text-stone">暂无账户余额。</div> : accountBalances.map((balance) => {
            const account = accountMap.get(balance.account);
            return <div key={`${balance.account}:${balance.currency}`} className="grid gap-2 border-b border-line bg-paper p-4 text-sm last:border-b-0 md:grid-cols-[minmax(0,1fr)_160px_160px] md:items-center">
              <div className="min-w-0">
                <div className="truncate font-medium text-ink">{account?.label ?? balance.account}</div>
                <div className="mt-0.5 truncate text-xs text-stone">{balance.account}</div>
              </div>
              <div className="font-medium text-olive md:text-right">{formatMoney(balance.amount / 100, balance.currency)}</div>
              <div className={`font-medium md:text-right ${balance.valuationMissing ? "text-[var(--danger)]" : "text-ink"}`}>{balance.valuationMissing ? "缺少汇率" : formatValuation(balance.valuation / 100, valuationCurrency)}</div>
            </div>;
          })}
        </div>}
      </div>

      <div className="card p-5 md:p-6">
        <div className="flex items-center gap-3">
          <span className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-[var(--selected-bg)] text-brand"><ArrowRightLeft className="h-5 w-5" /></span>
          <div>
            <h3 className="font-serif text-2xl font-medium">价格记录</h3>
            <p className="text-sm text-stone">来自 prices.bean。</p>
          </div>
        </div>
        <div className="mt-5 divide-y divide-line rounded-2xl border border-line bg-paper">
          {latestPrices.length === 0 ? <div className="p-5 text-sm text-stone">暂无价格记录。</div> : latestPrices.map((price, index) => <div key={`${price.date}:${price.currency}:${price.quoteCurrency}:${index}`} className="flex items-center justify-between gap-3 p-4 text-sm">
            <div>
              <div className="font-medium text-ink">1 {price.currency} = {formatRateNumber(price.amount / 100)} {price.quoteCurrency}</div>
              <div className="mt-0.5 text-xs text-stone">{price.date}</div>
            </div>
            <span className="rounded-full bg-tag px-2 py-1 text-xs text-stone">{price.currency}/{price.quoteCurrency}</span>
          </div>)}
        </div>
      </div>
    </section>
  </div>;
}

function CurrencyStat({ label, value, tone = "text-ink" }: { label: string; value: string; tone?: string }) {
  return <div className="rounded-2xl border border-line bg-paper p-3">
    <div className="text-[11px] uppercase tracking-[0.16em] text-stone">{label}</div>
    <div className={`mt-1 truncate font-serif text-xl font-medium ${tone}`}>{value}</div>
  </div>;
}

function CurrencyMetric({ label, value }: { label: string; value: string }) {
  return <div className="min-w-0 rounded-xl bg-paper p-3">
    <div className="text-[11px] uppercase tracking-[0.14em] text-stone">{label}</div>
    <div className="mt-1 truncate text-sm font-medium text-ink">{value}</div>
  </div>;
}

function RateBadge({ currency, valuationCurrency, rate }: { currency: string; valuationCurrency: string; rate: RateInfo }) {
  if (currency === valuationCurrency) return <span className="rounded-full bg-brand px-2.5 py-1 text-xs font-medium text-paper">基准</span>;
  if (!rate) return <span className="rounded-full bg-[var(--danger)]/10 px-2.5 py-1 text-xs font-medium text-[var(--danger)]">缺汇率</span>;
  const label = rate.source === "bridge" ? "交叉汇率" : rate.source === "inverse" ? "反向价格" : "直接价格";
  return <span className="rounded-full bg-tag px-2.5 py-1 text-xs font-medium text-olive">{label}</span>;
}

function rateLine(currency: string, valuationCurrency: string, rate: RateInfo) {
  if (currency === valuationCurrency) return `1 ${currency} = 1 ${valuationCurrency}`;
  if (!rate) return `没有 ${currency} 到 ${valuationCurrency} 的可用价格`;
  return `1 ${currency} = ${formatRateNumber(rate.rate)} ${valuationCurrency}${rate.date ? ` · ${rate.date}` : ""}`;
}

function currencyUniverse(commodities: string[], prices: Price[], balances: AccountBalance[], accounts: AccountView[], valuationCurrency: string) {
  const seen = new Set<string>([valuationCurrency, "CNY"]);
  for (const commodity of commodities) if (commodity) seen.add(commodity);
  for (const price of prices) {
    seen.add(price.currency);
    seen.add(price.quoteCurrency);
  }
  for (const balance of balances) if (balance.currency) seen.add(balance.currency);
  for (const account of accounts) if (account.currency) seen.add(account.currency);
  return [...seen].sort((a, b) => a === valuationCurrency ? -1 : b === valuationCurrency ? 1 : a.localeCompare(b));
}

function summarizeBalances(balances: AccountBalance[]) {
  const summary = new Map<string, { amount: number; valuation: number; missing: number; rows: AccountBalance[] }>();
  for (const balance of balances) {
    const current = summary.get(balance.currency) ?? { amount: 0, valuation: 0, missing: 0, rows: [] };
    current.amount += balance.amount;
    current.valuation += balance.valuation;
    current.missing += balance.valuationMissing ? 1 : 0;
    current.rows.push(balance);
    summary.set(balance.currency, current);
  }
  return summary;
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

function pairRate(currency: string, targetCurrency: string, prices: Price[]): RateInfo {
  const direct = latestPair(currency, targetCurrency, prices);
  if (direct) return { rate: direct.amount / 100, date: direct.date, source: "direct" };
  const inverse = latestPair(targetCurrency, currency, prices);
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

function latestDate(a: string | null, b: string | null) {
  if (!a) return b;
  if (!b) return a;
  return a > b ? a : b;
}

function formatRateNumber(value: number) {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: value >= 1 ? 4 : 6, minimumFractionDigits: value >= 1 ? 2 : 4 }).format(value);
}
