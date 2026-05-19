import { useCallback, useEffect, useRef, useState } from "react";
import { readLedgerCacheAsync, writeLedgerCache } from "../storage";
import { fetchJson, readJson } from "@/lib/clientFetch";
import { timeRangeToParams } from "@/lib/timeRange";
import type { AccountStatus, AccountView, BudgetRow, CreditCardAnalytics, IncomeStatementCache, LedgerCache, LedgerVersion, NetWorthPoint, NetWorthWindows, ReconcileRow, Summary, TimeRange, Txn } from "../types";

const freshLedgerCacheKeys = new Set<string>();
const LEDGER_VERSION_POLL_MS = 45_000;

let runtimeLedgerCache: { key: string; cache: LedgerCache } | null = null;

function runtimeCacheKey(range: TimeRange, unlocked: boolean) {
  return `${timeRangeToParams(range)}:${unlocked ? "unlocked" : "locked"}`;
}

function readRuntimeLedgerCache(range: TimeRange, unlocked: boolean) {
  const key = runtimeCacheKey(range, unlocked);
  return runtimeLedgerCache?.key === key ? runtimeLedgerCache.cache : null;
}

function writeRuntimeLedgerCache(range: TimeRange, unlocked: boolean, cache: LedgerCache) {
  runtimeLedgerCache = { key: runtimeCacheKey(range, unlocked), cache };
}

