import type { AccountView, TransactionView } from "./beancountParser";

export type NetWorthPoint = { date: string; assets: number; liabilities: number; netWorth: number };
export type NetWorthDelta = { baseline: NetWorthPoint | null; change: number | null; changeRatio: number | null };
export type NetWorthWindows = {
  latest: NetWorthPoint | null;
  previousMonthEnd: NetWorthPoint | null;
  monthChange: number | null;
  sixMonth: NetWorthDelta;
  twelveMonth: NetWorthDelta;
};
export type CreditCardAnalytics = {
  account: string;
  label: string;
  balance: number;
  outstanding: number;
  periodSpend: number;
  periodRepayments: number;
  billCycleSpend: number;
  billCycleStart: string;
  billCycleEnd: string;
  statementDate: string;
  dueDate: string;
  txCount: number;
  repaymentCount: number;
  lastActivityDate: string | null;
};

export function monthEndNetWorth(rows: NetWorthPoint[]): NetWorthPoint[] {
  const byMonth = new Map<string, NetWorthPoint>();
  for (const row of [...rows].sort((a, b) => a.date.localeCompare(b.date))) {
    byMonth.set(row.date.slice(0, 7), row);
  }
  return Array.from(byMonth.values());
}

export function netWorthChangeWindows(rows: NetWorthPoint[]): NetWorthWindows {
  const monthly = monthEndNetWorth(rows);
  const latest = rows.at(-1) ?? null;
  const previousMonthEnd = monthly.length >= 2 ? monthly.at(-2)! : null;
  return {
    latest,
    previousMonthEnd,
    monthChange: latest && previousMonthEnd ? latest.netWorth - previousMonthEnd.netWorth : null,
    sixMonth: deltaFromMonthly(monthly, latest, 6),
    twelveMonth: deltaFromMonthly(monthly, latest, 12),
  };
}

function deltaFromMonthly(monthly: NetWorthPoint[], latest: NetWorthPoint | null, months: number): NetWorthDelta {
  if (!latest || !monthly.length) return { baseline: null, change: null, changeRatio: null };
  const baseline = monthly.length > months ? monthly.at(-(months + 1))! : monthly[0] ?? null;
  if (!baseline) return { baseline: null, change: null, changeRatio: null };
  const change = latest.netWorth - baseline.netWorth;
  return { baseline, change, changeRatio: baseline.netWorth !== 0 ? change / Math.abs(baseline.netWorth) : null };
}

export function creditCardAnalytics(
  txns: TransactionView[],
  balances: Record<string, number>,
  accounts: AccountView[],
  start: string,
  end: string,
  asOf = new Date().toISOString().slice(0, 10),
): CreditCardAnalytics[] {
  const billing = creditCardBillingCycle(asOf);
  const cards = accounts.filter((account) => account.group === "credit" && account.account.startsWith("Liabilities:"));
  return cards.map((card) => {
    let periodSpend = 0;
    let periodRepayments = 0;
    let billCycleSpend = 0;
    let txCount = 0;
    let repaymentCount = 0;
    let lastActivityDate: string | null = null;

    for (const txn of txns) {
      const cardPostingTotal = txn.postings.filter((posting) => posting.account === card.account).reduce((sum, posting) => sum + posting.amount, 0);
      if (cardPostingTotal !== 0 && (!lastActivityDate || txn.date > lastActivityDate)) lastActivityDate = txn.date;
      const expenseAmount = txn.postings.filter((posting) => posting.account.startsWith("Expenses:")).reduce((sum, posting) => sum + posting.amount, 0);
      const assetOutflow = txn.postings.filter((posting) => posting.account.startsWith("Assets:") && posting.amount < 0).reduce((sum, posting) => sum + Math.abs(posting.amount), 0);
      const cardSpend = expenseAmount > 0 && cardPostingTotal < 0 ? Math.min(expenseAmount, Math.abs(cardPostingTotal)) : 0;

      if (txn.date >= billing.billCycleStart && txn.date < billing.billCycleEnd && cardSpend > 0) {
        billCycleSpend += cardSpend;
      }

      if (txn.date < start || txn.date >= end || cardPostingTotal === 0) continue;

      if (cardSpend > 0) {
        periodSpend += cardSpend;
        txCount += 1;
      } else if (assetOutflow > 0 && cardPostingTotal > 0) {
        periodRepayments += Math.min(assetOutflow, cardPostingTotal);
        repaymentCount += 1;
      }
    }

    const balance = balances[card.account] ?? 0;
    return {
      account: card.account,
      label: card.label,
      balance,
      outstanding: Math.max(0, Math.abs(Math.min(balance, 0))),
      periodSpend,
      periodRepayments,
      billCycleSpend,
      ...billing,
      txCount,
      repaymentCount,
      lastActivityDate,
    };
  }).sort((a, b) => b.outstanding - a.outstanding || b.periodSpend - a.periodSpend || a.label.localeCompare(b.label));
}

export function creditCardBillingCycle(asOf: string) {
  const [year, month, day] = asOf.split("-").map(Number);
  const cycleStartMonth = day >= 17 ? month : month - 1;
  const start = dateString(year, cycleStartMonth, 17);
  const end = dateString(year, cycleStartMonth + 1, 17);
  const statementDate = dateString(year, cycleStartMonth + 1, 18);
  const dueDate = dateString(year, cycleStartMonth + 2, 5);
  return { billCycleStart: start, billCycleEnd: end, statementDate, dueDate };
}

function dateString(year: number, month: number, day: number) {
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.toISOString().slice(0, 10);
}
