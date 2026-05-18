"use client";

import { useMemo, useState } from "react";
import { ArrowDownRight, ArrowUpRight, ChevronDown, ChevronRight, Eye, EyeOff } from "lucide-react";
import { ResponsiveContainer, Sankey, Tooltip } from "recharts";
import { formatCny } from "@/lib/money";
import { HiddenPanel, Metric } from "./shared";
import type { AccountAnalytics, ExpenseCategoryAnalytics, IncomeStatementNode, PayeeAnalytics } from "./types";

export function IncomeStatementPage({ income, expense, expenseAnalytics, topPayees, topPaymentAccounts, totalIncome, totalExpense, netIncome, visible, sensitiveUnlocked, onToggleVisible, onUnlockSensitive, onSelectCategory }: { income: IncomeStatementNode[]; expense: IncomeStatementNode[]; expenseAnalytics: ExpenseCategoryAnalytics[]; topPayees: PayeeAnalytics[]; topPaymentAccounts: AccountAnalytics[]; totalIncome: number; totalExpense: number; netIncome: number; visible: boolean; sensitiveUnlocked: boolean; onToggleVisible: () => void; onUnlockSensitive: () => void; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  const cashFlowData = useMemo(() => buildCashFlowData({ income, expense, expenseAnalytics, totalIncome, totalExpense, netIncome, sensitiveUnlocked }), [income, expense, expenseAnalytics, totalIncome, totalExpense, netIncome, sensitiveUnlocked]);

  return <>
    <section className="card overflow-hidden p-0">
      <div className="border-l-4 border-brand p-4 md:p-5">
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="text-[11px] uppercase tracking-[0.2em] text-stone">income statement</div>
            <h1 className="mt-1.5 font-serif text-2xl font-medium leading-tight md:text-3xl">花在哪里，赚在哪里。</h1>
            <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">支出分析可直接查看；收入和净利需要确认本人后显示。</p>
          </div>
          <button className="shrink-0 rounded-xl border border-line bg-panel px-3 py-2 text-sm text-olive hover:bg-tag" onClick={onToggleVisible} title={visible ? "隐藏金额" : "显示金额"} aria-label={visible ? "隐藏金额" : "显示金额"}>
            {visible ? <EyeOff className="h-4 w-4 text-brand" /> : <Eye className="h-4 w-4 text-brand" />}
          </button>
        </div>
      </div>
      <div className="grid grid-cols-3 divide-x divide-line border-t border-line p-3 text-center md:p-4">
        <Metric label="收入" value={visible && sensitiveUnlocked ? formatCny(totalIncome / 100) : "••••••"} cls="amount-income text-base sm:text-xl" />
        <Metric label="支出" value={visible ? formatCny(totalExpense / 100) : "••••••"} cls="amount-expense text-base sm:text-xl" />
        <Metric label="净利" value={visible && sensitiveUnlocked ? formatCny(netIncome / 100) : "••••••"} cls="amount-gold text-base sm:text-xl" />
      </div>
    </section>

    {visible ? (
      <>
      <CashFlowSankey data={cashFlowData} sensitiveUnlocked={sensitiveUnlocked} />
      <CategoryAnalyticsPanel rows={expenseAnalytics} topPayees={topPayees} topPaymentAccounts={topPaymentAccounts} onSelectCategory={onSelectCategory} />
      <div className="mt-4 grid gap-4 lg:grid-cols-2">
        <div className="card p-4">
          <h2 className="mb-3 border-l-2 border-brand pl-3 font-serif text-xl text-warm">收入</h2>
          {sensitiveUnlocked ? (income.length === 0 ? <div className="py-8 text-center text-sm text-stone">本月暂无收入记录</div> : income.map((node) => <TreeNode key={node.account} node={node} visible={visible} onSelectCategory={onSelectCategory} />)) : <IncomeLockedPanel onUnlock={onUnlockSensitive} />}
        </div>
        <div className="card p-4">
          <h2 className="mb-3 border-l-2 border-brand pl-3 font-serif text-xl text-warm">支出</h2>
          {expense.length === 0 ? <div className="py-8 text-center text-sm text-stone">本月暂无支出记录</div> : expense.map((node) => <TreeNode key={node.account} node={node} visible={visible} onSelectCategory={onSelectCategory} />)}
        </div>
      </div>
      </>
    ) : (
      <HiddenPanel text="损益表金额默认隐藏。支出可直接显示；收入和净利需要使用 Face ID / Passkey 解锁。" />
    )}


  </>;
}

type CashFlowNode = { name: string; color: string; value?: number };
type CashFlowData = { nodes: CashFlowNode[]; links: { source: number; target: number; value: number }[] };
type SankeyNodeProps = { x: number; y: number; width: number; height: number; payload: CashFlowNode & { value?: number } };
type SankeyLinkProps = { sourceX: number; sourceY: number; sourceControlX: number; targetX: number; targetY: number; targetControlX: number; linkWidth: number; index: number };

function IncomeLockedPanel({ onUnlock }: { onUnlock: () => void }) {
  return <div className="rounded-xl border border-line bg-panel p-6 text-center text-sm text-stone"><p>收入分类和收入金额已隐藏。</p><button className="mt-4 rounded-xl bg-brand px-4 py-2 text-paper" onClick={onUnlock}>使用 Face ID / Passkey 查看收入</button></div>;
}

function CashFlowSankey({ data, sensitiveUnlocked }: { data: CashFlowData; sensitiveUnlocked: boolean }) {
  if (data.links.length === 0) return <section className="card mt-4 p-4"><h2 className="font-serif text-xl">Cash Flow</h2><div className="mt-3 rounded-xl border border-line bg-panel p-4 text-sm text-stone">当前周期暂无可视化现金流。</div></section>;

  return <section className="card mt-4 p-4">
    <div className="mb-3 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <h2 className="font-serif text-xl md:text-2xl">Cash Flow</h2>
        <p className="mt-1 text-sm text-olive">收入流入本期现金流，再分配到支出和储蓄/缺口。</p>
      </div>
      {!sensitiveUnlocked && <span className="text-xs text-stone">收入来源需解锁后显示明细</span>}
    </div>
    <div className="h-[360px] min-w-0 md:h-[420px]">
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
          margin={{ top: 16, right: 126, bottom: 16, left: 80 }}
          sort={false}
        >
          <Tooltip formatter={(value) => formatCny(Number(value) / 100)} />
        </Sankey>
      </ResponsiveContainer>
    </div>
  </section>;
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
    for (const row of visibleIncomeRows) {
      links.push({ source: addNode({ name: row.label, color: "rgb(var(--color-income))", value: row.amount }), target: cashFlowIndex, value: Math.max(1, row.amount) });
    }
    const otherIncome = Math.max(0, positiveTotalIncome - shownIncomeTotal);
    if (otherIncome > 0) links.push({ source: addNode({ name: "Other Income", color: "rgb(var(--color-income))", value: otherIncome }), target: cashFlowIndex, value: otherIncome });
  } else if (positiveTotalIncome > 0) {
    links.push({ source: addNode({ name: sensitiveUnlocked ? "Income" : "Income (locked)", color: "rgb(var(--color-income))", value: positiveTotalIncome }), target: cashFlowIndex, value: positiveTotalIncome });
  }

  for (const row of shownExpenses) {
    links.push({ source: cashFlowIndex, target: addNode({ name: row.label.replace(/^Expenses:/, ""), color: "#ff7a1a", value: row.amount }), value: Math.max(1, row.amount) });
  }
  if (otherExpense > 0) links.push({ source: cashFlowIndex, target: addNode({ name: "Other Expenses", color: "#ff9a4a", value: otherExpense }), value: otherExpense });
  if (netIncome > 0) links.push({ source: cashFlowIndex, target: addNode({ name: "Savings", color: "#22c55e", value: netIncome }), value: netIncome });
  if (netIncome < 0) links.push({ source: addNode({ name: "Deficit", color: "var(--danger)", value: Math.abs(netIncome) }), target: cashFlowIndex, value: Math.abs(netIncome) });

  return { nodes, links };
}

