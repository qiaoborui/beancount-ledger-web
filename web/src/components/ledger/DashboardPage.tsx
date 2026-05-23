import { useEffect, useMemo, useState, type ReactNode } from "react";
import { Eye, EyeOff } from "lucide-react";
import { Area, AreaChart, Bar, BarChart, CartesianGrid, ComposedChart, Legend, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { readJson } from "@/lib/clientFetch";
import { formatCny, formatCompactCny } from "@/lib/money";
import { timeRangeToParams } from "@/lib/timeRange";
import type { TimeRange } from "@/lib/timeRange";
import type { DashboardSummary } from "./types";

const COLORS = [
  "var(--chart-palette-1)",
  "var(--chart-palette-2)",
  "var(--chart-palette-3)",
  "var(--chart-palette-4)",
  "var(--chart-palette-5)",
  "var(--chart-palette-6)",
  "var(--chart-primary)",
  "var(--chart-secondary)",
];

export function DashboardPage({ timeRange, visible, onToggleVisible, onSensitiveLocked, onSelectCategory }: { timeRange: TimeRange; visible: boolean; onToggleVisible: () => void; onSensitiveLocked: () => void; onSelectCategory: (account: string, mode?: "exact" | "prefix") => void }) {
  const { data, loading, error } = useDashboardSummary(timeRange, onSensitiveLocked);
  const mask = (value: string) => visible ? value : "••••••";

  if (loading && !data) return <section className="card p-6 text-sm text-stone">正在加载看板…</section>;
  if (error && !data) return <section className="card p-6 text-sm text-stone">{error}</section>;
  if (!data) return <section className="card p-6 text-sm text-stone">暂无看板数据</section>;

  const maxExpense = data.anomalies[0]?.amount ?? 0;
  const budgetUsed = data.kpis.budgetUsage == null ? "暂无" : `${Math.round(data.kpis.budgetUsage * 100)}%`;
  const topCategory = data.categorySeries[0];
  const topCategoryText = topCategory ? `${topCategory.label} · ${mask(formatCompactCny(topCategory.total / 100))}` : "暂无";

  return <div className="space-y-7">
    <RowHeader title="消费监控" subtitle="支出、预算、商户和付款来源优先展示" />
    <section className="card p-3 md:p-4">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div className="grid flex-1 grid-cols-2 divide-x divide-y divide-line overflow-hidden rounded-xl border border-line sm:grid-cols-3 xl:grid-cols-6 xl:divide-y-0">
          <Kpi label="本期支出" value={mask(formatCompactCny(data.kpis.expense / 100))} tone="amount-expense" />
          <Kpi label="预算使用" value={visible ? budgetUsed : "••••••"} tone={data.kpis.budgetUsage != null && data.kpis.budgetUsage >= 1 ? "amount-expense" : "amount-gold"} />
          <Kpi label="最大单笔" value={mask(formatCompactCny(maxExpense / 100))} tone="amount-expense" />
          <Kpi label="高额支出" value={`${data.anomalies.length} 笔`} tone="text-warm" />
          <Kpi label="Top 分类" value={topCategoryText} tone="text-warm" />
          <Kpi label="结余" value={mask(formatCompactCny(data.kpis.net / 100))} tone={tone(data.kpis.net)} />
        </div>
        <button className="shrink-0 self-end rounded-xl border border-line bg-panel px-3 py-2 text-sm text-olive hover:bg-tag lg:self-auto" onClick={onToggleVisible} aria-label={visible ? "隐藏看板金额" : "显示看板金额"} title={visible ? "隐藏看板金额" : "显示看板金额"}>
          {visible ? <EyeOff className="inline h-4 w-4 text-brand" /> : <Eye className="inline h-4 w-4 text-brand" />} <span className="ml-1">{visible ? "隐藏金额" : "显示金额"}</span>
        </button>
      </div>
    </section>

    <RowHeader title="支出作战室" subtitle="先看每天花了多少，再看花给谁、花在哪" />
    <div className="grid gap-4 xl:grid-cols-12">
      <Panel className="xl:col-span-7" title="每日支出节奏" subtitle={`${data.dailyExpenseSeries.length} 个支出日`}>
        {visible ? <DailyExpenseChart data={data} /> : <HiddenChart />}
      </Panel>
      <Panel className="xl:col-span-5" title="星期分布" subtitle="消费节律">
        {visible ? <WeekdayExpenseChart data={data} /> : <HiddenChart />}
      </Panel>
      <Panel className="xl:col-span-4" title="分类排行" subtitle={`${data.categorySeries.length} 个分类`}>
        <CategoryRank rows={data.categorySeries} visible={visible} onSelectCategory={onSelectCategory} />
      </Panel>
      <Panel className="xl:col-span-4" title="商户排行" subtitle={`${data.topPayees.length} 个商户`}>
        <PayeeList data={data} visible={visible} />
      </Panel>
      <Panel className="xl:col-span-4" title="消费来源" subtitle={`${data.topPaymentAccounts.length} 个账户`}>
        <PaymentAccounts data={data} visible={visible} />
      </Panel>
    </div>

    <RowHeader title="预算与异常" subtitle="看超预算风险、异常大额和分类趋势" />
    <div className="grid gap-4 xl:grid-cols-12">
      <Panel className="xl:col-span-6" title="预算压力" subtitle={visible ? `剩余 ${formatCompactCny(data.kpis.budgetRemaining / 100)}` : "金额已隐藏"}>
        <BudgetPressure rows={data.budgetPressure} visible={visible} onSelectCategory={onSelectCategory} />
      </Panel>
      <Panel className="xl:col-span-6" title="高额支出" subtitle={`${data.anomalies.length} 笔`}>
        <AnomalyList rows={data.anomalies} visible={visible} onSelectCategory={onSelectCategory} />
      </Panel>
      <Panel className="xl:col-span-12" title="分类趋势" subtitle={`${data.categorySeries.length} 个 Top 分类`}>
        {visible ? <CategoryTrendChart data={data} /> : <HiddenChart />}
      </Panel>
    </div>

    <RowHeader title="资产与收入" subtitle="更敏感的资产、收入和账户趋势放在底部" />
    <div className="grid gap-4 xl:grid-cols-12">
      <Panel className="xl:col-span-4" title="资产 KPI" subtitle="敏感">
        <PrivateKpis data={data} visible={visible} />
      </Panel>
      <Panel className="xl:col-span-4" title="收入与结余" subtitle={cashflowSubtitle(data, visible)}>
        {visible ? <CashflowChart data={data} /> : <HiddenChart compact />}
      </Panel>
      <Panel className="xl:col-span-4" title="净资产趋势" subtitle={data.netWorthSeries.length ? `${data.netWorthSeries[0].date} ~ ${data.netWorthSeries.at(-1)?.date}` : "暂无"}>
        {visible ? <NetWorthChart data={data} /> : <HiddenChart compact />}
      </Panel>
      <Panel className="xl:col-span-12" title="账户余额趋势" subtitle={`${data.accountBalanceSeries.length} 个主要账户`}>
        {visible ? <AccountTrendChart data={data} /> : <HiddenChart />}
      </Panel>
    </div>
  </div>;
}

function useDashboardSummary(timeRange: TimeRange, onSensitiveLocked: () => void) {
  const [data, setData] = useState<DashboardSummary | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const params = timeRangeToParams(timeRange);

  useEffect(() => {
    const controller = new AbortController();
    async function load() {
      setLoading(true);
      setError("");
      try {
        const response = await fetch(`/api/ledger/dashboard?${params}`, { signal: controller.signal });
        if (response.status === 423 || response.status === 401) {
          onSensitiveLocked();
          setData(null);
          return;
        }
        const next = await readJson<DashboardSummary & { error?: string }>(response);
        if (!response.ok) throw new Error(next.error || `请求失败：${response.status}`);
        setData(next);
      } catch (err) {
        if (err instanceof DOMException && err.name === "AbortError") return;
        setError(err instanceof Error ? err.message : "看板加载失败");
      } finally {
        if (!controller.signal.aborted) setLoading(false);
      }
    }
    void load();
    return () => controller.abort();
  }, [onSensitiveLocked, params]);

  return { data, loading, error };
}

function RowHeader({ title, subtitle }: { title: string; subtitle: string }) {
  return <div className="flex flex-col gap-1 border-b border-line pb-2 sm:flex-row sm:items-end sm:justify-between">
    <h2 className="font-serif text-2xl font-medium">{title}</h2>
    <span className="text-xs text-stone">{subtitle}</span>
  </div>;
}

function Kpi({ label, value, tone }: { label: string; value: string; tone: string }) {
  return <div className="min-w-0 bg-panel p-3 text-center"><div className="text-[11px] uppercase tracking-[0.14em] text-stone">{label}</div><div className={`mt-1 truncate text-base font-semibold md:text-lg ${tone}`}>{value}</div></div>;
}

function Panel({ title, subtitle, className, children }: { title: string; subtitle?: string; className?: string; children: ReactNode }) {
  return <section className={`card min-w-0 p-4 ${className ?? ""}`}>
    <div className="flex items-start justify-between gap-3">
      <h3 className="font-serif text-xl">{title}</h3>
      {subtitle && <span className="rounded-full bg-tag px-2 py-1 text-xs text-stone">{subtitle}</span>}
    </div>
    {children}
  </section>;
}

function DailyExpenseChart({ data }: { data: DashboardSummary }) {
  const rows = data.dailyExpenseSeries.map((row) => ({ date: row.date.slice(5), 支出: row.amount / 100, 笔数: row.txCount }));
  return <ChartBox empty={!rows.length}>
    <ResponsiveContainer width="100%" height="100%">
      <ComposedChart data={rows} margin={{ left: 8, right: 16, top: 14, bottom: 0 }} barCategoryGap="30%">
        <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" vertical={false} />
        <XAxis dataKey="date" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={10} />
        <YAxis yAxisId="money" width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} />
        <YAxis yAxisId="count" orientation="right" width={36} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} />
        <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => name === "笔数" ? [Number(value), "笔数"] : [formatCny(Number(value)), name]} />
        <Bar yAxisId="money" dataKey="支出" fill="rgb(var(--color-expense))" radius={[4, 4, 0, 0]} maxBarSize={22} />
        <Line yAxisId="count" type="monotone" dataKey="笔数" stroke="var(--chart-primary)" strokeWidth={2} dot={{ r: 2 }} />
      </ComposedChart>
    </ResponsiveContainer>
  </ChartBox>;
}

