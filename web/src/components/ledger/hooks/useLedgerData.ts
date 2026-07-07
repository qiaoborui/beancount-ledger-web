import { useCallback, useEffect, useRef, useState } from "react";
import { readLedgerCache, readLedgerCacheAsync, writeLedgerCache } from "../storage";
import { fetchJson } from "@/lib/clientFetch";
import { timeRangeToParams } from "@/lib/timeRange";
import { forgetLedgerAuthentication, hasKnownLedgerAuthentication, rememberLedgerAuthenticated } from "../authState";
import { readEncryptedLedgerCache, writeEncryptedLedgerCache } from "../offlineUnlock";
import type { AccountBalance, AccountStatus, AccountView, CreditCardAnalytics, IncomeStatementCache, InvestmentSummary, LedgerCache, LedgerIndexInfo, LedgerVersion, NetWorthPoint, NetWorthWindows, Price, ReconcileRow, Summary, TimeRange, Txn } from "../types";

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

function readDisplayLedgerCache(range: TimeRange, unlocked: boolean, valuationCurrency: string) {
  const runtimeCached = readRuntimeLedgerCache(range, unlocked, valuationCurrency);
  if (runtimeCached) return runtimeCached;
  const cached = readLedgerCache(range, valuationCurrency);
  if (!cached) return null;
  if (!unlocked) return maskSensitiveLedgerCache(cached);
  return cached.sensitiveCached ? cached : maskSensitiveLedgerCache(cached);
}

