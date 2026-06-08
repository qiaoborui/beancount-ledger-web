import { useCallback, useEffect, useRef, useState } from "react";
import { readLedgerCacheAsync, writeLedgerCache } from "../storage";
import { fetchJson } from "@/lib/clientFetch";
import { timeRangeToParams } from "@/lib/timeRange";
import type { AccountBalance, AccountStatus, AccountView, BudgetRow, CreditCardAnalytics, IncomeStatementCache, LedgerCache, LedgerVersion, NetWorthPoint, NetWorthWindows, Price, ReconcileRow, Summary, TimeRange, Txn } from "../types";

const freshLedgerCacheKeys = new Set<string>();

let runtimeLedgerCache: { key: string; cache: LedgerCache } | null = null;

function runtimeCacheKey(range: TimeRange, unlocked: boolean, valuationCurrency: string) {
  return `${timeRangeToParams(range)}:${unlocked ? "unlocked" : "locked"}:${valuationCurrency}`;
}

function readRuntimeLedgerCache(range: TimeRange, unlocked: boolean, valuationCurrency: string) {
  const key = runtimeCacheKey(range, unlocked, valuationCurrency);
  return runtimeLedgerCache?.key === key ? runtimeLedgerCache.cache : null;
}

function writeRuntimeLedgerCache(range: TimeRange, unlocked: boolean, valuationCurrency: string, cache: LedgerCache) {
  runtimeLedgerCache = { key: runtimeCacheKey(range, unlocked, valuationCurrency), cache };
}

function ledgerContextKey(range: TimeRange, unlocked: boolean, valuationCurrency: string) {
  return runtimeCacheKey(range, unlocked, valuationCurrency);
}

async function fetchLedgerVersion(): Promise<LedgerVersion | null> {
  try {
    const data = await fetchJson<{ version?: LedgerVersion }>("/api/ledger/version", undefined, {});
    return data.version ?? null;
  } catch {
    return null;
  }
}

type LedgerBootstrapResponse = {
  summary?: Summary;
  balances?: Record<string, number>;
  accountBalances?: AccountBalance[];
  netWorthHistory?: NetWorthPoint[];
  monthEndNetWorth?: NetWorthPoint[];
  netWorthWindows?: NetWorthWindows | null;
  creditCards?: CreditCardAnalytics[];
  transactions?: Txn[];
  budgetRows?: BudgetRow[];
  reconciliationRows?: ReconcileRow[];
  accounts?: AccountView[];
  commodities?: string[];
  prices?: Price[];
  valuationCurrency?: string;
  incomeStatement?: NonNullable<IncomeStatementCache>;
  accountStatuses?: AccountStatus[];
  ledgerVersion?: LedgerVersion;
  sensitiveUnlocked?: boolean;
};