function WeekdayExpenseChart({ data }: { data: DashboardSummary }) {
  const rows = data.weekdayExpense.map((row) => ({ weekday: row.weekday, 支出: row.amount / 100, 笔数: row.txCount }));
  return <ChartBox empty={!rows.some((row) => row.支出 > 0)}>
    <ResponsiveContainer width="100%" height="100%">
      <BarChart data={rows} margin={{ left: 8, right: 16, top: 14, bottom: 0 }} barCategoryGap="30%">
        <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" vertical={false} />
        <XAxis dataKey="weekday" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} />
        <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} />
        <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => name === "笔数" ? [Number(value), "笔数"] : [formatCny(Number(value)), name]} />
        <Bar dataKey="支出" fill="var(--chart-tertiary)" radius={[4, 4, 0, 0]} maxBarSize={34} />
      </BarChart>
    </ResponsiveContainer>
  </ChartBox>;
}

function NetWorthChart({ data }: { data: DashboardSummary }) {
  const rows = data.netWorthSeries.map((row) => ({ month: row.date, 净资产: row.netWorth / 100, 资产: row.assets / 100, 负债: row.liabilities / 100 }));
  return <ChartBox empty={!rows.length} compact>
    <ResponsiveContainer width="100%" height="100%">
      <LineChart data={rows} margin={{ left: 8, right: 16, top: 14, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" vertical={false} />
        <XAxis dataKey="month" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={14} />
        <YAxis width={58} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} domain={["dataMin", "dataMax"]} />
        <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatCny(Number(value)), name]} />
        <Legend />
        <Line type="monotone" dataKey="净资产" stroke="var(--chart-primary)" strokeWidth={3} dot={{ r: 3 }} />
        <Line type="monotone" dataKey="资产" stroke="var(--chart-tertiary)" strokeWidth={2} dot={false} />
        <Line type="monotone" dataKey="负债" stroke="var(--chart-secondary)" strokeWidth={2} dot={false} />
      </LineChart>
    </ResponsiveContainer>
  </ChartBox>;
}

