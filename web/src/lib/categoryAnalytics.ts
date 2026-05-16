import type { TransactionView } from "./beancountParser";

export type PayeeAnalytics = {
  payee: string;
  amount: number;
  txCount: number;
};

export type AccountAnalytics = {
  account: string;
  amount: number;
  txCount: number;
};

export type ExpenseCategoryAnalytics = {
  account: string;
  label: string;
  amount: number;
  txCount: number;
  share: number | null;
  previousAmount: number;
  changeRatio: number | null;
  topPayees: PayeeAnalytics[];
};

export type ExpenseAnalyticsSummary = {
  categories: ExpenseCategoryAnalytics[];
  topPayees: PayeeAnalytics[];
  topPaymentAccounts: AccountAnalytics[];
};

type CategoryAccumulator = {
  amount: number;
  txnIds: Set<string>;
  payees: Map<string, { amount: number; txnIds: Set<string> }>;
};

function txnId(txn: TransactionView): string {
  return `${txn.source.file}:${txn.source.line}`;
}

function labelForAccount(account: string): string {
  return account.split(":").pop() ?? account;
}

function previousRange(start: string, end: string): { start: string; end: string } {
  const startDate = new Date(`${start}T00:00:00Z`);
  const endDate = new Date(`${end}T00:00:00Z`);
  const durationMs = endDate.getTime() - startDate.getTime();
  const previousStart = new Date(startDate.getTime() - durationMs);
  const fmt = (date: Date) => date.toISOString().slice(0, 10);
  return { start: fmt(previousStart), end: start };
}

function collectExpenseCategories(txns: TransactionView[], start: string, end: string): Map<string, CategoryAccumulator> {
  const categories = new Map<string, CategoryAccumulator>();

  for (const txn of txns) {
    if (txn.date < start || txn.date >= end) continue;
    const id = txnId(txn);
    for (const posting of txn.postings) {
      if (!posting.account.startsWith("Expenses:")) continue;
      const category = categories.get(posting.account) ?? { amount: 0, txnIds: new Set<string>(), payees: new Map<string, { amount: number; txnIds: Set<string> }>() };
      category.amount += posting.amount;
      category.txnIds.add(id);

      const payeeName = txn.payee || "（无商户）";
      const payee = category.payees.get(payeeName) ?? { amount: 0, txnIds: new Set<string>() };
      payee.amount += posting.amount;
      payee.txnIds.add(id);
      category.payees.set(payeeName, payee);

      categories.set(posting.account, category);
    }
  }

  return categories;
}

function periodTransactions(txns: TransactionView[], start: string, end: string): TransactionView[] {
  return txns.filter((txn) => txn.date >= start && txn.date < end);
}

function summarizeTopPayees(txns: TransactionView[], start: string, end: string): PayeeAnalytics[] {
  const payees = new Map<string, { amount: number; txnIds: Set<string> }>();
  for (const txn of periodTransactions(txns, start, end)) {
    const expense = txn.postings.filter((posting) => posting.account.startsWith("Expenses:")).reduce((sum, posting) => sum + posting.amount, 0);
    if (expense <= 0) continue;
    const payeeName = txn.payee || "（无商户）";
    const row = payees.get(payeeName) ?? { amount: 0, txnIds: new Set<string>() };
    row.amount += expense;
    row.txnIds.add(txnId(txn));
    payees.set(payeeName, row);
  }
  return Array.from(payees.entries())
    .map(([payee, row]) => ({ payee, amount: row.amount, txCount: row.txnIds.size }))
    .sort((a, b) => b.amount - a.amount || b.txCount - a.txCount || a.payee.localeCompare(b.payee))
    .slice(0, 8);
}

function summarizeTopPaymentAccounts(txns: TransactionView[], start: string, end: string): AccountAnalytics[] {
  const accounts = new Map<string, { amount: number; txnIds: Set<string> }>();
  for (const txn of periodTransactions(txns, start, end)) {
    const hasExpense = txn.postings.some((posting) => posting.account.startsWith("Expenses:"));
    if (!hasExpense) continue;
    const id = txnId(txn);
    for (const posting of txn.postings) {
      if (!(posting.account.startsWith("Assets:") || posting.account.startsWith("Liabilities:"))) continue;
      const outflow = -posting.amount;
      if (outflow <= 0) continue;
      const row = accounts.get(posting.account) ?? { amount: 0, txnIds: new Set<string>() };
      row.amount += outflow;
      row.txnIds.add(id);
      accounts.set(posting.account, row);
    }
  }
  return Array.from(accounts.entries())
    .map(([account, row]) => ({ account, amount: row.amount, txCount: row.txnIds.size }))
    .sort((a, b) => b.amount - a.amount || b.txCount - a.txCount || a.account.localeCompare(b.account))
    .slice(0, 8);
}

export function expenseCategoryAnalytics(txns: TransactionView[], start: string, end: string): ExpenseCategoryAnalytics[] {
  const current = collectExpenseCategories(txns, start, end);
  const previous = previousRange(start, end);
  const previousCategories = collectExpenseCategories(txns, previous.start, previous.end);
  const totalExpense = Array.from(current.values()).reduce((sum, row) => sum + row.amount, 0);

  return Array.from(current.entries())
    .map(([account, row]) => {
      const previousAmount = previousCategories.get(account)?.amount ?? 0;
      const changeRatio = previousAmount === 0 ? (row.amount === 0 ? 0 : null) : (row.amount - previousAmount) / previousAmount;
      const topPayees = Array.from(row.payees.entries())
        .map(([payee, payeeRow]) => ({ payee, amount: payeeRow.amount, txCount: payeeRow.txnIds.size }))
        .sort((a, b) => b.amount - a.amount || b.txCount - a.txCount || a.payee.localeCompare(b.payee))
        .slice(0, 3);

      return {
        account,
        label: labelForAccount(account),
        amount: row.amount,
        txCount: row.txnIds.size,
        share: totalExpense > 0 ? row.amount / totalExpense : null,
        previousAmount,
        changeRatio,
        topPayees,
      };
    })
    .sort((a, b) => b.amount - a.amount || a.account.localeCompare(b.account));
}

export function expenseAnalyticsSummary(txns: TransactionView[], start: string, end: string): ExpenseAnalyticsSummary {
  return {
    categories: expenseCategoryAnalytics(txns, start, end),
    topPayees: summarizeTopPayees(txns, start, end),
    topPaymentAccounts: summarizeTopPaymentAccounts(txns, start, end),
  };
}
