import { Area, AreaChart, Bar, BarChart, CartesianGrid, Cell, Line, LineChart, Pie, PieChart, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import type { ReactElement } from "react";
import { formatCompactValuation, formatValuation } from "@/lib/money";
import type { AccountAnalytics, DashboardAccountSeries, DashboardCashflowPoint, DashboardCategorySeries, DashboardDailyExpense } from "./types";

const tooltipStyle = { background: "var(--ivory)", border: "1px solid var(--line)", borderRadius: 6, color: "var(--ink)", boxShadow: "var(--float-shadow)", fontSize: 12 };
const categoryColors = ["oklch(var(--color-brand) / 1)", "oklch(var(--color-brand) / .78)", "oklch(var(--color-brand) / .58)", "oklch(var(--color-brand) / .40)", "oklch(var(--color-brand) / .25)", "oklch(var(--color-brand) / .14)"];

export type ComparisonMetric = "income" | "expense" | "net";

export function CashflowTrendChart({ rows, currency, cumulative = false }: { rows: DashboardCashflowPoint[]; currency: string; cumulative?: boolean }) {
  if (!rows.length) return <ChartEmpty text="当前范围暂无收支趋势" />;
  let income = 0;
  let expense = 0;
  const data = rows.map((row) => {
    income += row.income;
    expense += row.expense;
    return {
      label: row.month,
      收入: (cumulative ? income : row.income) / 100,
      支出: (cumulative ? expense : row.expense) / 100,
      净收入: (cumulative ? income - expense : row.net) / 100,
    };
  });
  return <ChartFrame>
    <LineChart data={data} margin={{ top: 14, right: 16, bottom: 2, left: 4 }}>
      <CartesianGrid stroke="var(--chart-grid)" strokeOpacity={0.78} vertical={false} />
      <XAxis dataKey="label" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={16} />
      <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={(value) => formatCompactValuation(Number(value), currency)} />
      <ReferenceLine y={0} stroke="var(--line-soft)" />
      <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatValuation(Number(value), currency), String(name)]} />
      <Line type="linear" dataKey="收入" stroke="var(--ink)" strokeWidth={1.5} dot={false} activeDot={{ r: 3, strokeWidth: 0 }} />
      <Line type="linear" dataKey="支出" stroke="var(--stone)" strokeWidth={1.35} strokeDasharray="5 4" dot={false} activeDot={{ r: 3, strokeWidth: 0 }} />
      <Line type="linear" dataKey="净收入" stroke="var(--chart-primary)" strokeWidth={1.75} dot={false} activeDot={{ r: 3, strokeWidth: 0 }} />
    </LineChart>
  </ChartFrame>;
}

export function PeriodComparisonChart({ current, previous, metric, currency, currentLabel, previousLabel }: { current: DashboardCashflowPoint[]; previous: DashboardCashflowPoint[]; metric: ComparisonMetric; currency: string; currentLabel: string; previousLabel: string }) {
  const data = current.map((row, index) => ({
    label: row.month,
    [currentLabel]: metricValue(row, metric) / 100,
    [previousLabel]: metricValue(previous[index], metric) / 100,
  }));
  if (!data.length) return <ChartEmpty text="当前范围暂无同比趋势" />;
  return <ChartFrame>
    <AreaChart data={data} margin={{ top: 14, right: 16, bottom: 2, left: 4 }}>
      <defs>
        <linearGradient id={`home-comparison-${metric}`} x1="0" x2="0" y1="0" y2="1">
          <stop offset="0%" stopColor="var(--chart-primary)" stopOpacity={0.18} />
          <stop offset="100%" stopColor="var(--chart-primary)" stopOpacity={0.01} />
        </linearGradient>
      </defs>
      <CartesianGrid stroke="var(--chart-grid)" strokeOpacity={0.78} vertical={false} />
      <XAxis dataKey="label" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={16} />
      <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={(value) => formatCompactValuation(Number(value), currency)} />
      <ReferenceLine y={0} stroke="var(--line-soft)" />
      <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatValuation(Number(value), currency), String(name)]} />
      <Area type="linear" dataKey={currentLabel} stroke="var(--chart-primary)" strokeWidth={1.7} fill={`url(#home-comparison-${metric})`} dot={false} activeDot={{ r: 3, strokeWidth: 0 }} />
      <Line type="linear" dataKey={previousLabel} stroke="var(--stone)" strokeWidth={1.25} strokeDasharray="5 4" dot={false} activeDot={{ r: 3, strokeWidth: 0 }} />
    </AreaChart>
  </ChartFrame>;
}