function ledgerContextKey(range: TimeRange, unlocked: boolean, valuationCurrency: string) {
  return runtimeCacheKey(range, unlocked, valuationCurrency);
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

type LedgerLoadOptions = {
  sensitiveUnlocked?: boolean;
};

function transactionHasIncome(txn: Txn) {
  return txn.postings.some((posting) => posting.account.startsWith("Income:"));
}

function offlineOrNetworkError(error: unknown) {
  return (typeof navigator !== "undefined" && !navigator.onLine) || error instanceof TypeError;
}

export function maskSensitiveLedgerCache(cache: LedgerCache): LedgerCache {
  return {
    ...cache,
    balances: {},
    accountBalances: [],
    netWorthRows: [],
    monthEndNetWorthRows: [],
    netWorthWindows: null,
    creditCards: [],
    investments: null,
    txns: cache.txns.filter((txn) => !transactionHasIncome(txn)),
    reconciliationRows: [],
    accountStatuses: [],
    incomeStatement: cache.incomeStatement ? {
      ...cache.incomeStatement,
      income: [],
      totalIncome: 0,
      netIncome: 0,
    } : null,
    sensitiveCached: false,
  };
}

export function buildLedgerCacheFromBootstrap(data: LedgerBootstrapResponse, clientUnlocked: boolean, fallbackValuationCurrency: string, version: LedgerVersion | null, savedAt = Date.now()) {
  const serverSensitiveUnlocked = Boolean(data.sensitiveUnlocked);
  const cacheUnlocked = clientUnlocked && serverSensitiveUnlocked;
  const responseValuationCurrency = data.valuationCurrency ?? fallbackValuationCurrency;
  const inc = data.incomeStatement ?? { income: [], expense: [], totalIncome: 0, totalExpense: 0, netIncome: 0, valuationCurrency: responseValuationCurrency, expenseAnalytics: [], topPayees: [], topPaymentAccounts: [] };
  const transactions = data.transactions ?? [];
  const cache: LedgerCache = {
    summary: data.summary ?? null,
    balances: cacheUnlocked ? (data.balances ?? {}) : {},
    accountBalances: cacheUnlocked ? (data.accountBalances ?? []) : [],
    netWorthRows: cacheUnlocked ? (data.netWorthHistory ?? []) : [],
    monthEndNetWorthRows: cacheUnlocked ? (data.monthEndNetWorth ?? []) : [],
    netWorthWindows: cacheUnlocked ? (data.netWorthWindows ?? null) : null,
    creditCards: cacheUnlocked ? (data.creditCards ?? []) : [],
    investments: cacheUnlocked ? (data.investments ?? null) : null,
    txns: cacheUnlocked ? transactions : transactions.filter((txn) => !transactionHasIncome(txn)),
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

export function useLedgerData({ timeRange, unlocked, valuationCurrency, onSensitiveLocked, onSensitiveUnlockChange, onAuthChange, onPasskeyRegistered, showToast }: { timeRange: TimeRange; unlocked: boolean; valuationCurrency: string; onSensitiveLocked: () => void; onSensitiveUnlockChange: (unlocked: boolean) => void; onAuthChange: (authenticated: boolean) => void; onPasskeyRegistered: (registered: boolean) => void; showToast: (kind: "info" | "success" | "error", text: string) => void }) {
  const initialCacheRef = useRef<LedgerCache | null | undefined>(undefined);
  if (initialCacheRef.current === undefined) initialCacheRef.current = readDisplayLedgerCache(timeRange, unlocked, valuationCurrency);
  const initialCache = initialCacheRef.current;
  const [summary, setSummary] = useState<Summary | null>(() => initialCache?.summary ?? null);
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
  const freshInFlightRef = useRef<Map<string, Promise<void>>>(new Map());
  const loadSequenceRef = useRef(0);
  const latestContextRef = useRef({ range: timeRange, unlocked, valuationCurrency });
  const offlineNoticeKeyRef = useRef<string | null>(null);

  latestContextRef.current = { range: timeRange, unlocked, valuationCurrency };

  const clearLedgerData = useCallback(() => {
    setSummary(null);
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
    const params = new URLSearchParams(timeRangeToParams(range));
    params.set("valuationCurrency", valuationCurrency);
    const query = params.toString();
    const inFlightKey = `${query}:${clientUnlocked ? "unlocked" : "locked"}`;
    const existing = freshInFlightRef.current.get(inFlightKey);
    if (existing) return existing;

    const run = async () => {
      const isBackground = Boolean(options.background);
      if (!isBackground) setLoadingFresh(true);
      try {
        // Phase 1: fast lite bootstrap for immediate UI
        const liteQuery = new URLSearchParams(timeRangeToParams(range));
        liteQuery.set("valuationCurrency", valuationCurrency);
        liteQuery.set("lite", "1");
        const liteData = await fetchJson<LedgerBootstrapResponse>(`/api/ledger/bootstrap?${liteQuery}`);
        const serverSensitiveUnlocked = Boolean(liteData.sensitiveUnlocked);
        if (clientUnlocked && !serverSensitiveUnlocked) {
          latestContextRef.current = { range, unlocked: false, valuationCurrency };
          onSensitiveLocked();
        }
        const version = liteData.ledgerVersion ?? await fetchLedgerVersion().catch(() => null);
        const { cache: liteCache, cacheUnlocked, responseValuationCurrency } = buildLedgerCacheFromBootstrap(liteData, clientUnlocked, valuationCurrency, version);
        applyCache(liteCache, cacheUnlocked, range, responseValuationCurrency, valuationCurrency);
        if (cacheUnlocked) {
          void writeEncryptedLedgerCache(range, liteCache, responseValuationCurrency);
          writeLedgerCache(range, maskSensitiveLedgerCache(liteCache), responseValuationCurrency);
          freshLedgerCacheKeys.add(timeRangeToParams(range) + `:${responseValuationCurrency}`);
        }

        // Phase 2: full bootstrap in background for rich data (net worth, credit cards, etc.)
        if (!isBackground) {
          const fullQuery = new URLSearchParams(timeRangeToParams(range));
          fullQuery.set("valuationCurrency", valuationCurrency);
          fetchJson<LedgerBootstrapResponse>(`/api/ledger/bootstrap?${fullQuery}`)
            .then((fullData) => {
              const fullVersion = fullData.ledgerVersion ?? version;
              const { cache: fullCache } = buildLedgerCacheFromBootstrap(fullData, clientUnlocked, valuationCurrency, fullVersion);
              applyCache(fullCache, cacheUnlocked, range, valuationCurrency, valuationCurrency);
              if (cacheUnlocked) {
                void writeEncryptedLedgerCache(range, fullCache, valuationCurrency);
                writeLedgerCache(range, maskSensitiveLedgerCache(fullCache), valuationCurrency);
                freshLedgerCacheKeys.add(timeRangeToParams(range) + `:${valuationCurrency}`);
              }
            })
            .catch(() => {}); // full bootstrap is best-effort
        }
      } finally {
        if (!isBackground) setLoadingFresh(false);
        freshInFlightRef.current.delete(inFlightKey);
      }
    };

    const promise = run();
    freshInFlightRef.current.set(inFlightKey, promise);
    return promise;
  }, [applyCache, onSensitiveLocked, unlocked, valuationCurrency]);

  const load = useCallback(async (forceFresh = false, options: LedgerLoadOptions = {}) => {
    const loadSequence = loadSequenceRef.current + 1;
    loadSequenceRef.current = loadSequence;
    const isCurrentLoad = () => loadSequenceRef.current === loadSequence;
    let me: { authenticated?: boolean; sensitiveUnlocked?: boolean };
    let passkey: { registered?: boolean };
    try {
      [me, passkey] = await Promise.all([
        fetchJson<{ authenticated?: boolean; sensitiveUnlocked?: boolean }>("/api/auth/me"),
        fetchJson<{ registered?: boolean }>("/api/passkey/status", undefined, { registered: false }).catch(() => ({ registered: false })),
      ]);
      if (!isCurrentLoad()) return;
      offlineNoticeKeyRef.current = null;
    } catch (error) {
      if (!isCurrentLoad()) return;
      if (offlineOrNetworkError(error) && hasKnownLedgerAuthentication()) {
        rememberLedgerAuthenticated();
        onAuthChange(true);
        const cached = await readLedgerCacheAsync(timeRange, valuationCurrency);
        const noticeKey = `${timeRangeToParams(timeRange)}:${valuationCurrency}:${cached ? "cached" : "empty"}`;
        if (cached) {
          const cache = unlocked ? cached : maskSensitiveLedgerCache(cached);
          applyCache(cache, unlocked, timeRange, cache.valuationCurrency ?? valuationCurrency, valuationCurrency);
          if (shouldShowOfflineLedgerNotice(offlineNoticeKeyRef.current, noticeKey)) {
            offlineNoticeKeyRef.current = noticeKey;
            showToast("info", "当前离线，已显示上次缓存的数据");
          }
        } else {
          if (shouldShowOfflineLedgerNotice(offlineNoticeKeyRef.current, noticeKey)) {
            offlineNoticeKeyRef.current = noticeKey;
            showToast("info", "当前离线，已保留登录状态；暂无缓存账本可显示");
          }
        }
        return;
      }
      throw error;
    }
    const hasPasskey = Boolean(passkey.registered);
    onPasskeyRegistered(hasPasskey);
    const authenticated = Boolean(me.authenticated);
    onAuthChange(authenticated);
    const sensitiveUnlocked = authenticated && Boolean(options.sensitiveUnlocked ?? me.sensitiveUnlocked) && !sessionStorage.getItem("ledger_locked_at");
    latestContextRef.current = { range: timeRange, unlocked: sensitiveUnlocked, valuationCurrency };
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
      latestContextRef.current = { range: timeRange, unlocked: false, valuationCurrency };
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
        const displayCache = sensitiveUnlocked && cached.sensitiveCached ? cached : maskSensitiveLedgerCache(cached);
        const cacheKey = timeRangeToParams(timeRange) + `:${valuationCurrency}`;
        applyCache(displayCache, sensitiveUnlocked, timeRange, cached.valuationCurrency ?? valuationCurrency, valuationCurrency);
        if (cached.sensitiveCached) freshLedgerCacheKeys.add(cacheKey);
        void fetchFreshLedger(timeRange, { background: true, clientUnlocked: sensitiveUnlocked }).catch(() => {});
        return;
      }
    }

    await fetchFreshLedger(timeRange, { clientUnlocked: sensitiveUnlocked });
  }, [applyCache, clearLedgerData, fetchFreshLedger, timeRange, onAuthChange, onPasskeyRegistered, onSensitiveUnlockChange, unlocked, valuationCurrency]);

  const unlockOfflineSensitiveCache = useCallback(async (secret: string) => {
    const cache = await readEncryptedLedgerCache(timeRange, valuationCurrency, secret);
    if (!cache) {
      showToast("error", "这个时间范围还没有可解密的离线缓存");
      return false;
    }
    sessionStorage.removeItem("ledger_locked_at");
    sessionStorage.removeItem("ledger_hidden_at");
    sessionStorage.setItem("ledger_unlocked", "1");
    onSensitiveUnlockChange(true);
    applyCache({ ...cache, sensitiveCached: true }, true, timeRange, cache.valuationCurrency ?? valuationCurrency, valuationCurrency);
    showToast("success", "已离线解锁缓存数据");
    return true;
  }, [applyCache, onSensitiveUnlockChange, showToast, timeRange, valuationCurrency]);

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
    unlockOfflineSensitiveCache,
  };
}
