import { Bar, CartesianGrid, ComposedChart, Line, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { formatValuation } from "@/lib/money";

export function HomeDailyTrendChart({ rows, valuationCurrency }: { rows: [string, { income: number; expense: number }][]; valuationCurrency: string }) {
  const data = rows.map(([date, value]) => ({
    date,
    income: value.income / 100,
    expense: value.expense / 100,
  }));
  return (
    <ResponsiveContainer width="100%" height="100%">
      <ComposedChart data={data} margin={{ top: 8, right: 10, bottom: 0, left: 0 }} barCategoryGap="34%">
        <CartesianGrid stroke="var(--chart-grid)" strokeDasharray="3 3" vertical={false} />
        <XAxis dataKey="date" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={12} tickFormatter={(value) => String(value).slice(5)} />
        <YAxis yAxisId="expense" width={48} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactMoney} />
        <YAxis yAxisId="income" orientation="right" width={48} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactMoney} />
        <Tooltip
          cursor={{ fill: "var(--selected-bg)" }}
          contentStyle={{ background: "var(--ivory)", border: "1px solid var(--line)", borderRadius: 12, color: "var(--ink)" }}
          labelFormatter={(label) => String(label)}
          formatter={(value, name) => [formatValuation(Number(value), valuationCurrency), name === "收入" ? "收入" : "支出"]}
        />
        <Bar yAxisId="expense" dataKey="expense" name="支出" fill="rgb(var(--color-expense))" radius={[4, 4, 0, 0]} maxBarSize={22} />
        <Line yAxisId="income" type="monotone" dataKey="income" name="收入" stroke="rgb(var(--color-income))" strokeWidth={2} dot={{ r: 2, fill: "rgb(var(--color-income))" }} activeDot={{ r: 4 }} />
      </ComposedChart>
    </ResponsiveContainer>
  );
}

function compactMoney(value: number) {
  if (Math.abs(value) >= 10000) return `${Math.round(value / 10000)}万`;
  if (Math.abs(value) >= 1000) return `${Math.round(value / 1000)}k`;
  return `${Math.round(value)}`;
}