function CashflowChart({ data }: { data: DashboardSummary }) {
  const rows = data.cashflowSeries.map((row) => ({ month: row.month, 收入: row.income / 100, 支出: row.expense / 100, 结余: row.net / 100 }));
  return <ChartBox empty={!rows.length} compact>
    <ResponsiveContainer width="100%" height="100%">
      <ComposedChart data={rows} margin={{ left: 8, right: 16, top: 14, bottom: 0 }} barCategoryGap="28%">
        <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" vertical={false} />
        <XAxis dataKey="month" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={14} />
        <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} />
        <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatCny(Number(value)), name]} />
        <Legend />
        <Bar dataKey="收入" fill="rgb(var(--color-income))" radius={[4, 4, 0, 0]} maxBarSize={22} />
        <Bar dataKey="支出" fill="rgb(var(--color-expense))" radius={[4, 4, 0, 0]} maxBarSize={22} />
        <Line type="monotone" dataKey="结余" stroke="var(--chart-primary)" strokeWidth={3} dot={{ r: 2 }} />
      </ComposedChart>
    </ResponsiveContainer>
  </ChartBox>;
}

function CategoryTrendChart({ data }: { data: DashboardSummary }) {
  const chartSeries = useMemo(() => data.categorySeries.slice(0, 8), [data.categorySeries]);
  const { focusedAccount, visibleSeries, toggleFocus } = useFocusedSeries(chartSeries);
  const rows = useMemo(() => seriesRows(chartSeries), [chartSeries]);
  return <ChartBox empty={!rows.length}>
    <div className="flex h-full min-h-0 flex-col">
      <div className="min-h-0 flex-1">
        <ResponsiveContainer width="100%" height="100%">
          <AreaChart data={rows} margin={{ left: 8, right: 16, top: 14, bottom: 0 }}>
            <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" vertical={false} />
            <XAxis dataKey="month" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={14} />
            <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} />
            <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatCny(Number(value)), labelForSeries(chartSeries, String(name))]} />
            {visibleSeries.map((series) => {
              const index = chartSeries.findIndex((item) => item.account === series.account);
              return <Area key={series.account} type="monotone" dataKey={series.account} stackId={focusedAccount ? undefined : "expense"} stroke={COLORS[index % COLORS.length]} fill={COLORS[index % COLORS.length]} fillOpacity={0.72} />;
            })}
          </AreaChart>
        </ResponsiveContainer>
      </div>
      <InteractiveLegend series={chartSeries} focusedAccount={focusedAccount} onToggle={toggleFocus} />
    </div>
  </ChartBox>;
}

