import { ResponsiveContainer, Sankey, Tooltip } from "recharts";
import { formatCny } from "@/lib/money";
import type { ExpenseCategoryAnalytics, IncomeStatementNode } from "./types";

type CashFlowNode = { name: string; color: string; value?: number };
type CashFlowData = { nodes: CashFlowNode[]; links: { source: number; target: number; value: number }[] };
type SankeyNodeProps = { x: number; y: number; width: number; height: number; payload: CashFlowNode & { value?: number } };
type SankeyLinkProps = { sourceX: number; sourceY: number; sourceControlX: number; targetX: number; targetY: number; targetControlX: number; linkWidth: number; index: number };

type CashFlowCardProps = {
  income: IncomeStatementNode[];
  expense: IncomeStatementNode[];
  expenseAnalytics: ExpenseCategoryAnalytics[];
  totalIncome: number;
  totalExpense: number;
  netIncome: number;
  sensitiveUnlocked: boolean;
  title?: string;
  description?: string;
  className?: string;
};

export function CashFlowCard({ income, expense, expenseAnalytics, totalIncome, totalExpense, netIncome, sensitiveUnlocked, title = "Cash Flow", description = "收入流入本期现金流，再分配到支出和储蓄/缺口。", className = "mt-4" }: CashFlowCardProps) {
  const data = buildCashFlowData({ income, expense, expenseAnalytics, totalIncome, totalExpense, netIncome, sensitiveUnlocked });
  const mobileRows = buildMobileRows({ expenseAnalytics, expense, totalExpense, netIncome });

  if (data.links.length === 0) return <section className={`card p-4 ${className}`}><h2 className="font-serif text-xl">{title}</h2><div className="mt-3 rounded-xl border border-line bg-panel p-4 text-sm text-stone">当前周期暂无可视化现金流。</div></section>;

  return <section className={`card p-4 ${className}`}>
    <div className="mb-3 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <h2 className="font-serif text-xl md:text-2xl">{title}</h2>
        <p className="mt-1 text-sm leading-6 text-olive">{description}</p>
      </div>
      {!sensitiveUnlocked && <span className="text-xs text-stone">收入来源需解锁后显示明细</span>}
    </div>

    <div className="md:hidden">
      <div className="grid grid-cols-3 divide-x divide-line rounded-2xl border border-line bg-panel p-3 text-center">
        <MobileStat label="收入" value={sensitiveUnlocked ? formatCny(totalIncome / 100) : "••••••"} tone="amount-income" />
        <MobileStat label="支出" value={formatCny(totalExpense / 100)} tone="amount-expense" />
        <MobileStat label={netIncome >= 0 ? "储蓄" : "缺口"} value={sensitiveUnlocked ? formatCny(Math.abs(netIncome) / 100) : "••••••"} tone={netIncome >= 0 ? "amount-gold" : "amount-expense"} />
      </div>
      <div className="mt-3 space-y-2">
        {mobileRows.map((row) => <div key={row.label} className="rounded-xl border border-line bg-panel p-3">
          <div className="flex items-center justify-between gap-3 text-sm">
            <span className="min-w-0 truncate text-warm">{row.label}</span>
            <strong className={`shrink-0 tabular-nums ${row.tone}`}>{formatCny(row.amount / 100)}</strong>
          </div>
          <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-line">
            <div className={row.barClass} style={{ width: `${row.percent}%` }} />
          </div>
        </div>)}
      </div>
    </div>

    <div className="hidden h-[380px] min-w-0 md:block xl:h-[420px]">
      <ResponsiveContainer width="100%" height="100%">
        <Sankey
          data={data}
          dataKey="value"
          nameKey="name"
          node={<CashFlowNodeShape />}
          link={<CashFlowLinkShape />}
          nodePadding={18}
          nodeWidth={18}
          linkCurvature={0.55}
          margin={{ top: 16, right: 132, bottom: 16, left: 86 }}
          sort={false}
        >
          <Tooltip formatter={(value) => formatCny(Number(value) / 100)} />
        </Sankey>
      </ResponsiveContainer>
    </div>
  </section>;
}

function MobileStat({ label, value, tone }: { label: string; value: string; tone: string }) {
  return <div className="min-w-0 px-1"><div className="text-[11px] text-stone">{label}</div><div className={`mt-1 truncate text-sm font-semibold ${tone}`}>{value}</div></div>;
}

function CashFlowNodeShape(props: Partial<SankeyNodeProps>) {
  const { x = 0, y = 0, width = 0, height = 0, payload } = props;
  const name = payload?.name ?? "";
  const isRightSide = x > 450;
  const labelX = isRightSide ? x + width + 8 : x - 8;
  return <g>
    <rect x={x} y={y} width={Math.max(width, 8)} height={Math.max(height, 6)} rx={2} fill={payload?.color ?? "var(--chart-primary)"} />
    <text x={labelX} y={y + height / 2} textAnchor={isRightSide ? "start" : "end"} dominantBaseline="middle" fill="var(--ink)" fontSize={12}>{name}</text>
  </g>;
}

function CashFlowLinkShape(props: Partial<SankeyLinkProps>) {
  const { sourceX = 0, sourceY = 0, sourceControlX = 0, targetX = 0, targetY = 0, targetControlX = 0, linkWidth = 1, index = 0 } = props;
  const palette = ["rgba(74, 107, 85, 0.25)", "rgba(45, 90, 138, 0.25)", "rgba(181, 139, 107, 0.25)", "rgba(126, 104, 220, 0.22)", "rgba(198, 137, 126, 0.22)"];
  return <path d={`M${sourceX},${sourceY} C${sourceControlX},${sourceY} ${targetControlX},${targetY} ${targetX},${targetY}`} fill="none" stroke={palette[index % palette.length]} strokeWidth={Math.max(1, linkWidth)} strokeOpacity={0.95} />;
}

