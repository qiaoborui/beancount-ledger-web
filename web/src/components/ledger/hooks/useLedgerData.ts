import { useCallback, useEffect, useState } from "react";
import { readLedgerCache, writeLedgerCache } from "../storage";
import { fetchJson, readJson } from "@/lib/clientFetch";
import { timeRangeToParams } from "@/lib/timeRange";
import type { AccountStatus, AccountView, BudgetRow, CreditCardAnalytics, IncomeStatementCache, LedgerCache, LedgerVersion, NetWorthPoint, NetWorthWindows, ReconcileRow, Summary, TimeRange, Txn } from "../types";

const freshLedgerCacheKeys = new Set<string>();
const LEDGER_VERSION_POLL_MS = 45_000;

async function fetchSensitiveJson<T>(input: RequestInfo | URL, fallback: T): Promise<T> {
  const response = await fetch(input);
  if (response.status === 401 || response.status === 423) return fallback;
  return readJson<T>(response, fallback);
}

async function fetchLedgerVersion(): Promise<LedgerVersion | null> {
  try {
    const data = await fetchJson<{ version?: LedgerVersion }>("/api/ledger/version", undefined, {});
    return data.version ?? null;
  } catch {
    return null;
  }
}

export function useLedgerData({ timeRange, unlocked, onAuthChange, onPasskeyRegistered, onGitStatusRefresh, showToast }: { timeRange: TimeRange; unlocked: boolean; onAuthChange: (authenticated: boolean) => void; onPasskeyRegistered: (registered: boolean) => void; onGitStatusRefresh: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void }) {
  const [summary, setSummary] = useState<Summary | null>(null);
  const [balances, setBalances] = useState<Record<string, number>>({});
  const [txns, setTxns] = useState<Txn[]>([]);
  const [budgetRows, setBudgetRows] = useState<BudgetRow[]>([]);
  const [netWorthRows, setNetWorthRows] = useState<NetWorthPoint[]>([]);
  const [monthEndNetWorthRows, setMonthEndNetWorthRows] = useState<NetWorthPoint[]>([]);
  const [netWorthWindows, setNetWorthWindows] = useState<NetWorthWindows | null>(null);
  const [creditCards, setCreditCards] = useState<CreditCardAnalytics[]>([]);
  const [reconciliationRows, setReconciliationRows] = useState<ReconcileRow[]>([]);
  const [accounts, setAccounts] = useState<AccountView[]>([]);
  const [incomeStatement, setIncomeStatement] = useState<IncomeStatementCache>(null);
  const [accountStatuses, setAccountStatuses] = useState<AccountStatus[]>([]);
  const [loadingFresh, setLoadingFresh] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [lastSyncedAt, setLastSyncedAt] = useState<number | null>(null);
  const [ledgerVersion, setLedgerVersion] = useState<LedgerVersion | null>(null);

  const applyCache = useCallback((cache: LedgerCache) => {
    setSummary(cache.summary);
    setBalances(cache.balances);
    setNetWorthRows(cache.netWorthRows);
    setMonthEndNetWorthRows(cache.monthEndNetWorthRows ?? []);
    setNetWorthWindows(cache.netWorthWindows ?? null);
    setCreditCards(cache.creditCards ?? []);
    setTxns(cache.txns);
    setBudgetRows(cache.budgetRows);
    setReconciliationRows(cache.reconciliationRows ?? []);
    setAccounts(cache.accounts ?? []);
    setIncomeStatement(cache.incomeStatement ?? null);
    setAccountStatuses(cache.accountStatuses ?? []);
    setLedgerVersion(cache.ledgerVersion ?? null);
    setLastSyncedAt(cache.savedAt);
  }, []);

  const fetchFreshLedger = useCallback(async (range: TimeRange) => {
    setLoadingFresh(true);
    const params = timeRangeToParams(range);
    try {
      const requests = [
        fetchJson<{ summary?: Summary; balances?: Record<string, number>; netWorthHistory?: NetWorthPoint[]; monthEndNetWorth?: NetWorthPoint[]; netWorthWindows?: NetWorthWindows | null; creditCards?: CreditCardAnalytics[] }>(`/api/ledger/summary?${params}`),
        fetchJson<{ transactions?: Txn[] }>(`/api/ledger/transactions?${params}`),
        fetchJson<{ rows?: BudgetRow[] }>(`/api/ledger/budget?${params}`),
        unlocked ? fetchSensitiveJson<{ rows?: ReconcileRow[] }>(`/api/ledger/reconciliation?${params}`, { rows: [] }) : Promise.resolve({ rows: [] }),
        fetchJson<{ accounts?: AccountView[] }>("/api/ledger/accounts"),
        fetchJson<NonNullable<IncomeStatementCache>>(`/api/ledger/income-statement?${params}`),
        unlocked ? fetchSensitiveJson<{ statuses?: AccountStatus[] }>("/api/ledger/account-status", { statuses: [] }) : Promise.resolve({ statuses: [] }),
      ] as const;
      const [s, t, b, r, a, inc, st, version] = await Promise.all([...requests, fetchLedgerVersion()]);
      const fresh: LedgerCache = {
        summary: s.summary ?? null,
        balances: unlocked ? (s.balances ?? {}) : {},
        netWorthRows: unlocked ? (s.netWorthHistory ?? []) : [],
        monthEndNetWorthRows: unlocked ? (s.monthEndNetWorth ?? []) : [],
        netWorthWindows: unlocked ? (s.netWorthWindows ?? null) : null,
        creditCards: unlocked ? (s.creditCards ?? []) : [],
        txns: t.transactions ?? [],
        budgetRows: b.rows ?? [],
        reconciliationRows: unlocked ? (r.rows ?? []) : [],
        accounts: a.accounts ?? [],
        accountStatuses: unlocked ? (st.statuses ?? []) : [],
        incomeStatement: { income: unlocked ? (inc.income ?? []) : [], expense: inc.expense ?? [], totalIncome: unlocked ? (inc.totalIncome ?? 0) : 0, totalExpense: inc.totalExpense ?? 0, netIncome: unlocked ? (inc.netIncome ?? 0) : 0, expenseAnalytics: inc.expenseAnalytics ?? [], topPayees: inc.topPayees ?? [], topPaymentAccounts: inc.topPaymentAccounts ?? [] },
        ledgerVersion: version ?? undefined,
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
      fetchJson<{ authenticated?: boolean }>("/api/auth/me"),
      fetchJson<{ registered?: boolean }>("/api/passkey/status", undefined, { registered: false }).catch(() => ({ registered: false })),
    ]);
    const hasPasskey = Boolean(passkey.registered);
    onPasskeyRegistered(hasPasskey);
    const authenticated = Boolean(me.authenticated);
    onAuthChange(authenticated);
    if (authenticated) sessionStorage.setItem("ledger_authed", "1");
    else sessionStorage.removeItem("ledger_authed");
    if (!authenticated) return;

    if (!forceFresh && unlocked) {
      const cached = readLedgerCache(timeRange);
      if (cached) {
        applyCache(cached);
        if (freshLedgerCacheKeys.has(timeRangeToParams(timeRange))) return;
      }
    }

    await fetchFreshLedger(timeRange);
  }, [applyCache, fetchFreshLedger, timeRange, onAuthChange, onPasskeyRegistered, unlocked]);

  useEffect(() => {
    if (authedPollDisabled()) return;
    let cancelled = false;
    let timer: number | null = null;

    async function checkVersion() {
      if (cancelled || refreshing || loadingFresh) return;
      try {
        const latest = await fetchLedgerVersion();
        if (cancelled || !latest) return;
        if (!ledgerVersion) {
          setLedgerVersion(latest);
          return;
        }
        if ((latest.version ?? latest.signature) !== (ledgerVersion.version ?? ledgerVersion.signature)) {
          showToast("info", "账本已更新，正在刷新数据");
          await load(true);
        }
      } catch {
        // Version polling is best-effort; keep the current data if the lightweight check fails.
      }
    }

    timer = window.setInterval(checkVersion, LEDGER_VERSION_POLL_MS);
    document.addEventListener("visibilitychange", checkVersion);
    return () => {
      cancelled = true;
      if (timer) window.clearInterval(timer);
      document.removeEventListener("visibilitychange", checkVersion);
    };
  }, [ledgerVersion, load, loadingFresh, refreshing, showToast]);

  function authedPollDisabled() {
    return typeof window === "undefined" || !summary;
  }

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
    monthEndNetWorthRows,
    netWorthWindows,
    creditCards,
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