function AccountTrendChart({ data }: { data: DashboardSummary }) {
  const chartSeries = data.accountBalanceSeries;
  const { focusedAccount, visibleSeries, toggleFocus } = useFocusedSeries(chartSeries);
  const rows = useMemo(() => seriesRows(chartSeries), [chartSeries]);
  return <ChartBox empty={!rows.length}>
    <div className="flex h-full min-h-0 flex-col">
      <div className="min-h-0 flex-1">
        <ResponsiveContainer width="100%" height="100%">
          <LineChart data={rows} margin={{ left: 8, right: 16, top: 14, bottom: 0 }}>
            <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" vertical={false} />
            <XAxis dataKey="month" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={14} />
            <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} />
            <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatCny(Number(value)), labelForSeries(chartSeries, String(name))]} />
            {visibleSeries.map((series) => {
              const index = chartSeries.findIndex((item) => item.account === series.account);
              return <Line key={series.account} type="monotone" dataKey={series.account} stroke={COLORS[index % COLORS.length]} strokeWidth={2} dot={{ r: 2 }} />;
            })}
          </LineChart>
        </ResponsiveContainer>
      </div>
      <InteractiveLegend series={chartSeries} focusedAccount={focusedAccount} onToggle={toggleFocus} />
    </div>
  </ChartBox>;
}

