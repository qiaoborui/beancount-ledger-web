"use client";

import { useState } from "react";
import { ResponsiveContainer, Sankey, Tooltip } from "recharts";
import { formatValuation } from "@/lib/money";
import { formatAccountOptionLabel } from "./accountDisplay";
import type { ExpenseCategoryAnalytics, IncomeStatementNode } from "./types";

type CashFlowNode = { name: string; color: string; value?: number; label?: string; side: "source" | "center" | "target" };
type CashFlowData = { nodes: CashFlowNode[]; links: { source: number; target: number; value: number }[] };
type CashFlowSelection = { kind: "node" | "link"; key: string; label: string; value: number; detail: string };
type SankeyNodeProps = { x: number; y: number; width: number; height: number; payload: CashFlowNode & { value?: number }; activeKey?: string | null; valuationCurrency?: string; onSelect?: (selection: CashFlowSelection) => void };
type SankeyLinkProps = { sourceX: number; sourceY: number; sourceControlX: number; targetX: number; targetY: number; targetControlX: number; linkWidth: number; index: number; nodes?: CashFlowNode[]; links?: CashFlowData["links"]; activeKey?: string | null; onSelect?: (selection: CashFlowSelection) => void };

type CashFlowCardProps = {
  income: IncomeStatementNode[];
  expense: IncomeStatementNode[];
  expenseAnalytics: ExpenseCategoryAnalytics[];
  totalIncome: number;
  totalExpense: number;
  valuationCurrency?: string;
  sensitiveUnlocked: boolean;
  title?: string;
  description?: string;
  className?: string;
};

export function CashFlowCard({ income, expense, expenseAnalytics, totalIncome, totalExpense, valuationCurrency = "CNY", sensitiveUnlocked, title = "现金流向", description = "收入进入本期现金流，再分配到支出分类和结余；还信用卡不重复计入损益。", className = "mt-4" }: CashFlowCardProps) {
  const data = buildCashFlowData({ income, expense, expenseAnalytics, totalIncome, totalExpense, sensitiveUnlocked });
  const [selection, setSelection] = useState<CashFlowSelection | null>(null);

  if (data.links.length === 0) return <section className={`card hidden p-4 lg:block ${className}`}><h2 className="font-serif text-xl">{title}</h2><div className="mt-3 rounded-xl border border-line bg-panel p-4 text-sm text-stone">当前周期暂无可视化现金流。</div></section>;

  return <section className={`card hidden overflow-hidden p-4 lg:block ${className}`}>
    <div className="mb-2 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between md:mb-3">
      <div>
        <h2 className="font-serif text-lg md:text-2xl">{title}</h2>
        <p className="mt-0.5 text-xs leading-5 text-olive md:mt-1 md:text-sm md:leading-6">{description}</p>
      </div>
      <div className="text-left sm:text-right">
        {selection ? <div className="rounded-xl border border-line bg-panel px-3 py-2 text-xs text-stone">
          <div className="font-medium text-warm">{selection.label}</div>
          <div className="mt-0.5 tabular-nums">{formatValuation(selection.value / 100, valuationCurrency)} · {selection.detail}</div>
        </div> : !sensitiveUnlocked && <span className="text-xs text-stone">收入来源需解锁后显示明细</span>}
      </div>
    </div>

    <div className="cash-flow-chart -mx-2 overflow-x-auto px-2 pb-1 [scrollbar-width:thin]">
      <div className="h-[390px] min-w-[560px] md:h-[380px] md:min-w-0 xl:h-[420px]">
        <ResponsiveContainer width="100%" height="100%">
          <Sankey
            data={data}
            dataKey="value"
            nameKey="name"
            node={<CashFlowNodeShape activeKey={selection?.key ?? null} valuationCurrency={valuationCurrency} onSelect={setSelection} />}
            link={<CashFlowLinkShape nodes={data.nodes} links={data.links} activeKey={selection?.key ?? null} onSelect={setSelection} />}
            nodePadding={10}
            nodeWidth={14}
            linkCurvature={0.55}
            margin={{ top: 8, right: 112, bottom: 8, left: 104 }}
            sort={false}
          >
            <Tooltip formatter={(value) => formatValuation(Number(value) / 100, valuationCurrency)} />
          </Sankey>
        </ResponsiveContainer>
      </div>
    </div>
  </section>;
}

function CashFlowNodeShape(props: Partial<SankeyNodeProps>) {
  const { x = 0, y = 0, width = 0, height = 0, payload, activeKey, valuationCurrency = "CNY", onSelect } = props;
  const name = payload?.name ?? "";
  const label = payload?.label ?? name;
  const key = `node-${name}`;
  const active = activeKey === key;
  const labelOnRight = payload?.side === "target";
  const labelX = labelOnRight ? x + width + 8 : x - 8;
  const select = () => onSelect?.({ kind: "node", key, label: name, value: payload?.value ?? 0, detail: "节点合计" });
  return <g className="cursor-pointer" onMouseEnter={select} onFocus={select} onTouchStart={select} tabIndex={0} role="button" aria-label={`${name} ${formatValuation((payload?.value ?? 0) / 100, valuationCurrency)}`}>
    <rect x={x} y={y} width={Math.max(width, 8)} height={Math.max(height, 6)} rx={2} fill={payload?.color ?? "var(--chart-primary)"} stroke={active ? "var(--brand)" : "transparent"} strokeWidth={active ? 2 : 0} filter={active ? "drop-shadow(0 2px 6px rgba(20, 20, 19, 0.22))" : undefined} />
    <text x={labelX} y={y + height / 2} textAnchor={labelOnRight ? "start" : "end"} dominantBaseline="middle" fill="var(--ink)" fontSize={11} fontWeight={active ? 700 : 400}>{label}</text>
  </g>;
}

