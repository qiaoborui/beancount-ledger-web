"use client";

import { useState, type ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { ArrowDownRight, ArrowUpRight, ChevronDown, ChevronRight, Eye, EyeOff } from "lucide-react";
import { formatValuation } from "@/lib/money";
import { CashFlowCard } from "./CashFlowCard";
import { HiddenPanel, Metric, ResponsiveValueRow } from "./shared";
import { formatAccountOptionLabel } from "./accountDisplay";
import type { AccountAnalytics, ExpenseCategoryAnalytics, IncomeStatementNode, PayeeAnalytics } from "./types";

export function IncomeStatementPage({ income, expense, expenseAnalytics, topPayees, topPaymentAccounts, totalIncome, totalExpense, netIncome, valuationCurrency, visible, sensitiveUnlocked, onToggleVisible, onUnlockSensitive, onSelectCategory }: { income: IncomeStatementNode[]; expense: IncomeStatementNode[]; expenseAnalytics: ExpenseCategoryAnalytics[]; topPayees: PayeeAnalytics[]; topPaymentAccounts: AccountAnalytics[]; totalIncome: number; totalExpense: number; netIncome: number; valuationCurrency: string; visible: boolean; sensitiveUnlocked: boolean; onToggleVisible: () => void; onUnlockSensitive: () => void; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  const { t } = useTranslation();
  return <div className="ledger-workbench">
    <section className="card overflow-hidden p-0">
      <div className="border-b border-line p-4 md:p-5">
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="text-[11px] uppercase tracking-[0.2em] text-stone">{t("incomeStatement.eyebrow")}</div>
            <h1 className="mt-1.5 font-serif text-2xl font-medium leading-tight md:text-3xl">{t("incomeStatement.title")}</h1>
            <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{t("incomeStatement.subtitle")}</p>
          </div>
          <button className="shrink-0 rounded-xl border border-line bg-panel px-3 py-2 text-sm text-olive hover:bg-tag" onClick={onToggleVisible} title={visible ? t("incomeStatement.hideAmounts") : t("incomeStatement.showAmounts")} aria-label={visible ? t("incomeStatement.hideAmounts") : t("incomeStatement.showAmounts")}>
            {visible ? <EyeOff className="h-4 w-4 text-brand" /> : <Eye className="h-4 w-4 text-brand" />}
          </button>
        </div>
      </div>
      <div className="grid grid-cols-3 divide-x divide-line border-t border-line p-3 text-center md:p-4">
        <Metric label={t("incomeStatement.income")} value={visible && sensitiveUnlocked ? formatValuation(totalIncome / 100, valuationCurrency) : "••••••"} cls="amount-income text-base sm:text-xl" />
        <Metric label={t("incomeStatement.expense")} value={visible ? formatValuation(totalExpense / 100, valuationCurrency) : "••••••"} cls="amount-expense text-base sm:text-xl" />
        <Metric label={t("incomeStatement.net")} value={visible && sensitiveUnlocked ? formatValuation(netIncome / 100, valuationCurrency) : "••••••"} cls="amount-gold text-base sm:text-xl" />
      </div>
    </section>

    {visible ? (
      <>
      <CashFlowCard income={income} expense={expense} expenseAnalytics={expenseAnalytics} totalIncome={totalIncome} totalExpense={totalExpense} valuationCurrency={valuationCurrency} sensitiveUnlocked={sensitiveUnlocked} />
      <CategoryAnalyticsPanel rows={expenseAnalytics} topPayees={topPayees} topPaymentAccounts={topPaymentAccounts} valuationCurrency={valuationCurrency} onSelectCategory={onSelectCategory} />
      <div className="mt-px grid gap-px bg-line lg:grid-cols-2">
        <div className="card p-4">
          <h2 className="mb-3 font-serif text-xl text-warm">{t("incomeStatement.income")}</h2>
          {sensitiveUnlocked ? (income.length === 0 ? <div className="py-8 text-center text-sm text-stone">{t("incomeStatement.noIncome")}</div> : income.map((node) => <TreeNode key={node.account} node={node} visible={visible} valuationCurrency={valuationCurrency} onSelectCategory={onSelectCategory} />)) : <IncomeLockedPanel onUnlock={onUnlockSensitive} />}
        </div>
        <div className="card p-4">
          <h2 className="mb-3 font-serif text-xl text-warm">{t("incomeStatement.expense")}</h2>
          {expense.length === 0 ? <div className="py-8 text-center text-sm text-stone">{t("incomeStatement.noExpense")}</div> : expense.map((node) => <TreeNode key={node.account} node={node} visible={visible} valuationCurrency={valuationCurrency} onSelectCategory={onSelectCategory} />)}
        </div>
      </div>
      </>
    ) : (
      <HiddenPanel text={t("incomeStatement.hidden")} />
    )}


  </div>;
}

function IncomeLockedPanel({ onUnlock }: { onUnlock: () => void }) {
  const { t } = useTranslation();
  return <div className="rounded-xl border border-line bg-panel p-6 text-center text-sm text-stone"><p>{t("incomeStatement.incomeLocked")}</p><button className="mt-4 rounded-xl bg-brand px-4 py-2 text-paper" onClick={onUnlock}>{t("incomeStatement.unlockIncome")}</button></div>;
}

function formatPercent(value: number | null): string {
  if (value == null || !Number.isFinite(value)) return "—";
  return `${Math.round(value * 100)}%`;
}

function formatChange(value: number | null): string {
  const { t } = useTranslation();
  if (value == null || !Number.isFinite(value)) return t("incomeStatement.new");
  if (value === 0) return t("incomeStatement.unchanged");
  const sign = value > 0 ? "+" : "";
  return `${sign}${Math.round(value * 100)}%`;
}

function RankList({ rows, empty, valuationCurrency }: { rows: { key: string; label: string; amount: number; detail: string }[]; empty: string; valuationCurrency: string }) {
  if (!rows.length) return <div className="rounded-xl border border-line bg-paper p-4 text-sm text-stone">{empty}</div>;
  return <div className="@container grid gap-2">
    {rows.slice(0, 5).map((row, index) => <div key={row.key} className="grid min-w-0 grid-cols-[auto_minmax(0,1fr)] items-center gap-x-3 gap-y-1 rounded-xl border border-line bg-paper p-3 @sm:grid-cols-[auto_minmax(0,1fr)_auto]">
      <span className="grid h-6 w-6 shrink-0 place-items-center rounded-full bg-tag text-xs text-stone">{index + 1}</span>
      <div className="min-w-0 flex-1">
        <div className="truncate text-sm font-medium text-warm">{row.label}</div>
        <div className="mt-0.5 text-xs text-stone">{row.detail}</div>
      </div>
      <strong className="col-start-2 min-w-0 max-w-full truncate justify-self-end text-right text-sm tabular-nums amount-expense @sm:col-start-auto" title={formatValuation(row.amount / 100, valuationCurrency)}>{formatValuation(row.amount / 100, valuationCurrency)}</strong>
    </div>)}
  </div>;
}

function CategoryAnalyticsPanel({ rows, topPayees, topPaymentAccounts, valuationCurrency, onSelectCategory }: { rows: ExpenseCategoryAnalytics[]; topPayees: PayeeAnalytics[]; topPaymentAccounts: AccountAnalytics[]; valuationCurrency: string; onSelectCategory?: (account: string, mode?: "exact" | "prefix") => void }) {
  const { t } = useTranslation();
  const topRows = rows.slice(0, 5);
  const unknown = rows.find((row) => row.account === "Expenses:Unknown");
  if (!rows.length) return null;

  return <section className="mt-4">
    <h2 className="border-l-2 border-brand pl-3 font-serif text-xl text-warm">{t("incomeStatement.expenseAnalysis")}</h2>
    <div className="mt-3 grid items-start gap-4 xl:grid-cols-2">
      <CollapsibleAnalysisCard title={t("incomeStatement.topCategories")} subtitle={t("incomeStatement.topCategoriesHint")}>
        <div className="mt-3 grid gap-2 md:grid-cols-2 xl:grid-cols-1 2xl:grid-cols-2">
          {topRows.map((row) => <button key={row.account} className="rounded-xl border border-line bg-panel p-3 text-left transition-colors hover:bg-tag" onClick={() => onSelectCategory?.(row.account, "prefix")}>
            <ResponsiveValueRow
              label={formatAccountOptionLabel(row.account, row.label, row.alias)}
              labelClassName="truncate text-sm font-medium text-warm"
              value={formatValuation(row.amount / 100, valuationCurrency)}
              valueClassName="text-sm font-medium amount-expense"
              valueTitle={formatValuation(row.amount / 100, valuationCurrency)}
              detail={<span className="flex flex-wrap items-center gap-x-2 gap-y-0.5"><span>{t("incomeStatement.txCountShare", { count: row.txCount, share: formatPercent(row.share) })}</span><span className={`inline-flex items-center gap-0.5 ${row.changeRatio != null && row.changeRatio > 0 ? "amount-expense" : "amount-income"}`}>{row.changeRatio != null && row.changeRatio > 0 ? <ArrowUpRight className="h-3 w-3" /> : <ArrowDownRight className="h-3 w-3" />}{formatChange(row.changeRatio)}</span></span>}
              detailClassName="text-xs text-stone"
            />
          </button>)}
        </div>
      </CollapsibleAnalysisCard>
      <CollapsibleAnalysisCard title={t("incomeStatement.topMerchants")} subtitle={t("incomeStatement.topMerchantsHint")}>
        <RankList rows={topPayees.map((row) => ({ key: row.payee, label: row.payee, amount: row.amount, detail: t("incomeStatement.txCount", { count: row.txCount }) }))} empty={t("incomeStatement.noMerchantExpense")} valuationCurrency={valuationCurrency} />
      </CollapsibleAnalysisCard>
      <CollapsibleAnalysisCard title={t("incomeStatement.toOrganize")} subtitle={unknown ? t("incomeStatement.toOrganizeFound") : t("incomeStatement.toOrganizeStatus")}>
        {unknown ? <button className="w-full rounded-xl border border-[var(--danger)]/30 bg-paper p-4 text-left transition-colors hover:bg-tag" onClick={() => onSelectCategory?.("Expenses:Unknown", "exact")}>
          <div className="text-sm font-medium text-[var(--danger)]">Expenses:Unknown</div>
          <div className="mt-2 min-w-0 truncate text-2xl font-semibold tabular-nums text-warm" title={formatValuation(unknown.amount / 100, valuationCurrency)}>{formatValuation(unknown.amount / 100, valuationCurrency)}</div>
          <div className="mt-1 text-xs text-stone">{t("incomeStatement.txCountShare", { count: unknown.txCount, share: formatPercent(unknown.share) })}</div>
          {unknown.topPayees.length > 0 && <div className="mt-3 flex flex-wrap gap-1">{unknown.topPayees.map((payee) => <span key={payee.payee} className="max-w-full rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone [overflow-wrap:anywhere]">{payee.payee} · {formatValuation(payee.amount / 100, valuationCurrency)}</span>)}</div>}
        </button> : <div className="rounded-xl border border-line bg-paper p-4 text-sm text-stone">{t("incomeStatement.noUnknown")}</div>}
      </CollapsibleAnalysisCard>
      <CollapsibleAnalysisCard title={t("incomeStatement.topPaymentAccounts")} subtitle={t("incomeStatement.topPaymentAccountsHint")}>
        <RankList rows={topPaymentAccounts.map((row) => ({ key: row.account, label: formatAccountOptionLabel(row.account, row.label, row.alias), amount: row.amount, detail: t("incomeStatement.txCount", { count: row.txCount }) }))} empty={t("incomeStatement.noPaymentAccountExpense")} valuationCurrency={valuationCurrency} />
      </CollapsibleAnalysisCard>
    </div>
  </section>;
}

function CollapsibleAnalysisCard({ title, subtitle, children }: { title: string; subtitle: string; children: ReactNode }) {
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
  const { t } = useTranslation();
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
      {isLeaf && <span className="shrink-0 text-xs text-stone">{t("incomeStatement.txCount", { count: node.txCount })}</span>}
    </button>
    {hasChildren && expanded && (
      <div className="relative" style={{ marginLeft: indentLeft }}>
        <div className="absolute bottom-0 left-[0.5625rem] top-0 w-px border-l border-dashed border-line" />
        {node.children.map((child) => <TreeNode key={child.account} node={child} visible={visible} valuationCurrency={valuationCurrency} onSelectCategory={onSelectCategory} />)}
      </div>
    )}
  </div>;
}
