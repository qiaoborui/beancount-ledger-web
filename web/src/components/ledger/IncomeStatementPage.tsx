"use client";

import { useState } from "react";
import { ArrowDownRight, ArrowUpRight, ChevronDown, ChevronRight, Eye, EyeOff } from "lucide-react";
import { formatValuation } from "@/lib/money";
import { CashFlowCard } from "./CashFlowCard";
import { HiddenPanel, Metric } from "./shared";
import { formatAccountOptionLabel } from "./accountDisplay";
import type { AccountAnalytics, ExpenseCategoryAnalytics, IncomeStatementNode, PayeeAnalytics } from "./types";

export function IncomeStatementPage({ income, expense, expenseAnalytics, topPayees, topPaymentAccounts, totalIncome, totalExpense, netIncome, valuationCurrency, visible, sensitiveUnlocked, onToggleVisible, onUnlockSensitive, onSelectCategory }: { income: IncomeStatementNode[]; expense: IncomeStatementNode[]; expenseAnalytics: ExpenseCategoryAnalytics[]; topPayees: PayeeAnalytics[]; topPaymentAccounts: AccountAnalytics[]; totalIncome: number; totalExpense: number; netIncome: number; valuationCurrency: string; visible: boolean; sensitiveUnlocked: boolean; onToggleVisible: () => void; onUnlockSensitive: () => void; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
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
        <Metric label="收入" value={visible && sensitiveUnlocked ? formatValuation(totalIncome / 100, valuationCurrency) : "••••••"} cls="amount-income text-base sm:text-xl" />
        <Metric label="支出" value={visible ? formatValuation(totalExpense / 100, valuationCurrency) : "••••••"} cls="amount-expense text-base sm:text-xl" />
        <Metric label="净利" value={visible && sensitiveUnlocked ? formatValuation(netIncome / 100, valuationCurrency) : "••••••"} cls="amount-gold text-base sm:text-xl" />
      </div>
    </section>

    {visible ? (
      <>
      <CashFlowCard income={income} expense={expense} expenseAnalytics={expenseAnalytics} totalIncome={totalIncome} totalExpense={totalExpense} valuationCurrency={valuationCurrency} sensitiveUnlocked={sensitiveUnlocked} />
      <CategoryAnalyticsPanel rows={expenseAnalytics} topPayees={topPayees} topPaymentAccounts={topPaymentAccounts} valuationCurrency={valuationCurrency} onSelectCategory={onSelectCategory} />
      <div className="mt-4 grid gap-4 lg:grid-cols-2">
        <div className="card p-4">
          <h2 className="mb-3 border-l-2 border-brand pl-3 font-serif text-xl text-warm">收入</h2>
          {sensitiveUnlocked ? (income.length === 0 ? <div className="py-8 text-center text-sm text-stone">本月暂无收入记录</div> : income.map((node) => <TreeNode key={node.account} node={node} visible={visible} valuationCurrency={valuationCurrency} onSelectCategory={onSelectCategory} />)) : <IncomeLockedPanel onUnlock={onUnlockSensitive} />}
        </div>
        <div className="card p-4">
          <h2 className="mb-3 border-l-2 border-brand pl-3 font-serif text-xl text-warm">支出</h2>
          {expense.length === 0 ? <div className="py-8 text-center text-sm text-stone">本月暂无支出记录</div> : expense.map((node) => <TreeNode key={node.account} node={node} visible={visible} valuationCurrency={valuationCurrency} onSelectCategory={onSelectCategory} />)}
        </div>
      </div>
      </>
    ) : (
      <HiddenPanel text="损益表金额默认隐藏。支出可直接显示；收入和净利需要解锁后查看。" />
    )}


  </>;
}

function IncomeLockedPanel({ onUnlock }: { onUnlock: () => void }) {
  return <div className="rounded-xl border border-line bg-panel p-6 text-center text-sm text-stone"><p>收入分类和收入金额已隐藏。</p><button className="mt-4 rounded-xl bg-brand px-4 py-2 text-paper" onClick={onUnlock}>解锁查看收入</button></div>;
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

function RankList({ rows, empty, valuationCurrency }: { rows: { key: string; label: string; amount: number; detail: string }[]; empty: string; valuationCurrency: string }) {
  if (!rows.length) return <div className="rounded-xl border border-line bg-paper p-4 text-sm text-stone">{empty}</div>;
  return <div className="grid gap-2">
    {rows.slice(0, 5).map((row, index) => <div key={row.key} className="grid min-w-0 grid-cols-[auto_minmax(0,1fr)] items-center gap-x-3 gap-y-1 rounded-xl border border-line bg-paper p-3 sm:grid-cols-[auto_minmax(0,1fr)_auto]">
      <span className="grid h-6 w-6 shrink-0 place-items-center rounded-full bg-tag text-xs text-stone">{index + 1}</span>
      <div className="min-w-0 flex-1">
        <div className="truncate text-sm font-medium text-warm">{row.label}</div>
        <div className="mt-0.5 text-xs text-stone">{row.detail}</div>
      </div>
      <strong className="col-start-2 min-w-0 justify-self-end text-right text-sm tabular-nums amount-expense sm:col-start-auto">{formatValuation(row.amount / 100, valuationCurrency)}</strong>
    </div>)}
  </div>;
}

function CategoryAnalyticsPanel({ rows, topPayees, topPaymentAccounts, valuationCurrency, onSelectCategory }: { rows: ExpenseCategoryAnalytics[]; topPayees: PayeeAnalytics[]; topPaymentAccounts: AccountAnalytics[]; valuationCurrency: string; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  const topRows = rows.slice(0, 5);
  const unknown = rows.find((row) => row.account === "Expenses:Unknown");
  if (!rows.length) return null;

  return <section className="mt-4">
    <h2 className="border-l-2 border-brand pl-3 font-serif text-xl text-warm">支出分析</h2>
    <div className="mt-3 grid items-start gap-4 xl:grid-cols-2">
      <CollapsibleAnalysisCard title="Top 分类" subtitle="点击分类查看流水">
        <div className="mt-3 grid gap-2 md:grid-cols-2 xl:grid-cols-1 2xl:grid-cols-2">
          {topRows.map((row) => <button key={row.account} className="rounded-xl border border-line bg-panel p-3 text-left transition-colors hover:bg-tag" onClick={() => onSelectCategory?.(row.account, "prefix")}>
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <div className="truncate text-sm font-medium text-warm">{formatAccountOptionLabel(row.account, row.label, row.alias)}</div>
                <div className="mt-1 text-xs text-stone">{row.txCount} 笔 · 占支出 {formatPercent(row.share)}</div>
              </div>
              <div className="shrink-0 text-right">
                <div className="amount-expense text-sm font-medium tabular-nums">{formatValuation(row.amount / 100, valuationCurrency)}</div>
                <div className={`mt-1 inline-flex items-center gap-0.5 text-xs ${row.changeRatio != null && row.changeRatio > 0 ? "amount-expense" : "amount-income"}`}>
                  {row.changeRatio != null && row.changeRatio > 0 ? <ArrowUpRight className="h-3 w-3" /> : <ArrowDownRight className="h-3 w-3" />}
                  {formatChange(row.changeRatio)}
                </div>
              </div>
            </div>
          </button>)}
        </div>
      </CollapsibleAnalysisCard>
      <CollapsibleAnalysisCard title="Top 商户" subtitle="按 payee 汇总当前周期支出">
        <RankList rows={topPayees.map((row) => ({ key: row.payee, label: row.payee, amount: row.amount, detail: `${row.txCount} 笔` }))} empty="当前周期没有商户支出" valuationCurrency={valuationCurrency} />
      </CollapsibleAnalysisCard>
      <CollapsibleAnalysisCard title="待整理" subtitle={unknown ? "发现未分类支出" : "分类状态"}>
        {unknown ? <button className="w-full rounded-xl border border-[var(--danger)]/30 bg-paper p-4 text-left transition-colors hover:bg-tag" onClick={() => onSelectCategory?.("Expenses:Unknown", "exact")}>
          <div className="text-sm font-medium text-[var(--danger)]">Expenses:Unknown</div>
          <div className="mt-2 text-2xl font-semibold tabular-nums text-warm">{formatValuation(unknown.amount / 100, valuationCurrency)}</div>
          <div className="mt-1 text-xs text-stone">{unknown.txCount} 笔 · 占支出 {formatPercent(unknown.share)}</div>
          {unknown.topPayees.length > 0 && <div className="mt-3 flex flex-wrap gap-1">{unknown.topPayees.map((payee) => <span key={payee.payee} className="rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone">{payee.payee} · {formatValuation(payee.amount / 100, valuationCurrency)}</span>)}</div>}
        </button> : <div className="rounded-xl border border-line bg-paper p-4 text-sm text-stone">当前周期没有 Expenses:Unknown。</div>}
      </CollapsibleAnalysisCard>
      <CollapsibleAnalysisCard title="Top 支付账户" subtitle="按 Assets / Liabilities 出账账户汇总">
        <RankList rows={topPaymentAccounts.map((row) => ({ key: row.account, label: formatAccountOptionLabel(row.account, row.label, row.alias), amount: row.amount, detail: `${row.txCount} 笔` }))} empty="当前周期没有支付账户支出" valuationCurrency={valuationCurrency} />
      </CollapsibleAnalysisCard>
    </div>
  </section>;
}

function CollapsibleAnalysisCard({ title, subtitle, children }: { title: string; subtitle: string; children: React.ReactNode }) {
  const [open, setOpen] = useState(false);
  return <section className="card self-start overflow-hidden p-0">
    <button className="flex w-full items-center justify-between gap-3 p-4 text-left" onClick={() => setOpen((value) => !value)} aria-expanded={open}>
      <div className="min-w-0">
        <h3 className="font-serif text-lg text-warm">{title}</h3>
        <p className="mt-0.5 text-xs text-stone">{subtitle}</p>
      </div>
      <ChevronDown className={`h-4 w-4 shrink-0 text-brand transition-transform ${open ? "rotate-180" : ""}`} />
    </button>
    {open && <div className="border-t border-line p-4 pt-3">{children}</div>}
  </section>;
}

function TreeNode({ node, visible, valuationCurrency, onSelectCategory }: { node: IncomeStatementNode; visible: boolean; valuationCurrency: string; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
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
      <span className="min-w-0 truncate text-sm">{formatAccountOptionLabel(node.account, node.label, node.alias)}</span>
      <span className="ml-auto shrink-0 pl-3 text-sm tabular-nums">{visible ? formatValuation(node.amount / 100, valuationCurrency) : "••••••"}</span>
      {isLeaf && <span className="shrink-0 text-xs text-stone">{node.txCount} 笔</span>}
    </button>
    {hasChildren && expanded && (
      <div className="relative" style={{ marginLeft: indentLeft }}>
        <div className="absolute bottom-0 left-[0.5625rem] top-0 w-px border-l border-dashed border-line" />
        {node.children.map((child) => <TreeNode key={child.account} node={child} visible={visible} valuationCurrency={valuationCurrency} onSelectCategory={onSelectCategory} />)}
      </div>
    )}
  </div>;
}