function useFocusedSeries<T extends { account: string }>(series: T[]) {
  const [focusedAccount, setFocusedAccount] = useState<string | null>(null);

  useEffect(() => {
    if (focusedAccount && !series.some((item) => item.account === focusedAccount)) {
      setFocusedAccount(null);
    }
  }, [focusedAccount, series]);

  const visibleSeries = useMemo(() => {
    if (!focusedAccount) return series;
    return series.filter((item) => item.account === focusedAccount);
  }, [focusedAccount, series]);

  const toggleFocus = (account: string) => {
    setFocusedAccount((current) => current === account ? null : account);
  };

  return { focusedAccount, visibleSeries, toggleFocus };
}

function InteractiveLegend({ series, focusedAccount, onToggle }: { series: { account: string; label: string }[]; focusedAccount: string | null; onToggle: (account: string) => void }) {
  if (!series.length) return null;
  return <div className="mt-2 flex max-h-20 flex-wrap items-center justify-center gap-x-3 gap-y-2 overflow-y-auto px-1 text-xs" aria-label="图例">
    {series.map((item, index) => {
      const selected = focusedAccount === item.account;
      const muted = focusedAccount != null && !selected;
      return <button key={item.account} type="button" className={`flex min-w-0 max-w-full items-center gap-1.5 rounded-full border px-2 py-1 transition ${selected ? "border-brand bg-tag text-ink" : muted ? "border-transparent text-stone opacity-55 hover:bg-tag hover:opacity-100" : "border-transparent text-stone hover:bg-tag"}`} onClick={() => onToggle(item.account)} aria-pressed={selected} title={selected ? "恢复全部显示" : `只显示 ${item.label}`}>
        <span className="h-2.5 w-2.5 shrink-0 rounded-sm" style={{ background: COLORS[index % COLORS.length], opacity: muted ? 0.45 : 1 }} />
        <span className="max-w-[11rem] truncate">{item.label}</span>
      </button>;
    })}
  </div>;
}

function CategoryRank({ rows, visible, onSelectCategory }: { rows: DashboardSummary["categorySeries"]; visible: boolean; onSelectCategory: (account: string, mode?: "exact" | "prefix") => void }) {
  if (!rows.length) return <EmptyPanel text="暂无分类支出" />;
  const maxValue = Math.max(1, ...rows.map((row) => row.total));
  return <div className="mt-4 space-y-3">
    {rows.slice(0, 8).map((row, index) => <button key={row.account} className="w-full text-left" onClick={() => onSelectCategory(row.account, "prefix")}>
      <div className="flex items-center justify-between gap-3 text-sm">
        <span className="min-w-0 truncate text-olive">{row.label}</span>
        <strong className="shrink-0 text-warm">{visible ? formatCompactCny(row.total / 100) : "••••••"}</strong>
      </div>
      <div className="mt-1 h-2 overflow-hidden rounded-full bg-line"><div className="h-full" style={{ width: `${row.total / maxValue * 100}%`, background: COLORS[index % COLORS.length] }} /></div>
    </button>)}
  </div>;
}

