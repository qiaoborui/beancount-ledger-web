import { useCallback, useEffect, useState } from "react";
import { readLedgerCache, writeLedgerCache } from "../storage";
import { timeRangeToParams } from "@/lib/timeRange";
import type { AccountStatus, AccountView, BudgetRow, IncomeStatementCache, LedgerCache, ReconcileRow, Summary, TimeRange, Txn } from "../types";

const freshLedgerCacheKeys = new Set<string>();

export function useLedgerData({ timeRange, unlocked, onAuthChange, onPasskeyRegistered, onGitStatusRefresh, showToast }: { timeRange: TimeRange; unlocked: boolean; onAuthChange: (authenticated: boolean) => void; onPasskeyRegistered: (registered: boolean) => void; onGitStatusRefresh: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void }) {
  const [summary, setSummary] = useState<Summary | null>(null);
  const [balances, setBalances] = useState<Record<string, number>>({});
  const [txns, setTxns] = useState<Txn[]>([]);
  const [budgetRows, setBudgetRows] = useState<BudgetRow[]>([]);
  const [netWorthRows, setNetWorthRows] = useState<{ date: string; assets: number; liabilities: number; netWorth: number }[]>([]);
  const [reconciliationRows, setReconciliationRows] = useState<ReconcileRow[]>([]);
  const [accounts, setAccounts] = useState<AccountView[]>([]);
  const [incomeStatement, setIncomeStatement] = useState<IncomeStatementCache>(null);
  const [accountStatuses, setAccountStatuses] = useState<AccountStatus[]>([]);
  const [loadingFresh, setLoadingFresh] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [lastSyncedAt, setLastSyncedAt] = useState<number | null>(null);

  const applyCache = useCallback((cache: LedgerCache) => {
    setSummary(cache.summary);
    setBalances(cache.balances);
    setNetWorthRows(cache.netWorthRows);
    setTxns(cache.txns);
    setBudgetRows(cache.budgetRows);
    setReconciliationRows(cache.reconciliationRows ?? []);
    setAccounts(cache.accounts ?? []);
    setIncomeStatement(cache.incomeStatement ?? null);
    setAccountStatuses(cache.accountStatuses ?? []);
    setLastSyncedAt(cache.savedAt);
  }, []);

  const fetchFreshLedger = useCallback(async (range: TimeRange) => {
    setLoadingFresh(true);
    const params = timeRangeToParams(range);
    try {
      const requests = [
        fetch(`/api/ledger/summary?${params}`).then((r) => r.json()),
        fetch(`/api/ledger/transactions?${params}`).then((r) => r.json()),
        fetch(`/api/ledger/budget?${params}`).then((r) => r.json()),
        unlocked ? fetch(`/api/ledger/reconciliation?${params}`).then((r) => r.json()) : Promise.resolve({ rows: [] }),
        fetch("/api/ledger/accounts").then((r) => r.json()),
        fetch(`/api/ledger/income-statement?${params}`).then((r) => r.json()),
        unlocked ? fetch("/api/ledger/account-status").then((r) => r.json()) : Promise.resolve({ statuses: [] }),
      ] as const;
      const [s, t, b, r, a, inc, st] = await Promise.all(requests);
      const fresh: LedgerCache = {
        summary: s.summary,
        balances: unlocked ? (s.balances ?? {}) : {},
        netWorthRows: unlocked ? (s.netWorthHistory ?? []) : [],
        txns: t.transactions,
        budgetRows: b.rows,
        reconciliationRows: unlocked ? (r.rows ?? []) : [],
        accounts: a.accounts ?? [],
        accountStatuses: unlocked ? (st.statuses ?? []) : [],
        incomeStatement: { income: unlocked ? (inc.income ?? []) : [], expense: inc.expense ?? [], totalIncome: unlocked ? (inc.totalIncome ?? 0) : 0, totalExpense: inc.totalExpense ?? 0, netIncome: unlocked ? (inc.netIncome ?? 0) : 0, expenseAnalytics: inc.expenseAnalytics ?? [], topPayees: inc.topPayees ?? [], topPaymentAccounts: inc.topPaymentAccounts ?? [] },
        savedAt: Date.now(),
      };
      applyCache(fresh);
      if (unlocked) {
        writeLedgerCache(range, fresh);
        freshLedgerCacheKeys.add(timeRangeToParams(range));
      }
      onGitStatusRefresh();
    } finally {
      setLoadingFresh(false);
    }
  }, [applyCache, onGitStatusRefresh, unlocked]);

  const load = useCallback(async (forceFresh = false) => {
    const [me, passkey] = await Promise.all([
      fetch("/api/auth/me").then((r) => r.json()),
      fetch("/api/passkey/status").then((r) => r.json()).catch(() => ({ registered: false })),
    ]);
    const hasPasskey = Boolean(passkey.registered);
    onPasskeyRegistered(hasPasskey);
    onAuthChange(me.authenticated);
    if (me.authenticated) sessionStorage.setItem("ledger_authed", "1");
    else sessionStorage.removeItem("ledger_authed");
    if (!me.authenticated) return;

    if (!forceFresh && unlocked) {
      const cached = readLedgerCache(timeRange);
      if (cached) {
        applyCache(cached);
        if (freshLedgerCacheKeys.has(timeRangeToParams(timeRange))) return;
      }
    }

    await fetchFreshLedger(timeRange);
  }, [applyCache, fetchFreshLedger, timeRange, onAuthChange, onPasskeyRegistered, unlocked]);

  async function refreshLedger() {
    if (refreshing || loadingFresh) return;
    setRefreshing(true);
    try {
      await load(true);
      showToast("success", unlocked ? "已刷新到最新账本" : "已刷新普通账本数据；余额和净资产仍保持隐藏");
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : "刷新失败");
    } finally {
      setRefreshing(false);
    }
  }

  useEffect(() => { load(); }, [load]);

  return {
    summary,
    balances,
    txns,
    budgetRows,
    netWorthRows,
    reconciliationRows,
    accounts,
    incomeStatement,
    loadingFresh,
    refreshing,
    lastSyncedAt,
    load,
    accountStatuses,
    refreshLedger,
  };
}
