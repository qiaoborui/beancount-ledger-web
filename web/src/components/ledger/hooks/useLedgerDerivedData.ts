import { useMemo } from "react";
import type { AccountView, Summary } from "../types";
import { formatAccountOptionLabel } from "../accountDisplay";

export function useLedgerDerivedData({ summary, accounts, balances, netWorthRows, page }: { summary: Summary | null; accounts: AccountView[]; balances: Record<string, number>; netWorthRows: { date: string; assets: number; liabilities: number; netWorth: number }[]; page: string }) {
  const chart = useMemo(() => {
    const days = summary?.days ?? {};
    return Array.from({ length: 31 }, (_, i) => String(i + 1).padStart(2, "0")).map((day) => ({
      day: `${Number(day)}日`,
      收入: (days[day]?.income ?? 0) / 100,
      支出: (days[day]?.expense ?? 0) / 100,
    }));
  }, [summary]);

  const accountLabelMap = useMemo(() => Object.fromEntries(accounts.map((account) => [account.account, formatAccountOptionLabel(account)])), [accounts]);
  const activeAccounts = useMemo(() => accounts.filter((account) => account.active), [accounts]);
  const balanceAccounts = useMemo(() => accounts.filter((account) => !["expense", "income", "equity"].includes(account.group)), [accounts]);
  const expenseAccounts = useMemo(() => activeAccounts.filter((account) => account.group === "expense").map((account) => account.account), [activeAccounts]);
  const incomeAccounts = useMemo(() => activeAccounts.filter((account) => account.group === "income").map((account) => account.account), [activeAccounts]);
  const paymentAccounts = useMemo(() => activeAccounts.filter((account) => ["cash", "credit", "wealth", "receivable"].includes(account.group)).map((account) => account.account), [activeAccounts]);

  const visibleBalances = balanceAccounts
    .filter(({ account }) => balances[account] !== undefined || page === "accounts")
    .map((item) => ({ account: item.account, label: item.label, value: balances[item.account] ?? 0, active: item.active, group: item.group }));

  const netWorthChart = netWorthRows.map((row) => ({
    date: row.date.slice(5),
    资产: row.assets / 100,
    负债: row.liabilities / 100,
    净资产: row.netWorth / 100,
  }));

  return { chart, accountLabelMap, balanceAccounts, expenseAccounts, incomeAccounts, paymentAccounts, visibleBalances, netWorthChart };
}