function CashFlowLinkShape(props: Partial<SankeyLinkProps>) {
  const { sourceX = 0, sourceY = 0, sourceControlX = 0, targetX = 0, targetY = 0, targetControlX = 0, linkWidth = 1, index = 0, nodes = [], links = [], activeKey, onSelect } = props;
  const palette = ["rgba(74, 107, 85, 0.25)", "rgba(45, 90, 138, 0.25)", "rgba(181, 139, 107, 0.25)", "rgba(126, 104, 220, 0.22)", "rgba(198, 137, 126, 0.22)"];
  const link = links[index];
  const source = link ? nodes[link.source]?.name ?? "来源" : "来源";
  const target = link ? nodes[link.target]?.name ?? "去向" : "去向";
  const key = `link-${index}`;
  const active = activeKey === key;
  const select = () => link && onSelect?.({ kind: "link", key, label: `${source} → ${target}`, value: link.value, detail: "现金流向" });
  return <path className="cursor-pointer" d={`M${sourceX},${sourceY} C${sourceControlX},${sourceY} ${targetControlX},${targetY} ${targetX},${targetY}`} fill="none" stroke={active ? "var(--brand)" : palette[index % palette.length]} strokeWidth={Math.max(2, active ? linkWidth + 2 : linkWidth)} strokeOpacity={active ? 0.82 : 0.95} onMouseEnter={select} onTouchStart={select} />;
}

function buildCashFlowData({ income, expense, expenseAnalytics, totalIncome, totalExpense, sensitiveUnlocked }: { income: IncomeStatementNode[]; expense: IncomeStatementNode[]; expenseAnalytics: ExpenseCategoryAnalytics[]; totalIncome: number; totalExpense: number; sensitiveUnlocked: boolean }): CashFlowData {
  const nodes: CashFlowNode[] = [];
  const links: CashFlowData["links"] = [];
  const addNode = (node: CashFlowNode) => {
    nodes.push(node);
    return nodes.length - 1;
  };
  const positiveTotalIncome = Math.max(0, totalIncome);
  const visibleIncomeRows = sensitiveUnlocked ? topNodes(income, 4) : [];
  const expenseRows = expenseAnalytics.length ? expenseAnalytics.map((row) => ({ label: formatAccountOptionLabel(row.account, row.label, row.alias), amount: row.amount })) : topNodes(expense, 8);
  const shownExpenses = expenseRows.filter((row) => row.amount > 0).sort((a, b) => b.amount - a.amount).slice(0, 8);
  const otherExpense = Math.max(0, totalExpense - shownExpenses.reduce((sum, row) => sum + row.amount, 0));
  const cashSurplus = totalIncome - totalExpense;
  const flowValue = Math.max(positiveTotalIncome, totalExpense + Math.max(0, cashSurplus), 1);
  const cashFlowIndex = addNode({ name: "本期现金流", color: "var(--chart-primary)", value: flowValue, side: "center" });

  if (sensitiveUnlocked && visibleIncomeRows.length) {
    const shownIncomeTotal = visibleIncomeRows.reduce((sum, row) => sum + row.amount, 0);
    for (const row of visibleIncomeRows) links.push({ source: addNode({ name: row.label, label: compactCashFlowLabel(row.label), color: "rgb(var(--color-income))", value: row.amount, side: "source" }), target: cashFlowIndex, value: Math.max(1, row.amount) });
    const otherIncome = Math.max(0, positiveTotalIncome - shownIncomeTotal);
    if (otherIncome > 0) links.push({ source: addNode({ name: "其他收入", color: "rgb(var(--color-income))", value: otherIncome, side: "source" }), target: cashFlowIndex, value: otherIncome });
  } else if (positiveTotalIncome > 0) {
    links.push({ source: addNode({ name: sensitiveUnlocked ? "收入" : "收入（已锁定）", color: "rgb(var(--color-income))", value: positiveTotalIncome, side: "source" }), target: cashFlowIndex, value: positiveTotalIncome });
  }

  for (const row of shownExpenses) {
    const name = row.label.replace(/^Expenses:/, "");
    links.push({ source: cashFlowIndex, target: addNode({ name, label: compactCashFlowLabel(name), color: "#ff7a1a", value: row.amount, side: "target" }), value: Math.max(1, row.amount) });
  }
  if (otherExpense > 0) links.push({ source: cashFlowIndex, target: addNode({ name: "其他支出", color: "#ff9a4a", value: otherExpense, side: "target" }), value: otherExpense });
  if (cashSurplus > 0) links.push({ source: cashFlowIndex, target: addNode({ name: "结余", color: "#22c55e", value: cashSurplus, side: "target" }), value: cashSurplus });
  if (cashSurplus < 0) links.push({ source: addNode({ name: "缺口", color: "var(--danger)", value: Math.abs(cashSurplus), side: "source" }), target: cashFlowIndex, value: Math.abs(cashSurplus) });

  return { nodes, links };
}

function topNodes(nodes: IncomeStatementNode[], limit: number) {
  return nodes.map((node) => ({ label: formatAccountOptionLabel(node.account, node.label, node.alias), amount: node.amount })).filter((node) => node.amount > 0).sort((a, b) => b.amount - a.amount).slice(0, limit);
}

function compactCashFlowLabel(label: string) {
  const alias = label.split(" · ")[0]?.trim();
  if (alias && alias !== label) return alias;
  const parts = label.split(":").filter(Boolean);
  return parts.length > 1 ? parts[parts.length - 1] : label;
}