function PayeeList({ data, visible }: { data: DashboardSummary; visible: boolean }) {
  if (!data.topPayees.length) return <EmptyPanel text="暂无商户数据" />;
  const maxValue = Math.max(1, ...data.topPayees.map((row) => row.amount));
  return <div className="mt-4 space-y-3">
    {data.topPayees.slice(0, 8).map((row) => <div key={row.payee}>
      <div className="flex items-center justify-between gap-3 text-sm">
        <span className="min-w-0 truncate text-olive">{row.payee}</span>
        <strong className="shrink-0 text-warm">{visible ? formatCompactCny(row.amount / 100) : "••••••"}</strong>
      </div>
      <div className="mt-1 flex items-center gap-2">
        <div className="h-2 flex-1 overflow-hidden rounded-full bg-line"><div className="h-full bg-[rgb(var(--color-expense))]" style={{ width: `${row.amount / maxValue * 100}%` }} /></div>
        <span className="w-10 text-right text-xs text-stone">{row.txCount} 笔</span>
      </div>
    </div>)}
  </div>;
}

function BudgetPressure({ rows, visible, onSelectCategory }: { rows: DashboardSummary["budgetPressure"]; visible: boolean; onSelectCategory: (account: string, mode?: "exact" | "prefix") => void }) {
  if (!rows.length) return <EmptyPanel text="暂无预算数据" />;
  return <div className="mt-4 space-y-3">
    {rows.slice(0, 7).map((row) => {
      const pct = Math.max(0, Math.min(140, (row.ratio ?? 0) * 100));
      return <button key={row.account} className="w-full rounded-xl border border-line bg-panel p-3 text-left hover:bg-tag" onClick={() => onSelectCategory(row.account, "prefix")}>
        <div className="flex items-center justify-between gap-3 text-sm">
          <span className="min-w-0 truncate text-olive">{row.label}</span>
          <strong className={pct >= 100 ? "amount-expense" : pct >= 80 ? "amount-gold" : "amount-income"}>{row.ratio == null ? "暂无" : `${Math.round(pct)}%`}</strong>
        </div>
        <div className="mt-2 h-2 overflow-hidden rounded-full bg-line"><div className={pct >= 100 ? "h-full bg-[rgb(var(--color-expense))]" : "h-full bg-brand"} style={{ width: `${Math.min(pct, 100)}%` }} /></div>
        <div className="mt-1 text-xs text-stone">{visible ? `已用 ${formatCompactCny(row.spent / 100)} · 剩余 ${formatCompactCny(row.remaining / 100)}` : "金额已隐藏"}</div>
      </button>;
    })}
  </div>;
}

function AnomalyList({ rows, visible, onSelectCategory }: { rows: DashboardSummary["anomalies"]; visible: boolean; onSelectCategory: (account: string, mode?: "exact" | "prefix") => void }) {
  if (!rows.length) return <EmptyPanel text="暂无高额支出" />;
  return <div className="mt-4 divide-y divide-line overflow-hidden rounded-xl border border-line bg-panel">
    {rows.slice(0, 8).map((row) => <button key={`${row.source}:${row.account}`} className="flex w-full items-center justify-between gap-3 p-3 text-left hover:bg-tag" onClick={() => onSelectCategory(row.account, "prefix")}>
      <span className="min-w-0">
        <span className="block truncate text-sm font-medium text-olive">{row.payee || row.narration || row.account}</span>
        <span className="mt-0.5 block truncate text-xs text-stone">{row.date} · {row.account.replace(/^Expenses:/, "")}</span>
      </span>
      <strong className="shrink-0 amount-expense">{visible ? formatCompactCny(row.amount / 100) : "••••••"}</strong>
    </button>)}
  </div>;
}

function PaymentAccounts({ data, visible }: { data: DashboardSummary; visible: boolean }) {
  if (!data.topPaymentAccounts.length) return <EmptyPanel text="暂无消费账户" />;
  const rows = data.topPaymentAccounts.slice(0, 7);
  const maxValue = Math.max(1, ...rows.map((row) => row.amount));
  return <div className="mt-4 space-y-3">
    {rows.map((row) => <div key={row.account}>
      <div className="flex items-center justify-between gap-3 text-sm">
        <span className="min-w-0 truncate text-olive">{row.account.replace(/^(Assets|Liabilities):/, "")}</span>
        <strong className="shrink-0 text-warm">{visible ? formatCompactCny(row.amount / 100) : "••••••"}</strong>
      </div>
      <div className="mt-1 h-2 overflow-hidden rounded-full bg-line"><div className="h-full bg-[var(--chart-tertiary)]" style={{ width: `${row.amount / maxValue * 100}%` }} /></div>
    </div>)}
  </div>;
}

