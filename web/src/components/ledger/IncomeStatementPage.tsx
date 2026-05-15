"use client";

import { useState } from "react";
import { ChevronDown, ChevronRight, Eye, EyeOff } from "lucide-react";
import { formatCny } from "@/lib/money";
import { HiddenPanel, Metric } from "./shared";
import type { IncomeStatementNode } from "./types";

export function IncomeStatementPage({ income, expense, totalIncome, totalExpense, netIncome, visible, sensitiveUnlocked, onToggleVisible, onUnlockSensitive, onSelectCategory }: { income: IncomeStatementNode[]; expense: IncomeStatementNode[]; totalIncome: number; totalExpense: number; netIncome: number; visible: boolean; sensitiveUnlocked: boolean; onToggleVisible: () => void; onUnlockSensitive: () => void; onSelectCategory?: (account: string) => void }) {
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
    ) : (
      <HiddenPanel text="损益表金额默认隐藏。支出可直接显示；收入和净利需要使用 Face ID / Passkey 解锁。" />
    )}


  </>;
}

function IncomeLockedPanel({ onUnlock }: { onUnlock: () => void }) {
  return <div className="rounded-xl border border-line bg-panel p-6 text-center text-sm text-stone"><p>收入分类和收入金额已隐藏。</p><button className="mt-4 rounded-xl bg-brand px-4 py-2 text-paper" onClick={onUnlock}>使用 Face ID / Passkey 查看收入</button></div>;
}

function TreeNode({ node, visible, onSelectCategory }: { node: IncomeStatementNode; visible: boolean; onSelectCategory?: (account: string) => void }) {
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