export function useLedgerData({ timeRange, unlocked, valuationCurrency, onSensitiveLocked, onSensitiveUnlockChange, onAuthChange, onPasskeyRegistered, onGitStatusRefresh, showToast }: { timeRange: TimeRange; unlocked: boolean; valuationCurrency: string; onSensitiveLocked: () => void; onSensitiveUnlockChange: (unlocked: boolean) => void; onAuthChange: (authenticated: boolean) => void; onPasskeyRegistered: (registered: boolean) => void; onGitStatusRefresh: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void }) {
  const initialRuntimeCache = readRuntimeLedgerCache(timeRange, unlocked, valuationCurrency);
  const [summary, setSummary] = useState<Summary | null>(() => initialRuntimeCache?.summary ?? null);
  const [balances, setBalances] = useState<Record<string, number>>(() => initialRuntimeCache?.balances ?? {});
  const [accountBalances, setAccountBalances] = useState<AccountBalance[]>(() => initialRuntimeCache?.accountBalances ?? []);
  const [txns, setTxns] = useState<Txn[]>(() => initialRuntimeCache?.txns ?? []);
  const [budgetRows, setBudgetRows] = useState<BudgetRow[]>(() => initialRuntimeCache?.budgetRows ?? []);
  const [netWorthRows, setNetWorthRows] = useState<NetWorthPoint[]>(() => initialRuntimeCache?.netWorthRows ?? []);
  const [monthEndNetWorthRows, setMonthEndNetWorthRows] = useState<NetWorthPoint[]>(() => initialRuntimeCache?.monthEndNetWorthRows ?? []);
  const [netWorthWindows, setNetWorthWindows] = useState<NetWorthWindows | null>(() => initialRuntimeCache?.netWorthWindows ?? null);
  const [creditCards, setCreditCards] = useState<CreditCardAnalytics[]>(() => initialRuntimeCache?.creditCards ?? []);
  const [reconciliationRows, setReconciliationRows] = useState<ReconcileRow[]>(() => initialRuntimeCache?.reconciliationRows ?? []);
  const [accounts, setAccounts] = useState<AccountView[]>(() => initialRuntimeCache?.accounts ?? []);
  const [commodities, setCommodities] = useState<string[]>(() => initialRuntimeCache?.commodities ?? ["CNY"]);
  const [prices, setPrices] = useState<Price[]>(() => initialRuntimeCache?.prices ?? []);
  const [incomeStatement, setIncomeStatement] = useState<IncomeStatementCache>(() => initialRuntimeCache?.incomeStatement ?? null);
  const [accountStatuses, setAccountStatuses] = useState<AccountStatus[]>(() => initialRuntimeCache?.accountStatuses ?? []);
  const [loadingFresh, setLoadingFresh] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [lastSyncedAt, setLastSyncedAt] = useState<number | null>(() => initialRuntimeCache?.savedAt ?? null);
  const [ledgerVersion, setLedgerVersion] = useState<LedgerVersion | null>(() => initialRuntimeCache?.ledgerVersion ?? null);
  const freshInFlightRef = useRef<Map<string, Promise<void>>>(new Map());
  const latestContextRef = useRef({ range: timeRange, unlocked, valuationCurrency });

  latestContextRef.current = { range: timeRange, unlocked, valuationCurrency };

  const clearLedgerData = useCallback(() => {
    setSummary(null);
    setBalances({});
    setAccountBalances([]);
    setNetWorthRows([]);
    setMonthEndNetWorthRows([]);
    setNetWorthWindows(null);
    setCreditCards([]);
    setTxns([]);
    setBudgetRows([]);
    setReconciliationRows([]);
    setAccounts([]);
    setCommodities(["CNY"]);
    setPrices([]);
    setIncomeStatement(null);
    setAccountStatuses([]);
    setLedgerVersion(null);
    setLastSyncedAt(null);
  }, []);

  const applyCache = useCallback((cache: LedgerCache, cacheUnlocked = unlocked, cacheRange = timeRange, cacheValuationCurrency = valuationCurrency, contextValuationCurrency = cacheValuationCurrency) => {
    writeRuntimeLedgerCache(cacheRange, cacheUnlocked, cacheValuationCurrency, cache);
    const latest = latestContextRef.current;
    if (ledgerContextKey(cacheRange, cacheUnlocked, contextValuationCurrency) !== ledgerContextKey(latest.range, latest.unlocked, latest.valuationCurrency)) {
      return;
    }
    setSummary(cache.summary);
    setBalances(cache.balances);
    setAccountBalances(cache.accountBalances ?? []);
    setNetWorthRows(cache.netWorthRows);
    setMonthEndNetWorthRows(cache.monthEndNetWorthRows ?? []);
    setNetWorthWindows(cache.netWorthWindows ?? null);
    setCreditCards(cache.creditCards ?? []);
    setTxns(cache.txns);
    setBudgetRows(cache.budgetRows);
    setReconciliationRows(cache.reconciliationRows ?? []);
    setAccounts(cache.accounts ?? []);
    setCommodities(cache.commodities?.length ? cache.commodities : ["CNY"]);
    setPrices(cache.prices ?? []);
    setIncomeStatement(cache.incomeStatement ?? null);
    setAccountStatuses(cache.accountStatuses ?? []);
    setLedgerVersion(cache.ledgerVersion ?? null);
    setLastSyncedAt(cache.savedAt);
  }, [timeRange, unlocked, valuationCurrency]);

  const clearSensitiveData = useCallback(() => {
    setBalances({});
    setAccountBalances([]);
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
    const params = new URLSearchParams(timeRangeToParams(range));
    params.set("valuationCurrency", valuationCurrency);
    const query = params.toString();
    const inFlightKey = `${query}:${unlocked ? "unlocked" : "locked"}`;
    const existing = freshInFlightRef.current.get(inFlightKey);
    if (existing) return existing;

    const run = async () => {
      if (!options.background) setLoadingFresh(true);
      try {
        const data = await fetchJson<LedgerBootstrapResponse>(`/api/ledger/bootstrap?${query}`);
        const sensitiveUnlocked = Boolean(data.sensitiveUnlocked);
        const responseValuationCurrency = data.valuationCurrency ?? valuationCurrency;
        if (unlocked && !sensitiveUnlocked) onSensitiveLocked();
        const inc = data.incomeStatement ?? { income: [], expense: [], totalIncome: 0, totalExpense: 0, netIncome: 0, valuationCurrency: responseValuationCurrency, expenseAnalytics: [], topPayees: [], topPaymentAccounts: [] };
        const version = data.ledgerVersion ?? await fetchLedgerVersion();
        const fresh: LedgerCache = {
          summary: data.summary ?? null,
          balances: sensitiveUnlocked ? (data.balances ?? {}) : {},
          accountBalances: sensitiveUnlocked ? (data.accountBalances ?? []) : [],
          netWorthRows: sensitiveUnlocked ? (data.netWorthHistory ?? []) : [],
          monthEndNetWorthRows: sensitiveUnlocked ? (data.monthEndNetWorth ?? []) : [],
          netWorthWindows: sensitiveUnlocked ? (data.netWorthWindows ?? null) : null,
          creditCards: sensitiveUnlocked ? (data.creditCards ?? []) : [],
          txns: data.transactions ?? [],
          budgetRows: data.budgetRows ?? [],
          reconciliationRows: sensitiveUnlocked ? (data.reconciliationRows ?? []) : [],
          accounts: data.accounts ?? [],
          commodities: data.commodities ?? ["CNY"],
          prices: data.prices ?? [],
          valuationCurrency: responseValuationCurrency,
          accountStatuses: sensitiveUnlocked ? (data.accountStatuses ?? []) : [],
          incomeStatement: { income: sensitiveUnlocked ? (inc.income ?? []) : [], expense: inc.expense ?? [], totalIncome: sensitiveUnlocked ? (inc.totalIncome ?? 0) : 0, totalExpense: inc.totalExpense ?? 0, netIncome: sensitiveUnlocked ? (inc.netIncome ?? 0) : 0, valuationCurrency: inc.valuationCurrency ?? responseValuationCurrency, expenseAnalytics: inc.expenseAnalytics ?? [], topPayees: inc.topPayees ?? [], topPaymentAccounts: inc.topPaymentAccounts ?? [] },
          ledgerVersion: version ?? undefined,
          savedAt: Date.now(),
        };
        applyCache(fresh, sensitiveUnlocked, range, responseValuationCurrency, valuationCurrency);
        if (sensitiveUnlocked) {
          writeLedgerCache(range, fresh, responseValuationCurrency);
          freshLedgerCacheKeys.add(timeRangeToParams(range) + `:${responseValuationCurrency}`);
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
  }, [applyCache, onGitStatusRefresh, onSensitiveLocked, unlocked, valuationCurrency]);

  const load = useCallback(async (forceFresh = false) => {
    const [me, passkey] = await Promise.all([
      fetchJson<{ authenticated?: boolean; sensitiveUnlocked?: boolean }>("/api/auth/me"),
      fetchJson<{ registered?: boolean }>("/api/passkey/status", undefined, { registered: false }).catch(() => ({ registered: false })),
    ]);
    const hasPasskey = Boolean(passkey.registered);
    onPasskeyRegistered(hasPasskey);
    const authenticated = Boolean(me.authenticated);
    onAuthChange(authenticated);
    if (authenticated) {
      sessionStorage.setItem("ledger_authed", "1");
      if (me.sensitiveUnlocked && !sessionStorage.getItem("ledger_locked_at")) {
        sessionStorage.setItem("ledger_unlocked", "1");
        onSensitiveUnlockChange(true);
      } else {
        sessionStorage.removeItem("ledger_unlocked");
        onSensitiveUnlockChange(false);
      }
    }
    else {
      sessionStorage.removeItem("ledger_authed");
      sessionStorage.removeItem("ledger_unlocked");
      onSensitiveUnlockChange(false);
      clearLedgerData();
    }
    if (!authenticated) return;

    if (!forceFresh) {
      const runtimeCached = readRuntimeLedgerCache(timeRange, unlocked, valuationCurrency);
      if (runtimeCached) {
        applyCache(runtimeCached);
        return;
      }
    }

    if (!forceFresh && unlocked) {
      const cacheKey = timeRangeToParams(timeRange) + `:${valuationCurrency}`;
      const cached = await readLedgerCacheAsync(timeRange, valuationCurrency);
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
  }, [applyCache, clearLedgerData, fetchFreshLedger, timeRange, onAuthChange, onPasskeyRegistered, onSensitiveUnlockChange, unlocked, valuationCurrency]);

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
    accountBalances,
    txns,
    budgetRows,
    netWorthRows,
    monthEndNetWorthRows,
    netWorthWindows,
    creditCards,
    reconciliationRows,
    accounts,
    commodities,
    prices,
    incomeStatement,
    loadingFresh,
    refreshing,
    lastSyncedAt,
    ledgerVersion,
    load,
    accountStatuses,
    refreshLedger,
  };
}
