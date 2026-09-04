import { useCallback, useEffect, useRef, useState } from "react";
import { isSensitiveIncomeTransaction, maskSensitiveLedgerCache, maskSensitivePeriodComparisons, readLedgerCache, readLedgerCacheAsync, writeLedgerCache } from "../storage";
import { fetchJson } from "@/lib/clientFetch";
import { comparisonCacheIdentity, localToday, timeRangeToParams } from "@/lib/timeRange";
import { forgetLedgerAuthentication, hasKnownLedgerAuthentication, rememberLedgerAuthenticated } from "../authState";
import type { AccountBalance, AccountStatus, AccountView, CreditCardAnalytics, IncomeStatementCache, InvestmentSummary, LedgerCache, LedgerIndexInfo, LedgerPeriodComparisons, LedgerVersion, NetWorthPoint, NetWorthWindows, Price, ReconcileRow, Summary, TimeRange, Txn } from "../types";
import { apiEndpointLedgerScope } from "@/lib/apiEndpoints";
import i18n from "@/i18n";

let runtimeLedgerCache: { key: string; cache: LedgerCache } | null = null;

function runtimeCacheKey(range: TimeRange, unlocked: boolean, valuationCurrency: string, ledgerScope = apiEndpointLedgerScope(), comparisonDate = localToday()) {
  return `${ledgerScope}:${timeRangeToParams(range)}:${unlocked ? "unlocked" : "locked"}:${valuationCurrency}:${comparisonCacheIdentity(range, comparisonDate)}`;
}

function readRuntimeLedgerCache(range: TimeRange, unlocked: boolean, valuationCurrency: string) {
  const key = runtimeCacheKey(range, unlocked, valuationCurrency);
  return runtimeLedgerCache?.key === key ? runtimeLedgerCache.cache : null;
}

function writeRuntimeLedgerCache(range: TimeRange, unlocked: boolean, valuationCurrency: string, cache: LedgerCache, ledgerScope = apiEndpointLedgerScope()) {
  runtimeLedgerCache = { key: runtimeCacheKey(range, unlocked, valuationCurrency, ledgerScope, cache.comparisonDate ?? localToday()), cache };
}

function readDisplayLedgerCache(range: TimeRange, unlocked: boolean, valuationCurrency: string) {
  const runtimeCached = readRuntimeLedgerCache(range, unlocked, valuationCurrency);
  if (runtimeCached) return runtimeCached;
  const cached = readLedgerCache(range, valuationCurrency);
  if (!cached) return null;
  return maskSensitiveLedgerCache(cached);
}

function ledgerContextKey(range: TimeRange, unlocked: boolean, valuationCurrency: string, ledgerScope = apiEndpointLedgerScope(), comparisonDate = localToday()) {
  return runtimeCacheKey(range, unlocked, valuationCurrency, ledgerScope, comparisonDate);
}

export async function fetchLedgerIndexInfo(): Promise<LedgerIndexInfo | null> {
  try {
    return await fetchJson<LedgerIndexInfo>("/api/ledger/index-info");
  } catch {
    return null;
  }
}

async function fetchLedgerVersion(): Promise<LedgerVersion | null> {
  try {
    return await fetchJson<LedgerVersion>("/api/ledger/version");
  } catch {
    return null;
  }
}