function topNodes(nodes: IncomeStatementNode[], limit: number) {
  return nodes.map((node) => ({ label: node.label || node.account, amount: node.amount })).filter((node) => node.amount > 0).sort((a, b) => b.amount - a.amount).slice(0, limit);
}

function formatPercent(value: number | null): string {
  if (value == null || !Number.isFinite(value)) return "—";
  return `${Math.round(value * 100)}%`;
}

function formatChange(value: number | null): string {
  if (value == null || !Number.isFinite(value)) return "新增";
  if (value === 0) return "持平";
  const sign = value > 0 ? "+" : "";
  return `${sign}${Math.round(value * 100)}%`;
}

function CollapsibleCard({ title, subtitle, defaultOpen = false, children }: { title: string; subtitle?: string; defaultOpen?: boolean; children: React.ReactNode }) {
  const [open, setOpen] = useState(defaultOpen);
  return <section className="card self-start overflow-hidden p-0">
    <button className="flex w-full items-center justify-between gap-3 p-4 text-left" onClick={() => setOpen((value) => !value)} aria-expanded={open}>
      <div className="min-w-0">
        <h2 className="border-l-2 border-brand pl-3 font-serif text-xl text-warm">{title}</h2>
        {subtitle && <div className="mt-1 pl-3 text-xs text-stone">{subtitle}</div>}
      </div>
      <ChevronDown className={`h-4 w-4 shrink-0 text-brand transition-transform ${open ? "rotate-180" : ""}`} />
    </button>
    {open && <div className="border-t border-line p-4 pt-3">{children}</div>}
  </section>;
}

