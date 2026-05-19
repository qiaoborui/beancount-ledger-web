import path from "node:path";
import { ledgerRootForUser } from "./ledgerPaths";
import { monthSummary, parseBudgets, parseTransactions } from "./beancountParser";
import { getLedgerSnapshotForUser } from "./ledgerCache";
import { formatCny } from "./money";
import type { Insight } from "./notifications";

const LARGE_EXPENSE_CENTS = 30000;

function prevMonth(month: string, offset: number) {
  const [year, m] = month.split("-").map(Number);
  const date = new Date(Date.UTC(year, m - 1 + offset, 1));
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
}

function monthEnd(month: string) {
  return prevMonth(month, 1) + "-01";
}

function sourceId(userId: string, source: { file: string; line: number }) {
  return `${path.relative(ledgerRootForUser(userId), source.file)}:${source.line}`;
}

export function detectInsightsForUser(userId: string, month: string): Insight[] {
  const snapshot = getLedgerSnapshotForUser(userId);
  const txns = parseTransactions(snapshot.lines);
  const start = `${month}-01`;
  const end = monthEnd(month);
  const currentTxns = txns.filter((txn) => txn.date >= start && txn.date < end);
  const insights: Insight[] = [];

  for (const txn of currentTxns) {
    const expense = txn.postings.filter((posting) => posting.account.startsWith("Expenses:")).reduce((sum, posting) => sum + posting.amount, 0);
    if (expense >= LARGE_EXPENSE_CENTS) {
      insights.push({ id: `large-${sourceId(userId, txn.source)}`, severity: expense >= 100000 ? "critical" : "warning", title: "大额支出", detail: `${txn.date} ${txn.payee} ${txn.narration}：${formatCny(expense / 100)}，超过 300 元阈值。`, amount: expense, date: txn.date });
    }
  }

  const budgets = parseBudgets(snapshot.lines).filter((b) => b.date <= `${month}-01`);
  const latest = new Map<string, { amount: number; date: string }>();
  for (const b of budgets) {
    const cur = latest.get(b.account);
    if (!cur || b.date >= cur.date) latest.set(b.account, { amount: b.amount, date: b.date });
  }
  const actual = monthSummary(month, txns).categories;
  for (const [account, budget] of latest) {
    const spent = actual[account] ?? 0;
    const ratio = budget.amount ? spent / budget.amount : 0;
    if (ratio >= 0.8) {
      insights.push({ id: `budget-${account}`, severity: ratio >= 1 ? "critical" : "warning", title: "预算接近上限", detail: `${account} 已用 ${Math.round(ratio * 100)}%（${formatCny(spent / 100)} / ${formatCny(budget.amount / 100)}）。`, amount: spent, account });
    }
  }

  const currentExpense = monthSummary(month, txns).expense;
  const previousExpenses = [-1, -2, -3].map((offset) => monthSummary(prevMonth(month, offset), txns).expense).filter((amount) => amount > 0);
  if (previousExpenses.length) {
    const avg = previousExpenses.reduce((sum, amount) => sum + amount, 0) / previousExpenses.length;
    if (currentExpense > avg) {
      insights.push({ id: "expense-average", severity: currentExpense >= avg * 1.2 ? "warning" : "info", title: "本月支出高于过去 3 月均值", detail: `本月 ${formatCny(currentExpense / 100)}，过去 ${previousExpenses.length} 个月平均 ${formatCny(avg / 100)}。`, amount: currentExpense });
    }
  }

  const pastPayeeCounts = new Map<string, number>();
  for (const txn of txns.filter((txn) => txn.date < start)) pastPayeeCounts.set(txn.payee, (pastPayeeCounts.get(txn.payee) ?? 0) + 1);
  for (const txn of currentTxns) {
    const expense = txn.postings.filter((posting) => posting.account.startsWith("Expenses:")).reduce((sum, posting) => sum + posting.amount, 0);
    if (expense >= 10000 && (pastPayeeCounts.get(txn.payee) ?? 0) <= 1) {
      insights.push({ id: `rare-${sourceId(userId, txn.source)}`, severity: "info", title: "不常见商户", detail: `${txn.payee} 过去很少出现，本次支出 ${formatCny(expense / 100)}。`, amount: expense, date: txn.date });
    }
  }

  const unknownTxns = currentTxns.filter((txn) => txn.postings.some((posting) => posting.account === "Expenses:Unknown"));
  const unknownAmount = unknownTxns.flatMap((txn) => txn.postings).filter((posting) => posting.account === "Expenses:Unknown").reduce((sum, posting) => sum + posting.amount, 0);
  if (unknownTxns.length >= 3 || (currentExpense > 0 && unknownAmount / currentExpense >= 0.1)) {
    insights.push({ id: "unknown-expenses", severity: "warning", title: "未分类支出偏多", detail: `Expenses:Unknown 有 ${unknownTxns.length} 笔，共 ${formatCny(unknownAmount / 100)}，建议补分类。`, amount: unknownAmount, account: "Expenses:Unknown" });
  }

  const severityRank = { critical: 0, warning: 1, info: 2 } as const;
  return insights.sort((a, b) => severityRank[a.severity] - severityRank[b.severity] || (b.amount ?? 0) - (a.amount ?? 0));
}

export function detectInsights(month: string): Insight[] {
  return detectInsightsForUser("owner", month);
}