export type LedgerBootstrapResponse = {
  summary?: Summary;
  comparisons?: LedgerPeriodComparisons | null;
  balances?: Record<string, number>;
  accountBalances?: AccountBalance[];
  netWorthHistory?: NetWorthPoint[];
  monthEndNetWorth?: NetWorthPoint[];
  netWorthWindows?: NetWorthWindows | null;
  creditCards?: CreditCardAnalytics[];
  investments?: InvestmentSummary | null;
  transactions?: Txn[];
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

export function bootstrapSensitiveUnlockState(data: LedgerBootstrapResponse): boolean | null {
  return typeof data.sensitiveUnlocked === "boolean" ? data.sensitiveUnlocked : null;
}

type LedgerLoadOptions = {
  sensitiveUnlocked?: boolean;
};

function offlineOrNetworkError(error: unknown) {
  return (typeof navigator !== "undefined" && !navigator.onLine) || error instanceof TypeError;
}

export function buildLedgerCacheFromBootstrap(data: LedgerBootstrapResponse, clientUnlocked: boolean, fallbackValuationCurrency: string, version: LedgerVersion | null, savedAt = Date.now(), comparisonDate = localToday()) {
  const serverSensitiveUnlocked = bootstrapSensitiveUnlockState(data) === true;
  const cacheUnlocked = clientUnlocked && serverSensitiveUnlocked;
  const responseValuationCurrency = data.valuationCurrency ?? fallbackValuationCurrency;
  const inc = data.incomeStatement ?? { income: [], expense: [], totalIncome: 0, totalExpense: 0, netIncome: 0, valuationCurrency: responseValuationCurrency, expenseAnalytics: [], topPayees: [], topPaymentAccounts: [] };
  const transactions = data.transactions ?? [];
  const cache: LedgerCache = {
    summary: data.summary ?? null,
    comparisons: cacheUnlocked ? (data.comparisons ?? null) : maskSensitivePeriodComparisons(data.comparisons),
    comparisonDate,
    balances: cacheUnlocked ? (data.balances ?? {}) : {},
    accountBalances: cacheUnlocked ? (data.accountBalances ?? []) : [],
    netWorthRows: cacheUnlocked ? (data.netWorthHistory ?? []) : [],
    monthEndNetWorthRows: cacheUnlocked ? (data.monthEndNetWorth ?? []) : [],
    netWorthWindows: cacheUnlocked ? (data.netWorthWindows ?? null) : null,
    creditCards: cacheUnlocked ? (data.creditCards ?? []) : [],
    investments: cacheUnlocked ? (data.investments ?? null) : null,
    txns: cacheUnlocked ? transactions : transactions.filter((txn) => !isSensitiveIncomeTransaction(txn)),
    reconciliationRows: cacheUnlocked ? (data.reconciliationRows ?? []) : [],
    accounts: data.accounts ?? [],
    commodities: data.commodities ?? ["CNY"],
    prices: data.prices ?? [],
    valuationCurrency: responseValuationCurrency,
    accountStatuses: cacheUnlocked ? (data.accountStatuses ?? []) : [],
    incomeStatement: { income: cacheUnlocked ? (inc.income ?? []) : [], expense: inc.expense ?? [], totalIncome: cacheUnlocked ? (inc.totalIncome ?? 0) : 0, totalExpense: inc.totalExpense ?? 0, netIncome: cacheUnlocked ? (inc.netIncome ?? 0) : 0, valuationCurrency: inc.valuationCurrency ?? responseValuationCurrency, expenseAnalytics: inc.expenseAnalytics ?? [], topPayees: inc.topPayees ?? [], topPaymentAccounts: inc.topPaymentAccounts ?? [] },
    ledgerVersion: version ?? undefined,
    savedAt,
    sensitiveCached: cacheUnlocked,
  };
  return { cache, cacheUnlocked, serverSensitiveUnlocked, responseValuationCurrency };
}

export function shouldShowOfflineLedgerNotice(previousKey: string | null, nextKey: string) {
  return previousKey !== nextKey;
}

export function useLedgerData({ timeRange, unlocked, valuationCurrency, onSensitiveUnlockChange, onAuthChange, onPasskeyRegistered, showToast }: { timeRange: TimeRange; unlocked: boolean; valuationCurrency: string; onSensitiveUnlockChange: (unlocked: boolean) => void; onAuthChange: (authenticated: boolean) => void; onPasskeyRegistered: (registered: boolean) => void; showToast: (kind: "info" | "success" | "error", text: string) => void }) {
  const initialCacheRef = useRef<LedgerCache | null | undefined>(undefined);
  if (initialCacheRef.current === undefined) initialCacheRef.current = readDisplayLedgerCache(timeRange, unlocked, valuationCurrency);
  const initialCache = initialCacheRef.current;
  const [summary, setSummary] = useState<Summary | null>(() => initialCache?.summary ?? null);
  const [comparisons, setComparisons] = useState<LedgerPeriodComparisons | null>(() => initialCache?.comparisons ?? null);
  const [balances, setBalances] = useState<Record<string, number>>(() => initialCache?.balances ?? {});
  const [accountBalances, setAccountBalances] = useState<AccountBalance[]>(() => initialCache?.accountBalances ?? []);
  const [txns, setTxns] = useState<Txn[]>(() => initialCache?.txns ?? []);
  const [netWorthRows, setNetWorthRows] = useState<NetWorthPoint[]>(() => initialCache?.netWorthRows ?? []);
  const [monthEndNetWorthRows, setMonthEndNetWorthRows] = useState<NetWorthPoint[]>(() => initialCache?.monthEndNetWorthRows ?? []);
  const [netWorthWindows, setNetWorthWindows] = useState<NetWorthWindows | null>(() => initialCache?.netWorthWindows ?? null);
  const [creditCards, setCreditCards] = useState<CreditCardAnalytics[]>(() => initialCache?.creditCards ?? []);
  const [investments, setInvestments] = useState<InvestmentSummary | null>(() => initialCache?.investments ?? null);
  const [reconciliationRows, setReconciliationRows] = useState<ReconcileRow[]>(() => initialCache?.reconciliationRows ?? []);
  const [accounts, setAccounts] = useState<AccountView[]>(() => initialCache?.accounts ?? []);
  const [commodities, setCommodities] = useState<string[]>(() => initialCache?.commodities ?? ["CNY"]);
  const [prices, setPrices] = useState<Price[]>(() => initialCache?.prices ?? []);
  const [incomeStatement, setIncomeStatement] = useState<IncomeStatementCache>(() => initialCache?.incomeStatement ?? null);
  const [accountStatuses, setAccountStatuses] = useState<AccountStatus[]>(() => initialCache?.accountStatuses ?? []);
  const [loadingFresh, setLoadingFresh] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [lastSyncedAt, setLastSyncedAt] = useState<number | null>(() => initialCache?.savedAt ?? null);
  const [ledgerVersion, setLedgerVersion] = useState<LedgerVersion | null>(() => initialCache?.ledgerVersion ?? null);
  const comparisonDateRef = useRef<string | null>(initialCache?.comparisonDate ?? null);
  const freshInFlightRef = useRef<Map<string, Promise<void>>>(new Map());
  const loadSequenceRef = useRef(0);
  const latestContextRef = useRef({ range: timeRange, unlocked, valuationCurrency, ledgerScope: apiEndpointLedgerScope() });
  const offlineNoticeKeyRef = useRef<string | null>(null);
  const showToastRef = useRef(showToast);

  latestContextRef.current = { range: timeRange, unlocked, valuationCurrency, ledgerScope: apiEndpointLedgerScope() };
  showToastRef.current = showToast;

  const clearLedgerData = useCallback(() => {
    setSummary(null);
    setComparisons(null);
    comparisonDateRef.current = null;
    setBalances({});
    setAccountBalances([]);
    setNetWorthRows([]);
    setMonthEndNetWorthRows([]);
    setNetWorthWindows(null);
    setCreditCards([]);
    setInvestments(null);
    setTxns([]);
    setReconciliationRows([]);
    setAccounts([]);
    setCommodities(["CNY"]);
    setPrices([]);
    setIncomeStatement(null);
    setAccountStatuses([]);
    setLedgerVersion(null);
    setLastSyncedAt(null);
  }, []);

  const applyCache = useCallback((cache: LedgerCache, cacheUnlocked = unlocked, cacheRange = timeRange, cacheValuationCurrency = valuationCurrency, contextValuationCurrency = cacheValuationCurrency, cacheLedgerScope = apiEndpointLedgerScope()) => {
    writeRuntimeLedgerCache(cacheRange, cacheUnlocked, cacheValuationCurrency, cache, cacheLedgerScope);
    const latest = latestContextRef.current;
    if (ledgerContextKey(cacheRange, cacheUnlocked, contextValuationCurrency, cacheLedgerScope, cache.comparisonDate ?? localToday()) !== ledgerContextKey(latest.range, latest.unlocked, latest.valuationCurrency, latest.ledgerScope)) {
      return;
    }
    comparisonDateRef.current = cache.comparisonDate ?? null;
    setSummary(cache.summary);
    setComparisons(cacheUnlocked ? (cache.comparisons ?? null) : maskSensitivePeriodComparisons(cache.comparisons));
    setBalances(cache.balances);
    setAccountBalances(cache.accountBalances ?? []);
    setNetWorthRows(cache.netWorthRows);
    setMonthEndNetWorthRows(cache.monthEndNetWorthRows ?? []);
    setNetWorthWindows(cache.netWorthWindows ?? null);
    setCreditCards(cache.creditCards ?? []);
    setInvestments(cache.investments ?? null);
    setTxns(cache.txns);
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
    setComparisons((current) => maskSensitivePeriodComparisons(current));
    setBalances({});
    setAccountBalances([]);
    setNetWorthRows([]);
    setMonthEndNetWorthRows([]);
    setNetWorthWindows(null);
    setCreditCards([]);
    setInvestments(null);
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

  const fetchFreshLedger = useCallback(async (range: TimeRange, options: { background?: boolean; clientUnlocked?: boolean } = {}) => {
    const clientUnlocked = options.clientUnlocked ?? unlocked;
    const ledgerScope = apiEndpointLedgerScope();
    const comparisonDate = localToday();
    const params = new URLSearchParams(timeRangeToParams(range));
    params.set("valuationCurrency", valuationCurrency);
    params.set("today", comparisonDate);
    const query = params.toString();
    const inFlightKey = `${ledgerScope}:${query}:${clientUnlocked ? "unlocked" : "locked"}`;
    const existing = freshInFlightRef.current.get(inFlightKey);
    if (existing) return existing;

    const run = async () => {
      const isBackground = Boolean(options.background);
      if (!isBackground) setLoadingFresh(true);
      try {
        // Phase 1: fast lite bootstrap for immediate UI
        const liteQuery = new URLSearchParams(timeRangeToParams(range));
        liteQuery.set("valuationCurrency", valuationCurrency);
        liteQuery.set("today", comparisonDate);
        liteQuery.set("lite", "1");
        const liteData = await fetchJson<LedgerBootstrapResponse>(`/api/ledger/bootstrap?${liteQuery}`, { cache: "no-store" });
        if (apiEndpointLedgerScope() !== ledgerScope) return;
        const serverSensitiveUnlocked = bootstrapSensitiveUnlockState(liteData);
        if (clientUnlocked && serverSensitiveUnlocked === false) {
          latestContextRef.current = { range, unlocked: false, valuationCurrency, ledgerScope };
          sessionStorage.removeItem("ledger_unlocked");
          onSensitiveUnlockChange(false);
        }
        const version = liteData.ledgerVersion ?? await fetchLedgerVersion().catch(() => null);
        if (apiEndpointLedgerScope() !== ledgerScope) return;
        const { cache: liteCache, cacheUnlocked, responseValuationCurrency } = buildLedgerCacheFromBootstrap(liteData, clientUnlocked, valuationCurrency, version, Date.now(), comparisonDate);
        applyCache(liteCache, cacheUnlocked, range, responseValuationCurrency, valuationCurrency, ledgerScope);
        if (cacheUnlocked && comparisonDate === localToday()) {
          writeLedgerCache(range, liteCache, responseValuationCurrency, ledgerScope);
        }

        // Phase 2: full bootstrap in background for rich data (net worth, credit cards, etc.)
        const fullQuery = new URLSearchParams(timeRangeToParams(range));
        fullQuery.set("valuationCurrency", valuationCurrency);
        fullQuery.set("today", comparisonDate);
        const fullData = await fetchJson<LedgerBootstrapResponse>(`/api/ledger/bootstrap?${fullQuery}`, { cache: "no-store" });
        if (apiEndpointLedgerScope() !== ledgerScope) return;
        const fullVersion = fullData.ledgerVersion ?? version;
        const {
          cache: fullCache,
          cacheUnlocked: fullCacheUnlocked,
          responseValuationCurrency: fullResponseValuationCurrency,
        } = buildLedgerCacheFromBootstrap(fullData, clientUnlocked, valuationCurrency, fullVersion, Date.now(), comparisonDate);
        if (clientUnlocked && bootstrapSensitiveUnlockState(fullData) === false) {
          latestContextRef.current = { range, unlocked: false, valuationCurrency, ledgerScope };
          sessionStorage.removeItem("ledger_unlocked");
          onSensitiveUnlockChange(false);
        }
        applyCache(fullCache, fullCacheUnlocked, range, fullResponseValuationCurrency, valuationCurrency, ledgerScope);
        if (fullCacheUnlocked && comparisonDate === localToday()) {
          writeLedgerCache(range, fullCache, fullResponseValuationCurrency, ledgerScope);
        }
      } finally {
        if (!isBackground) setLoadingFresh(false);
        freshInFlightRef.current.delete(inFlightKey);
      }
    };

    const promise = run();
    freshInFlightRef.current.set(inFlightKey, promise);
    return promise;
  }, [applyCache, onSensitiveUnlockChange, unlocked, valuationCurrency]);

  const load = useCallback(async (forceFresh = false, options: LedgerLoadOptions = {}) => {
    const loadSequence = loadSequenceRef.current + 1;
    const ledgerScope = apiEndpointLedgerScope();
    loadSequenceRef.current = loadSequence;
    const isCurrentLoad = () => loadSequenceRef.current === loadSequence && apiEndpointLedgerScope() === ledgerScope;
    let me: { authenticated?: boolean; sensitiveUnlocked?: boolean };
    let passkey: { registered?: boolean };
    try {
      [me, passkey] = await Promise.all([
        fetchJson<{ authenticated?: boolean; sensitiveUnlocked?: boolean }>("/api/auth/me", { cache: "no-store" }),
        fetchJson<{ registered?: boolean }>("/api/passkey/status", { cache: "no-store" }, { registered: false }).catch(() => ({ registered: false })),
      ]);
      if (!isCurrentLoad()) return;
      offlineNoticeKeyRef.current = null;
    } catch (error) {
      if (!isCurrentLoad()) return;
      if (hasKnownLedgerAuthentication()) {
        rememberLedgerAuthenticated();
        onAuthChange(true);
        const cached = await readLedgerCacheAsync(timeRange, valuationCurrency);
        const noticeKey = `${timeRangeToParams(timeRange)}:${valuationCurrency}:${cached ? "cached" : "empty"}`;
        if (cached) {
          applyCache(cached, unlocked, timeRange, cached.valuationCurrency ?? valuationCurrency, valuationCurrency, ledgerScope);
          if (shouldShowOfflineLedgerNotice(offlineNoticeKeyRef.current, noticeKey)) {
            offlineNoticeKeyRef.current = noticeKey;
            showToastRef.current("info", offlineOrNetworkError(error) ? i18n.t("ledgerData.offlineCached") : i18n.t("ledgerData.backendAuthUnverified"));
          }
        } else {
          if (shouldShowOfflineLedgerNotice(offlineNoticeKeyRef.current, noticeKey)) {
            offlineNoticeKeyRef.current = noticeKey;
            showToastRef.current("info", offlineOrNetworkError(error) ? i18n.t("ledgerData.offlineLoggedIn") : i18n.t("ledgerData.backendUnverifiedSwitch"));
          }
        }
        return;
      }
      onPasskeyRegistered(false);
      onAuthChange(false);
      onSensitiveUnlockChange(false);
      latestContextRef.current = { range: timeRange, unlocked: false, valuationCurrency, ledgerScope };
      clearLedgerData();
      showToastRef.current("error", i18n.t("ledgerData.cannotConnect"));
      return;
    }
    const hasPasskey = Boolean(passkey.registered);
    onPasskeyRegistered(hasPasskey);
    const authenticated = Boolean(me.authenticated);
    onAuthChange(authenticated);
    const sensitiveUnlocked = authenticated && Boolean(options.sensitiveUnlocked ?? me.sensitiveUnlocked) && !sessionStorage.getItem("ledger_locked_at");
    latestContextRef.current = { range: timeRange, unlocked: sensitiveUnlocked, valuationCurrency, ledgerScope };
    if (authenticated) {
      rememberLedgerAuthenticated();
      if (sensitiveUnlocked) {
        sessionStorage.setItem("ledger_unlocked", "1");
        onSensitiveUnlockChange(true);
      } else {
        sessionStorage.removeItem("ledger_unlocked");
        onSensitiveUnlockChange(false);
      }
    }
    else {
      forgetLedgerAuthentication();
      onSensitiveUnlockChange(false);
      latestContextRef.current = { range: timeRange, unlocked: false, valuationCurrency, ledgerScope };
      clearLedgerData();
    }
    if (!authenticated) return;

    if (!forceFresh) {
      const runtimeCached = readRuntimeLedgerCache(timeRange, sensitiveUnlocked, valuationCurrency);
      if (runtimeCached) {
        applyCache(runtimeCached, sensitiveUnlocked);
        void fetchFreshLedger(timeRange, { background: true, clientUnlocked: sensitiveUnlocked }).catch(() => {});
        return;
      }
      const cached = await readLedgerCacheAsync(timeRange, valuationCurrency);
      if (!isCurrentLoad()) return;
      if (cached) {
        applyCache(cached, sensitiveUnlocked, timeRange, cached.valuationCurrency ?? valuationCurrency, valuationCurrency);
        void fetchFreshLedger(timeRange, { background: true, clientUnlocked: sensitiveUnlocked }).catch(() => {});
        return;
      }
    }

    await fetchFreshLedger(timeRange, { clientUnlocked: sensitiveUnlocked });
  }, [applyCache, clearLedgerData, fetchFreshLedger, timeRange, onAuthChange, onPasskeyRegistered, onSensitiveUnlockChange, unlocked, valuationCurrency]);

  async function refreshLedger() {
    if (refreshing || loadingFresh) return;
    setRefreshing(true);
    try {
      await load(true);
      showToast("success", unlocked ? i18n.t("ledgerData.refreshedLatest") : i18n.t("ledgerData.refreshedHidden"));
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : i18n.t("ledgerData.refreshFailed"));
    } finally {
      setRefreshing(false);
    }
  }

  useEffect(() => {
    if (!unlocked) clearSensitiveData();
  }, [clearSensitiveData, unlocked]);

  useEffect(() => {
    let cancelled = false;
    let timeoutId = 0;
    const schedule = () => {
      const now = new Date();
      const nextMidnight = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
      timeoutId = window.setTimeout(() => {
        const today = localToday();
        const comparisonDate = comparisonDateRef.current;
        if (comparisonCacheIdentity(timeRange, comparisonDate) !== comparisonCacheIdentity(timeRange, today)) {
          setComparisons(null);
          comparisonDateRef.current = today;
        }
        void load(true).catch((error) => {
          showToastRef.current("error", error instanceof Error ? error.message : i18n.t("ledgerData.loadFailed"));
        }).finally(() => {
          if (!cancelled) schedule();
        });
      }, Math.max(1, nextMidnight.getTime() - now.getTime()));
    };
    schedule();
    return () => {
      cancelled = true;
      window.clearTimeout(timeoutId);
    };
  }, [load, timeRange]);

  useEffect(() => {
    void load().catch((error) => {
      showToastRef.current("error", error instanceof Error ? error.message : i18n.t("ledgerData.loadFailed"));
    });
  }, [load]);

  return {
    summary,
    comparisons,
    balances,
    accountBalances,
    txns,
    netWorthRows,
    monthEndNetWorthRows,
    netWorthWindows,
    creditCards,
    investments,
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