function RankList({ rows, empty }: { rows: { key: string; label: string; amount: number; detail: string }[]; empty: string }) {
  if (!rows.length) return <div className="rounded-xl border border-line bg-panel p-4 text-sm text-stone">{empty}</div>;
  return <div className="grid gap-2">
    {rows.slice(0, 5).map((row, index) => <div key={row.key} className="flex items-center gap-3 rounded-xl border border-line bg-panel p-3">
      <span className="grid h-6 w-6 shrink-0 place-items-center rounded-full bg-tag text-xs text-stone">{index + 1}</span>
      <div className="min-w-0 flex-1">
        <div className="truncate text-sm font-medium text-warm">{row.label}</div>
        <div className="mt-0.5 text-xs text-stone">{row.detail}</div>
      </div>
      <strong className="shrink-0 text-sm tabular-nums amount-expense">{formatCny(row.amount / 100)}</strong>
    </div>)}
  </div>;
}

function CategoryAnalyticsPanel({ rows, topPayees, topPaymentAccounts, onSelectCategory }: { rows: ExpenseCategoryAnalytics[]; topPayees: PayeeAnalytics[]; topPaymentAccounts: AccountAnalytics[]; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  const topRows = rows.slice(0, 6);
  const unknown = rows.find((row) => row.account === "Expenses:Unknown");
  if (!rows.length) return null;

  return <section className="mt-4 grid items-start gap-4 xl:grid-cols-[1.25fr_0.9fr]">
    <CollapsibleCard title="支出 Top 分类" subtitle="点击分类查看流水" defaultOpen>
      <div className="grid gap-2">
        {topRows.map((row) => <button key={row.account} className="rounded-xl border border-line bg-panel p-3 text-left transition-colors hover:bg-tag" onClick={() => onSelectCategory?.(row.account, "prefix")}>
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0">
              <div className="truncate text-sm font-medium text-warm">{row.account}</div>
              <div className="mt-1 text-xs text-stone">{row.txCount} 笔 · 占支出 {formatPercent(row.share)}</div>
            </div>
            <div className="shrink-0 text-right">
              <div className="amount-expense text-sm font-medium tabular-nums">{formatCny(row.amount / 100)}</div>
              <div className={`mt-1 inline-flex items-center gap-0.5 text-xs ${row.changeRatio != null && row.changeRatio > 0 ? "amount-expense" : "amount-income"}`}>
                {row.changeRatio != null && row.changeRatio > 0 ? <ArrowUpRight className="h-3 w-3" /> : <ArrowDownRight className="h-3 w-3" />}
                {formatChange(row.changeRatio)}
              </div>
            </div>
          </div>
        </button>)}
      </div>
    </CollapsibleCard>
    <div className="grid auto-rows-max gap-4">
      <CollapsibleCard title="Top 商户" subtitle="按 payee 汇总当前周期支出">
        <RankList rows={topPayees.map((row) => ({ key: row.payee, label: row.payee, amount: row.amount, detail: `${row.txCount} 笔` }))} empty="当前周期没有商户支出" />
      </CollapsibleCard>
      <CollapsibleCard title="Top 支付账户" subtitle="按 Assets / Liabilities 出账账户汇总">
        <RankList rows={topPaymentAccounts.map((row) => ({ key: row.account, label: row.account, amount: row.amount, detail: `${row.txCount} 笔` }))} empty="当前周期没有支付账户支出" />
      </CollapsibleCard>
      <CollapsibleCard title="待整理" subtitle={unknown ? "发现未分类支出" : "未分类状态"} defaultOpen={Boolean(unknown)}>
        {unknown ? <button className="w-full rounded-xl border border-[var(--danger)]/30 bg-panel p-4 text-left transition-colors hover:bg-tag" onClick={() => onSelectCategory?.("Expenses:Unknown", "exact")}>
          <div className="text-sm font-medium text-[var(--danger)]">未分类支出</div>
          <div className="mt-2 text-2xl font-semibold tabular-nums text-warm">{formatCny(unknown.amount / 100)}</div>
          <div className="mt-1 text-xs text-stone">{unknown.txCount} 笔 · 占支出 {formatPercent(unknown.share)}，点击集中整理</div>
          {unknown.topPayees.length > 0 && <div className="mt-3 flex flex-wrap gap-1">{unknown.topPayees.map((payee) => <span key={payee.payee} className="rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone">{payee.payee} · {formatCny(payee.amount / 100)}</span>)}</div>}
        </button> : <div className="rounded-xl border border-line bg-panel p-4 text-sm text-stone">当前周期没有 Expenses:Unknown，分类很干净。</div>}
      </CollapsibleCard>
    </div>
  </section>;
}

function TreeNode({ node, visible, onSelectCategory }: { node: IncomeStatementNode; visible: boolean; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  const [expanded, setExpanded] = useState(node.depth < 2);
  const hasChildren = node.children.length > 0;
  const isLeaf = !hasChildren;
  const indentLeft = `${0.75 + node.depth * 1.5}rem`;

  return <div>
    <button
      className={`flex w-full items-center gap-2 rounded-lg py-2 pr-2 text-left transition-colors hover:bg-tag ${hasChildren ? "font-medium text-warm" : "text-warm"}`}
      style={{ paddingLeft: indentLeft }}
      onClick={() => {
        if (hasChildren) setExpanded((value) => !value);
        else onSelectCategory?.(node.account);
      }}
    >
      <span className="grid h-5 w-5 shrink-0 place-items-center text-stone">
        {hasChildren ? expanded ? <ChevronDown className="h-3.5 w-3.5" /> : <ChevronRight className="h-3.5 w-3.5" /> : <span className="text-[10px] text-stone/50">·</span>}
      </span>
      <span className="min-w-0 truncate text-sm">{node.label}</span>
      <span className="ml-auto shrink-0 pl-3 text-sm tabular-nums">{visible ? formatCny(node.amount / 100) : "••••••"}</span>
      {isLeaf && <span className="shrink-0 text-xs text-stone">{node.txCount} 笔</span>}
    </button>
    {hasChildren && expanded && (
      <div className="relative" style={{ marginLeft: indentLeft }}>
        <div className="absolute bottom-0 left-[0.5625rem] top-0 w-px border-l border-dashed border-line" />
        {node.children.map((child) => <TreeNode key={child.account} node={child} visible={visible} onSelectCategory={onSelectCategory} />)}
      </div>
    )}
  </div>;
}