function PrivateKpis({ data, visible }: { data: DashboardSummary; visible: boolean }) {
  const mask = (value: string) => visible ? value : "••••••";
  return <div className="mt-4 grid grid-cols-2 gap-3">
    <SmallMetric label="资产" value={mask(formatCompactCny(data.kpis.assets / 100))} tone="amount-income" />
    <SmallMetric label="负债" value={mask(formatCompactCny(data.kpis.liabilities / 100))} tone="amount-expense" />
    <SmallMetric label="净资产" value={mask(formatCompactCny(data.kpis.netWorth / 100))} tone={tone(data.kpis.netWorth)} />
    <SmallMetric label="收入" value={mask(formatCompactCny(data.kpis.income / 100))} tone="amount-income" />
    <SmallMetric label="结余率" value={visible ? ratioLabel(data.kpis.savingsRate) : "••••••"} tone={tone(data.kpis.net)} />
    <SmallMetric label="预算剩余" value={mask(formatCompactCny(data.kpis.budgetRemaining / 100))} tone={data.kpis.budgetRemaining >= 0 ? "amount-income" : "amount-expense"} />
  </div>;
}

function SmallMetric({ label, value, tone }: { label: string; value: string; tone: string }) {
  return <div className="rounded-xl border border-line bg-panel p-3"><div className="text-[11px] uppercase tracking-[0.14em] text-stone">{label}</div><div className={`mt-1 truncate text-base font-semibold ${tone}`}>{value}</div></div>;
}

function ChartBox({ empty, compact = false, children }: { empty: boolean; compact?: boolean; children: ReactNode }) {
  if (empty) return <EmptyPanel text="暂无趋势数据" compact={compact} />;
  return <div className={`ledger-chart mt-4 min-w-0 ${compact ? "h-64" : "h-80"}`}>{children}</div>;
}

function HiddenChart({ compact = false }: { compact?: boolean }) {
  return <div className={`mt-4 grid place-items-center rounded-xl border border-line bg-panel text-sm text-stone ${compact ? "h-64" : "h-80"}`}>金额已隐藏</div>;
}

function EmptyPanel({ text, compact = false }: { text: string; compact?: boolean }) {
  return <div className={`mt-4 grid place-items-center rounded-xl border border-line bg-panel p-6 text-center text-sm text-stone ${compact ? "min-h-32" : "min-h-40"}`}>{text}</div>;
}

function seriesRows(series: { account: string; values: { month: string; value: number }[] }[]) {
  const months = Array.from(new Set(series.flatMap((row) => row.values.map((value) => value.month)))).sort();
  return months.map((month) => {
    const row: Record<string, string | number> = { month };
    for (const item of series) {
      row[item.account] = (item.values.find((value) => value.month === month)?.value ?? 0) / 100;
    }
    return row;
  });
}

function labelForSeries(series: { account: string; label: string }[], account: string) {
  return series.find((row) => row.account === account)?.label ?? account;
}

const tooltipStyle = { background: "var(--ivory)", border: "1px solid var(--line)", borderRadius: 12, color: "var(--ink)" };

function compactChartMoney(value: number) {
  return new Intl.NumberFormat("zh-CN", { notation: "compact", compactDisplay: "short", maximumFractionDigits: 1 }).format(value);
}

function ratioLabel(value: number | null) {
  if (value == null) return "暂无";
  return `${(value * 100).toFixed(1)}%`;
}

function tone(value: number) {
  return value >= 0 ? "amount-income" : "amount-expense";
}

function cashflowSubtitle(data: DashboardSummary, visible: boolean) {
  if (!visible) return "金额已隐藏";
  if (!data.cashflowSeries.length) return "暂无";
  const latest = data.cashflowSeries.at(-1);
  return latest ? `${latest.month} 结余 ${formatCompactCny(latest.net / 100)}` : "暂无";
}
