import { useMemo } from "react";
import type { AccountBalance, AccountView, Summary } from "../types";
import { formatAccountOptionLabel } from "../accountDisplay";

export function useLedgerDerivedData({ summary, accounts, balances, accountBalances, netWorthRows, page, valuationCurrency }: { summary: Summary | null; accounts: AccountView[]; balances: Record<string, number>; accountBalances: AccountBalance[]; netWorthRows: { date: string; assets: number; liabilities: number; netWorth: number }[]; page: string; valuationCurrency: string }) {
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
  const expenseAccounts = useMemo(() => activeAccounts.filter((account) => account.group === "expense").map((account) => account.account), [activeAccounts]);
  const incomeAccounts = useMemo(() => activeAccounts.filter((account) => account.group === "income").map((account) => account.account), [activeAccounts]);
  const paymentAccounts = useMemo(() => activeAccounts.filter((account) => ["cash", "credit", "wealth", "receivable"].includes(account.group)).map((account) => account.account), [activeAccounts]);

  const balancesByAccount = useMemo(() => {
    const out = new Map<string, AccountBalance[]>();
    for (const row of accountBalances) {
      const rows = out.get(row.account) ?? [];
      rows.push(row);
      out.set(row.account, rows);
    }
    return out;
  }, [accountBalances]);

  const balanceAccounts = useMemo(() => accounts.filter((account) => isBalanceAccount(account, balancesByAccount) && !["expense", "income", "equity"].includes(account.group)), [accounts, balancesByAccount]);
  const accountPageAccounts = useMemo(() => accounts.filter((account) => isVisibleAccountPageAccount(account, balances, balancesByAccount)), [accounts, balances, balancesByAccount]);

  const visibleBalances = balanceAccounts
    .filter((account) => page === "accounts" ? isVisibleAccountPageAccount(account, balances, balancesByAccount) : balances[account.account] !== undefined || balancesByAccount.has(account.account))
    .map((item) => accountBalanceDisplayRow(item, balances[item.account], balancesByAccount.get(item.account) ?? [], valuationCurrency));

  const netWorthChart = netWorthRows.map((row) => ({
    date: row.date.slice(5),
    资产: row.assets / 100,
    负债: row.liabilities / 100,
    净资产: row.netWorth / 100,
  }));

  return { chart, accountLabelMap, accountPageAccounts, balanceAccounts, expenseAccounts, incomeAccounts, paymentAccounts, visibleBalances, netWorthChart };
}

function isMonetaryAccount(account: AccountView) {
  const currency = account.currency || "CNY";
  return ["CNY", "USD", "HKD", "GBP", "EUR", "JPY"].includes(currency);
}

function isBalanceAccount(account: AccountView, balancesByAccount: Map<string, AccountBalance[]>) {
  return isMonetaryAccount(account) || balancesByAccount.has(account.account);
}

function hasOwnBalance(balances: Record<string, number>, account: string) {
  return Object.prototype.hasOwnProperty.call(balances, account);
}

function hasNonZeroBalance(nativeBalance: number | undefined, rows: AccountBalance[]) {
  if (nativeBalance !== undefined && nativeBalance !== 0) return true;
  return rows.some((row) => row.amount !== 0 || row.valuation !== 0);
}

function isVisibleAccountPageAccount(account: AccountView, balances: Record<string, number>, balancesByAccount: Map<string, AccountBalance[]>) {
  const rows = balancesByAccount.get(account.account) ?? [];
  const hasLedgerActivity = hasOwnBalance(balances, account.account) || rows.length > 0;
  return hasLedgerActivity && hasNonZeroBalance(balances[account.account], rows);
}

function accountBalanceDisplayRow(account: AccountView, nativeBalance: number | undefined, rows: AccountBalance[], fallbackValuationCurrency: string) {
  const usableRows = rows.filter((row) => row.amount !== 0 || row.valuation !== 0);
  if (usableRows.length === 1) {
    const row = usableRows[0];
    return { account: account.account, label: account.label, value: row.amount, currency: row.currency, active: account.active, group: account.group };
  }
  if (usableRows.length > 1) {
    const valuedRows = usableRows.filter((row) => !row.valuationMissing);
    const valuationCurrency = valuedRows[0]?.valuationCurrency ?? usableRows[0]?.valuationCurrency ?? fallbackValuationCurrency;
    return { account: account.account, label: account.label, value: valuedRows.reduce((sum, row) => sum + row.valuation, 0), currency: valuationCurrency, active: account.active, group: account.group, valuation: true };
  }
  return { account: account.account, label: account.label, value: nativeBalance ?? 0, currency: account.currency || fallbackValuationCurrency, active: account.active, group: account.group };
}