export function CategoryDistributionChart({ series, currency }: { series: DashboardCategorySeries[]; currency: string }) {
  const data = series.filter((row) => row.total > 0).slice(0, 6).map((row) => ({ name: row.label, value: row.total / 100 }));
  const total = data.reduce((sum, row) => sum + row.value, 0);
  if (!data.length) return <ChartEmpty text="当前范围暂无支出分类" />;
  return <div className="relative h-full min-h-0">
    <ChartFrame>
      <PieChart>
        <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatValuation(Number(value), currency), String(name)]} />
        <Pie data={data} dataKey="value" nameKey="name" innerRadius="57%" outerRadius="78%" paddingAngle={1.5} stroke="var(--ivory)" strokeWidth={2}>
          {data.map((row, index) => <Cell key={row.name} fill={categoryColors[index % categoryColors.length]} />)}
        </Pie>
      </PieChart>
    </ChartFrame>
    <div className="pointer-events-none absolute inset-0 grid place-items-center text-center">
      <div><div className="text-[11px] text-stone">分类支出</div><div className="mt-1 text-lg font-semibold tabular-nums text-ink">{formatCompactValuation(total, currency)}</div></div>
    </div>
  </div>;
}

export function CategoryComparisonChart({ current, previous, account, currency, currentLabel, previousLabel }: { current: DashboardCategorySeries[]; previous: DashboardCategorySeries[]; account: string; currency: string; currentLabel: string; previousLabel: string }) {
  const currentSeries = current.find((row) => row.account === account);
  const previousSeries = previous.find((row) => row.account === account);
  const rows = currentSeries?.values ?? previousSeries?.values ?? [];
  const data = rows.map((row, index) => ({ label: row.month, [currentLabel]: (currentSeries?.values[index]?.value ?? 0) / 100, [previousLabel]: (previousSeries?.values[index]?.value ?? 0) / 100 }));
  if (!data.length) return <ChartEmpty text="该分类暂无趋势数据" />;
  return <ChartFrame>
    <LineChart data={data} margin={{ top: 14, right: 16, bottom: 2, left: 4 }}>
      <CartesianGrid stroke="var(--chart-grid)" strokeOpacity={0.78} vertical={false} />
      <XAxis dataKey="label" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={16} />
      <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={(value) => formatCompactValuation(Number(value), currency)} />
      <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatValuation(Number(value), currency), String(name)]} />
      <Line type="linear" dataKey={currentLabel} stroke="var(--chart-primary)" strokeWidth={1.7} dot={false} activeDot={{ r: 3, strokeWidth: 0 }} />
      <Line type="linear" dataKey={previousLabel} stroke="var(--stone)" strokeWidth={1.25} strokeDasharray="5 4" dot={false} activeDot={{ r: 3, strokeWidth: 0 }} />
    </LineChart>
  </ChartFrame>;
}

export function PaymentAccountChart({ rows, currency }: { rows: AccountAnalytics[]; currency: string }) {
  const data = rows.slice(0, 6).map((row) => ({ label: row.label || row.account, 支出: row.amount / 100 }));
  if (!data.length) return <ChartEmpty text="当前范围暂无付款账户数据" />;
  return <ChartFrame>
    <BarChart data={data} margin={{ top: 14, right: 16, bottom: 8, left: 4 }}>
      <CartesianGrid stroke="var(--chart-grid)" strokeOpacity={0.72} vertical={false} />
      <XAxis dataKey="label" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} interval={0} tickFormatter={(value) => String(value).slice(0, 8)} />
      <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={(value) => formatCompactValuation(Number(value), currency)} />
      <Tooltip contentStyle={tooltipStyle} formatter={(value) => [formatValuation(Number(value), currency), "支出"]} />
      <Bar dataKey="支出" fill="var(--stone)" radius={[2, 2, 0, 0]} maxBarSize={54} />
    </BarChart>
  </ChartFrame>;
}

export function AccountBalanceTrendChart({ series, account, currency }: { series: DashboardAccountSeries[]; account: string; currency: string }) {
  const selected = series.find((row) => row.account === account) ?? series[0];
  const data = selected?.values.map((row) => ({ label: row.month, 余额: row.value / 100 })) ?? [];
  if (!data.length) return <ChartEmpty text="当前范围暂无账户余额趋势" />;
  return <ChartFrame>
    <AreaChart data={data} margin={{ top: 14, right: 16, bottom: 2, left: 4 }}>
      <defs><linearGradient id="home-account-fill" x1="0" x2="0" y1="0" y2="1"><stop offset="0%" stopColor="var(--ink)" stopOpacity={0.15} /><stop offset="100%" stopColor="var(--ink)" stopOpacity={0.01} /></linearGradient></defs>
      <CartesianGrid stroke="var(--chart-grid)" strokeOpacity={0.78} vertical={false} />
      <XAxis dataKey="label" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={16} />
      <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={(value) => formatCompactValuation(Number(value), currency)} />
      <ReferenceLine y={0} stroke="var(--line-soft)" />
      <Tooltip contentStyle={tooltipStyle} formatter={(value) => [formatValuation(Number(value), currency), "余额"]} />
      <Area type="linear" dataKey="余额" stroke="var(--ink)" strokeWidth={1.6} fill="url(#home-account-fill)" dot={false} activeDot={{ r: 3, strokeWidth: 0 }} />
    </AreaChart>
  </ChartFrame>;
}