async function fetchSensitiveJson<T>(input: RequestInfo | URL, fallback: T, onSensitiveLocked?: () => void): Promise<T> {
  const response = await fetch(input);
  if (response.status === 401 || response.status === 423) {
    if (response.status === 423) onSensitiveLocked?.();
    return fallback;
  }
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

export function useLedgerData({ timeRange, unlocked, onSensitiveLocked, onAuthChange, onPasskeyRegistered, onGitStatusRefresh, showToast }: { timeRange: TimeRange; unlocked: boolean; onSensitiveLocked: () => void; onAuthChange: (authenticated: boolean) => void; onPasskeyRegistered: (registered: boolean) => void; onGitStatusRefresh: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void }) {
  const initialRuntimeCache = readRuntimeLedgerCache(timeRange, unlocked);
  const [summary, setSummary] = useState<Summary | null>(() => initialRuntimeCache?.summary ?? null);
  const [balances, setBalances] = useState<Record<string, number>>(() => initialRuntimeCache?.balances ?? {});
  const [txns, setTxns] = useState<Txn[]>(() => initialRuntimeCache?.txns ?? []);
  const [budgetRows, setBudgetRows] = useState<BudgetRow[]>(() => initialRuntimeCache?.budgetRows ?? []);
  const [netWorthRows, setNetWorthRows] = useState<NetWorthPoint[]>(() => initialRuntimeCache?.netWorthRows ?? []);
  const [monthEndNetWorthRows, setMonthEndNetWorthRows] = useState<NetWorthPoint[]>(() => initialRuntimeCache?.monthEndNetWorthRows ?? []);
  const [netWorthWindows, setNetWorthWindows] = useState<NetWorthWindows | null>(() => initialRuntimeCache?.netWorthWindows ?? null);
  const [creditCards, setCreditCards] = useState<CreditCardAnalytics[]>(() => initialRuntimeCache?.creditCards ?? []);
  const [reconciliationRows, setReconciliationRows] = useState<ReconcileRow[]>(() => initialRuntimeCache?.reconciliationRows ?? []);
  const [accounts, setAccounts] = useState<AccountView[]>(() => initialRuntimeCache?.accounts ?? []);
  const [incomeStatement, setIncomeStatement] = useState<IncomeStatementCache>(() => initialRuntimeCache?.incomeStatement ?? null);
  const [accountStatuses, setAccountStatuses] = useState<AccountStatus[]>(() => initialRuntimeCache?.accountStatuses ?? []);
  const [loadingFresh, setLoadingFresh] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [lastSyncedAt, setLastSyncedAt] = useState<number | null>(() => initialRuntimeCache?.savedAt ?? null);
  const [ledgerVersion, setLedgerVersion] = useState<LedgerVersion | null>(() => initialRuntimeCache?.ledgerVersion ?? null);
  const freshInFlightRef = useRef<Map<string, Promise<void>>>(new Map());

  const clearLedgerData = useCallback(() => {
    setSummary(null);
    setBalances({});
    setNetWorthRows([]);
    setMonthEndNetWorthRows([]);
    setNetWorthWindows(null);
    setCreditCards([]);
    setTxns([]);
    setBudgetRows([]);
    setReconciliationRows([]);
    setAccounts([]);
    setIncomeStatement(null);
    setAccountStatuses([]);
    setLedgerVersion(null);
    setLastSyncedAt(null);
  }, []);

  const applyCache = useCallback((cache: LedgerCache) => {
    writeRuntimeLedgerCache(timeRange, unlocked, cache);
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
  }, [timeRange, unlocked]);

  const clearSensitiveData = useCallback(() => {
    setBalances({});
    setNetWorthRows([]);
    setMonthEndNetWorthRows([]);
    setNetWorthWindows(null);
    setCreditCards([]);
    setTxns([]);
    setReconciliationRows([]);
    setAccountStatuses([]);
    setIncomeStatement((current) => current ? {
      ...current,
      income: [],
      totalIncome: 0,
      netIncome: 0,
    } : null);
  }, []);

  const fetchFreshLedger = useCallback(async (range: TimeRange, options: { background?: boolean } = {}) => {
    const params = timeRangeToParams(range);
    const inFlightKey = `${params}:${unlocked ? "unlocked" : "locked"}`;
    const existing = freshInFlightRef.current.get(inFlightKey);
    if (existing) return existing;

    const run = async () => {
      if (!options.background) setLoadingFresh(true);
      try {
        const requests = [
          fetchJson<{ summary?: Summary; balances?: Record<string, number>; netWorthHistory?: NetWorthPoint[]; monthEndNetWorth?: NetWorthPoint[]; netWorthWindows?: NetWorthWindows | null; creditCards?: CreditCardAnalytics[] }>(`/api/ledger/summary?${params}`),
          fetchJson<{ transactions?: Txn[] }>(`/api/ledger/transactions?${params}`),
          fetchJson<{ rows?: BudgetRow[] }>(`/api/ledger/budget?${params}`),
          unlocked ? fetchSensitiveJson<{ rows?: ReconcileRow[] }>(`/api/ledger/reconciliation?${params}`, { rows: [] }, onSensitiveLocked) : Promise.resolve({ rows: [] }),
          fetchJson<{ accounts?: AccountView[] }>("/api/ledger/accounts"),
          fetchJson<NonNullable<IncomeStatementCache>>(`/api/ledger/income-statement?${params}`),
          unlocked ? fetchSensitiveJson<{ statuses?: AccountStatus[] }>("/api/ledger/account-status", { statuses: [] }, onSensitiveLocked) : Promise.resolve({ statuses: [] }),
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
        if (!options.background) setLoadingFresh(false);
        freshInFlightRef.current.delete(inFlightKey);
      }
    };

    const promise = run();
    freshInFlightRef.current.set(inFlightKey, promise);
    return promise;
  }, [applyCache, onGitStatusRefresh, onSensitiveLocked, unlocked]);

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
    else {
      sessionStorage.removeItem("ledger_authed");
      sessionStorage.removeItem("ledger_unlocked");
      clearLedgerData();
    }
    if (!authenticated) return;

    if (!forceFresh) {
      const runtimeCached = readRuntimeLedgerCache(timeRange, unlocked);
      if (runtimeCached) {
        applyCache(runtimeCached);
        return;
      }
    }

    if (!forceFresh && unlocked) {
      const cacheKey = timeRangeToParams(timeRange);
      const cached = await readLedgerCacheAsync(timeRange);
      if (cached) {
        applyCache(cached);
        if (freshLedgerCacheKeys.has(cacheKey)) return;
        fetchFreshLedger(timeRange, { background: true }).catch(() => {
          // Keep showing cached data if background refresh fails.
        });
        return;
      }
    }

    await fetchFreshLedger(timeRange);
  }, [applyCache, clearLedgerData, fetchFreshLedger, timeRange, onAuthChange, onPasskeyRegistered, unlocked]);

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

  useEffect(() => {
    if (!unlocked) clearSensitiveData();
  }, [clearSensitiveData, unlocked]);

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