function buildCashFlowData({ income, expense, expenseAnalytics, totalIncome, totalExpense, netIncome, sensitiveUnlocked }: { income: IncomeStatementNode[]; expense: IncomeStatementNode[]; expenseAnalytics: ExpenseCategoryAnalytics[]; totalIncome: number; totalExpense: number; netIncome: number; sensitiveUnlocked: boolean }): CashFlowData {
  const nodes: CashFlowNode[] = [];
  const links: CashFlowData["links"] = [];
  const addNode = (node: CashFlowNode) => {
    nodes.push(node);
    return nodes.length - 1;
  };
  const positiveTotalIncome = Math.max(0, totalIncome);
  const visibleIncomeRows = sensitiveUnlocked ? topNodes(income, 4) : [];
  const expenseRows = expenseAnalytics.length ? expenseAnalytics.map((row) => ({ label: row.label || row.account, amount: row.amount })) : topNodes(expense, 8);
  const shownExpenses = expenseRows.filter((row) => row.amount > 0).sort((a, b) => b.amount - a.amount).slice(0, 8);
  const otherExpense = Math.max(0, totalExpense - shownExpenses.reduce((sum, row) => sum + row.amount, 0));
  const flowValue = Math.max(positiveTotalIncome, totalExpense + Math.max(0, netIncome), 1);
  const cashFlowIndex = addNode({ name: "Cash Flow", color: "var(--chart-primary)", value: flowValue });

  if (sensitiveUnlocked && visibleIncomeRows.length) {
    const shownIncomeTotal = visibleIncomeRows.reduce((sum, row) => sum + row.amount, 0);
    for (const row of visibleIncomeRows) links.push({ source: addNode({ name: row.label, color: "rgb(var(--color-income))", value: row.amount }), target: cashFlowIndex, value: Math.max(1, row.amount) });
    const otherIncome = Math.max(0, positiveTotalIncome - shownIncomeTotal);
    if (otherIncome > 0) links.push({ source: addNode({ name: "Other Income", color: "rgb(var(--color-income))", value: otherIncome }), target: cashFlowIndex, value: otherIncome });
  } else if (positiveTotalIncome > 0) {
    links.push({ source: addNode({ name: sensitiveUnlocked ? "Income" : "Income (locked)", color: "rgb(var(--color-income))", value: positiveTotalIncome }), target: cashFlowIndex, value: positiveTotalIncome });
  }

  for (const row of shownExpenses) links.push({ source: cashFlowIndex, target: addNode({ name: row.label.replace(/^Expenses:/, ""), color: "#ff7a1a", value: row.amount }), value: Math.max(1, row.amount) });
  if (otherExpense > 0) links.push({ source: cashFlowIndex, target: addNode({ name: "Other Expenses", color: "#ff9a4a", value: otherExpense }), value: otherExpense });
  if (netIncome > 0) links.push({ source: cashFlowIndex, target: addNode({ name: "Savings", color: "#22c55e", value: netIncome }), value: netIncome });
  if (netIncome < 0) links.push({ source: addNode({ name: "Deficit", color: "var(--danger)", value: Math.abs(netIncome) }), target: cashFlowIndex, value: Math.abs(netIncome) });

  return { nodes, links };
}

function buildMobileRows({ expenseAnalytics, expense, totalExpense, netIncome }: { expenseAnalytics: ExpenseCategoryAnalytics[]; expense: IncomeStatementNode[]; totalExpense: number; netIncome: number }) {
  const expenseRows = expenseAnalytics.length ? expenseAnalytics.map((row) => ({ label: row.label || row.account.replace(/^Expenses:/, ""), amount: row.amount })) : topNodes(expense, 4);
  const topExpenseRows = expenseRows.filter((row) => row.amount > 0).sort((a, b) => b.amount - a.amount).slice(0, 4);
  const maxValue = Math.max(...topExpenseRows.map((row) => row.amount), Math.abs(netIncome), 1);
  const rows = topExpenseRows.map((row) => ({ ...row, tone: "amount-expense", barClass: "h-full rounded-full bg-[var(--danger)]", percent: Math.max(3, Math.round(row.amount / maxValue * 100)) }));
  const otherExpense = Math.max(0, totalExpense - topExpenseRows.reduce((sum, row) => sum + row.amount, 0));
  if (otherExpense > 0) rows.push({ label: "其他支出", amount: otherExpense, tone: "amount-expense", barClass: "h-full rounded-full bg-[var(--danger)]/70", percent: Math.max(3, Math.round(otherExpense / maxValue * 100)) });
  if (netIncome > 0) rows.push({ label: "储蓄", amount: netIncome, tone: "amount-gold", barClass: "h-full rounded-full bg-brand", percent: Math.max(3, Math.round(netIncome / maxValue * 100)) });
  if (netIncome < 0) rows.push({ label: "缺口", amount: Math.abs(netIncome), tone: "amount-expense", barClass: "h-full rounded-full bg-[var(--danger)]", percent: Math.max(3, Math.round(Math.abs(netIncome) / maxValue * 100)) });
  return rows;
}

function topNodes(nodes: IncomeStatementNode[], limit: number) {
  return nodes.map((node) => ({ label: node.label || node.account, amount: node.amount })).filter((node) => node.amount > 0).sort((a, b) => b.amount - a.amount).slice(0, limit);
}
