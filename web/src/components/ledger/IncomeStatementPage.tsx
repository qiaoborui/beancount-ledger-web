"use client";

import { useState } from "react";
import { ArrowDownRight, ArrowUpRight, ChevronDown, ChevronRight, Eye, EyeOff } from "lucide-react";
import { formatCny } from "@/lib/money";
import { HiddenPanel, Metric } from "./shared";
import type { AccountAnalytics, ExpenseCategoryAnalytics, IncomeStatementNode, PayeeAnalytics } from "./types";

export function IncomeStatementPage({ income, expense, expenseAnalytics, topPayees, topPaymentAccounts, totalIncome, totalExpense, netIncome, visible, sensitiveUnlocked, onToggleVisible, onUnlockSensitive, onSelectCategory }: { income: IncomeStatementNode[]; expense: IncomeStatementNode[]; expenseAnalytics: ExpenseCategoryAnalytics[]; topPayees: PayeeAnalytics[]; topPaymentAccounts: AccountAnalytics[]; totalIncome: number; totalExpense: number; netIncome: number; visible: boolean; sensitiveUnlocked: boolean; onToggleVisible: () => void; onUnlockSensitive: () => void; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  return <>
    <section className="card overflow-hidden p-0">
      <div className="border-l-4 border-brand p-5 md:p-6">
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="text-xs uppercase tracking-[0.24em] text-stone">income statement</div>
            <h1 className="mt-2 font-serif text-3xl font-medium leading-tight md:text-4xl">花在哪里，赚在哪里。</h1>
            <p className="mt-3 max-w-2xl text-sm leading-6 text-olive">支出分析可直接查看；收入和净利需要确认本人后显示。</p>
          </div>
          <button className="shrink-0 rounded-xl border border-line bg-panel px-3 py-2 text-sm text-olive hover:bg-tag" onClick={onToggleVisible} title={visible ? "隐藏金额" : "显示金额"} aria-label={visible ? "隐藏金额" : "显示金额"}>
            {visible ? <EyeOff className="h-4 w-4 text-brand" /> : <Eye className="h-4 w-4 text-brand" />}
          </button>
        </div>
      </div>
      <div className="grid grid-cols-3 divide-x divide-line border-t border-line p-5 text-center">
        <Metric label="收入" value={visible && sensitiveUnlocked ? formatCny(totalIncome / 100) : "••••••"} cls="amount-income text-lg sm:text-2xl" />
        <Metric label="支出" value={visible ? formatCny(totalExpense / 100) : "••••••"} cls="amount-expense text-lg sm:text-2xl" />
        <Metric label="净利" value={visible && sensitiveUnlocked ? formatCny(netIncome / 100) : "••••••"} cls="amount-gold text-lg sm:text-2xl" />
      </div>
    </section>

    {visible ? (
      <>
      <CategoryAnalyticsPanel rows={expenseAnalytics} topPayees={topPayees} topPaymentAccounts={topPaymentAccounts} onSelectCategory={onSelectCategory} />
      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <div className="card p-4">
          <h2 className="mb-4 border-l-2 border-brand pl-3 font-serif text-2xl text-warm">收入</h2>
          {sensitiveUnlocked ? (income.length === 0 ? <div className="py-8 text-center text-sm text-stone">本月暂无收入记录</div> : income.map((node) => <TreeNode key={node.account} node={node} visible={visible} onSelectCategory={onSelectCategory} />)) : <IncomeLockedPanel onUnlock={onUnlockSensitive} />}
        </div>
        <div className="card p-4">
          <h2 className="mb-4 border-l-2 border-brand pl-3 font-serif text-2xl text-warm">支出</h2>
          {expense.length === 0 ? <div className="py-8 text-center text-sm text-stone">本月暂无支出记录</div> : expense.map((node) => <TreeNode key={node.account} node={node} visible={visible} onSelectCategory={onSelectCategory} />)}
        </div>
      </div>
      </>
    ) : (
      <HiddenPanel text="损益表金额默认隐藏。支出可直接显示；收入和净利需要使用 Face ID / Passkey 解锁。" />
    )}


  </>;
}

function IncomeLockedPanel({ onUnlock }: { onUnlock: () => void }) {
  return <div className="rounded-xl border border-line bg-panel p-6 text-center text-sm text-stone"><p>收入分类和收入金额已隐藏。</p><button className="mt-4 rounded-xl bg-brand px-4 py-2 text-paper" onClick={onUnlock}>使用 Face ID / Passkey 查看收入</button></div>;
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
        <h2 className="border-l-2 border-brand pl-3 font-serif text-2xl text-warm">{title}</h2>
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

  return <section className="mt-6 grid items-start gap-4 xl:grid-cols-[1.25fr_0.9fr]">
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