export function ExpenseHeatmap({ rows, start, end, currency }: { rows: DashboardDailyExpense[]; start: string; end: string; currency: string }) {
  const amountByDate = new Map(rows.map((row) => [row.date, row.amount]));
  const months = monthKeys(start, end).slice(0, 12);
  const max = rows.reduce((value, row) => Math.max(value, row.amount), 0);
  if (!months.length) return <ChartEmpty text="当前范围暂无可用日期" />;
  return <div className="overflow-x-auto pb-1">
    <div className="grid min-w-[62rem] grid-cols-12 gap-3">
      {months.map((month) => <div key={month} className="min-w-0">
        <div className="mb-2 text-center text-[11px] font-medium tabular-nums text-stone">{Number(month.slice(5))}月</div>
        <div className="grid grid-cols-7 gap-1">
          {monthCells(month).map((date, index) => date ? <span key={date} className={`aspect-square min-w-0 rounded-[2px] ${heatClass(amountByDate.get(date) ?? 0, max)}`} title={`${date} · ${formatValuation((amountByDate.get(date) ?? 0) / 100, currency)}`} aria-label={`${date} 支出 ${formatValuation((amountByDate.get(date) ?? 0) / 100, currency)}`} /> : <span key={`${month}-${index}`} className="aspect-square" />)}
        </div>
      </div>)}
    </div>
    <div className="mt-4 flex items-center justify-end gap-1.5 text-[10px] text-stone"><span>低</span><span className="h-2.5 w-5 rounded-[2px] bg-tag" /><span className="h-2.5 w-5 rounded-[2px] bg-brand/25" /><span className="h-2.5 w-5 rounded-[2px] bg-brand/55" /><span className="h-2.5 w-5 rounded-[2px] bg-brand" /><span>高</span></div>
  </div>;
}

function ChartFrame({ children }: { children: ReactElement }) {
  return <div className="ledger-chart h-full min-h-0 min-w-0"><ResponsiveContainer width="100%" height="100%">{children}</ResponsiveContainer></div>;
}

function ChartEmpty({ text }: { text: string }) {
  return <div className="grid h-full min-h-40 place-items-center text-sm text-stone">{text}</div>;
}

function metricValue(row: DashboardCashflowPoint | undefined, metric: ComparisonMetric) {
  if (!row) return 0;
  return metric === "income" ? row.income : metric === "expense" ? row.expense : row.net;
}

function monthKeys(start: string, end: string) {
  const startDate = new Date(`${start}T00:00:00Z`);
  const endDate = new Date(`${end}T00:00:00Z`);
  const cursor = new Date(Date.UTC(startDate.getUTCFullYear(), startDate.getUTCMonth(), 1));
  const out: string[] = [];
  while (cursor < endDate && out.length < 12) {
    out.push(`${cursor.getUTCFullYear()}-${String(cursor.getUTCMonth() + 1).padStart(2, "0")}`);
    cursor.setUTCMonth(cursor.getUTCMonth() + 1);
  }
  return out;
}

function monthCells(month: string) {
  const [year, monthNumber] = month.split("-").map(Number);
  const first = new Date(Date.UTC(year, monthNumber - 1, 1));
  const dayOffset = (first.getUTCDay() + 6) % 7;
  const days = new Date(Date.UTC(year, monthNumber, 0)).getUTCDate();
  return Array.from({ length: 42 }, (_, index) => {
    const day = index - dayOffset + 1;
    return day > 0 && day <= days ? `${month}-${String(day).padStart(2, "0")}` : null;
  });
}

function heatClass(amount: number, max: number) {
  if (amount <= 0 || max <= 0) return "bg-tag";
  const ratio = amount / max;
  if (ratio > 0.72) return "bg-brand";
  if (ratio > 0.38) return "bg-brand/55";
  if (ratio > 0.16) return "bg-brand/25";
  return "bg-brand/10";
}
