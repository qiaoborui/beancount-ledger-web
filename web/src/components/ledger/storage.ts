import { readIndexedCache, writeIndexedCache } from "@/lib/indexedLedgerCache";
import type { LedgerCache, LedgerNavHref, LedgerPeriodComparisons, MetricPeriodComparisons, PrivacySettings, ThemeMode } from "./types";
import type { TimeRange } from "@/lib/timeRange";
import { comparisonCacheIdentity, localToday, timeRangeCacheKey } from "@/lib/timeRange";
import { apiEndpointLedgerScope, apiEndpointPreviousLedgerScope, apiEndpointStorageKeyForLedgerScope } from "@/lib/apiEndpoints";

export const defaultPrivacySettings: PrivacySettings = {
  homePage: "agent",
  showHomeSummaryAmounts: true,
  showAccountBalancesByDefault: false,
  showNetWorthByDefault: false,
  showIncomeStatementByDefault: false,
  valuationCurrency: "CNY",
};

export const defaultMobileTabHrefs: LedgerNavHref[] = ["/home", "/transactions", "/accounts"];

const allLedgerNavHrefs: LedgerNavHref[] = ["/agent", "/home", "/dashboard", "/advice", "/transactions", "/accounts", "/imports", "/editor", "/net-worth", "/investments", "/income-statement", "/currencies", "/reconcile", "/settings"];
const privacySettingsKey = "ledger_privacy_settings";
const themeModeKey = "ledger_theme_mode";
const mobileTabsKey = "ledger_mobile_tabs";
const legacyCacheScopeKey = "ledger_cache_legacy_scope:v1";

function legacyCacheBelongsToScope(ledgerScope: string) {
  if (typeof window === "undefined") return false;
  try {
    const claimed = localStorage.getItem(legacyCacheScopeKey);
    if (claimed) {
      if (claimed === ledgerScope) return true;
      if (claimed === apiEndpointPreviousLedgerScope() && ledgerScope.startsWith("cluster:")) {
        localStorage.setItem(legacyCacheScopeKey, ledgerScope);
        return localStorage.getItem(legacyCacheScopeKey) === ledgerScope;
      }
      return false;
    }
    localStorage.setItem(legacyCacheScopeKey, ledgerScope);
    return localStorage.getItem(legacyCacheScopeKey) === ledgerScope;
  } catch {
    return false;
  }
}

function readLocalLedgerCache(key: string): LedgerCache | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) as LedgerCache : null;
  } catch {
    return null;
  }
}

export function isSensitiveIncomeTransaction(txn: LedgerCache["txns"][number]) {
  return txn.postings.some((posting) => posting.account.startsWith("Income:"));
}

function maskMetricPeriodComparisons(comparisons: MetricPeriodComparisons): MetricPeriodComparisons {
  const mask = (comparison: MetricPeriodComparisons["monthOverMonth"]) => ({
    ...comparison,
    current: null,
    baseline: null,
    delta: null,
    percentage: null,
  });
  return { monthOverMonth: mask(comparisons.monthOverMonth), yearOverYear: mask(comparisons.yearOverYear) };
}

export function maskSensitivePeriodComparisons(comparisons: LedgerPeriodComparisons | null | undefined): LedgerPeriodComparisons | null {
  if (!comparisons) return null;
  return {
    ...comparisons,
    income: maskMetricPeriodComparisons(comparisons.income),
    totalAssets: comparisons.totalAssets ? maskMetricPeriodComparisons(comparisons.totalAssets) : null,
  };
}

export function maskSensitiveLedgerCache(cache: LedgerCache): LedgerCache {
  return {
    ...cache,
    summary: cache.summary ? {
      ...cache.summary,
      income: 0,
      net: 0,
      days: Object.fromEntries(Object.entries(cache.summary.days).map(([day, values]) => [day, {
        ...values,
        income: 0,
      }])),
    } : null,
    comparisons: maskSensitivePeriodComparisons(cache.comparisons),
    balances: {},
    accountBalances: [],
    netWorthRows: [],
    monthEndNetWorthRows: [],
    netWorthWindows: null,
    creditCards: [],
    investments: null,
    txns: cache.txns.filter((txn) => !isSensitiveIncomeTransaction(txn)),
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

function persistedLedgerCacheNeedsRewrite(cache: LedgerCache) {
  return cache.sensitiveCached !== false
    || (cache.summary?.income ?? 0) !== 0
    || (cache.summary?.net ?? 0) !== 0
    || Object.values(cache.summary?.days ?? {}).some((day) => (day.income ?? 0) !== 0)
    || metricComparisonsContainValues(cache.comparisons?.income)
    || metricComparisonsContainValues(cache.comparisons?.totalAssets)
    || Object.keys(cache.balances).length > 0
    || (cache.accountBalances?.length ?? 0) > 0
    || cache.netWorthRows.length > 0
    || (cache.monthEndNetWorthRows?.length ?? 0) > 0
    || cache.netWorthWindows != null
    || (cache.creditCards?.length ?? 0) > 0
    || cache.investments != null
    || cache.txns.some(isSensitiveIncomeTransaction)
    || (cache.reconciliationRows?.length ?? 0) > 0
    || (cache.accountStatuses?.length ?? 0) > 0
    || (cache.incomeStatement?.income.length ?? 0) > 0
    || (cache.incomeStatement?.totalIncome ?? 0) !== 0
    || (cache.incomeStatement?.netIncome ?? 0) !== 0;
}

function metricComparisonsContainValues(comparisons: MetricPeriodComparisons | null | undefined) {
  if (!comparisons) return false;
  return [comparisons.monthOverMonth, comparisons.yearOverYear].some((comparison) =>
    comparison.current != null || comparison.baseline != null || comparison.delta != null || comparison.percentage != null,
  );
}

function ledgerCacheStorageKey(timeRange: TimeRange, valuationCurrency: string, ledgerScope: string) {
  return apiEndpointStorageKeyForLedgerScope(timeRangeCacheKey(timeRange, valuationCurrency), ledgerScope);
}

function normalizePersistedLedgerCache(timeRange: TimeRange, valuationCurrency: string, ledgerScope: string, cache: LedgerCache, migrate = false, sourceKey?: string) {
  const today = localToday();
  const staleComparisons = cache.comparisons != null
    && comparisonCacheIdentity(timeRange, cache.comparisonDate) !== comparisonCacheIdentity(timeRange, today);
  const current = staleComparisons ? { ...cache, comparisons: null, comparisonDate: today } : cache;
  const masked = maskSensitiveLedgerCache(current);
  const needsRewrite = staleComparisons || persistedLedgerCacheNeedsRewrite(cache);
  if (migrate || needsRewrite) writeLedgerCache(timeRange, masked, valuationCurrency, ledgerScope);
  if (needsRewrite && sourceKey && sourceKey !== ledgerCacheStorageKey(timeRange, valuationCurrency, ledgerScope)) {
    writePersistedLedgerCache(sourceKey, masked);
  }
  return masked;
}

export function readLedgerCache(timeRange: TimeRange, valuationCurrency = "CNY"): LedgerCache | null {
  const legacyKey = timeRangeCacheKey(timeRange, valuationCurrency);
  const ledgerScope = apiEndpointLedgerScope();
  const key = ledgerCacheStorageKey(timeRange, valuationCurrency, ledgerScope);
  const scoped = readLocalLedgerCache(key);
  if (scoped) return normalizePersistedLedgerCache(timeRange, valuationCurrency, ledgerScope, scoped, false, key);
  const previousScope = apiEndpointPreviousLedgerScope();
  const previousKey = previousScope ? apiEndpointStorageKeyForLedgerScope(legacyKey, previousScope) : undefined;
  const previous = previousKey ? readLocalLedgerCache(previousKey) : null;
  if (previous) {
    return normalizePersistedLedgerCache(timeRange, valuationCurrency, ledgerScope, previous, true, previousKey);
  }
  if (!legacyCacheBelongsToScope(ledgerScope)) return null;
  const legacy = readLocalLedgerCache(legacyKey);
  if (legacy) {
    return normalizePersistedLedgerCache(timeRange, valuationCurrency, ledgerScope, legacy, true, legacyKey);
  }
  return null;
}

export async function readLedgerCacheAsync(timeRange: TimeRange, valuationCurrency = "CNY"): Promise<LedgerCache | null> {
  const legacyKey = timeRangeCacheKey(timeRange, valuationCurrency);
  const ledgerScope = apiEndpointLedgerScope();
  const key = ledgerCacheStorageKey(timeRange, valuationCurrency, ledgerScope);
  const scoped = await readIndexedCache<LedgerCache>(key) ?? readLocalLedgerCache(key);
  if (scoped) return normalizePersistedLedgerCache(timeRange, valuationCurrency, ledgerScope, scoped, false, key);
  const previousScope = apiEndpointPreviousLedgerScope();
  if (previousScope) {
    const previousKey = apiEndpointStorageKeyForLedgerScope(legacyKey, previousScope);
    const previous = await readIndexedCache<LedgerCache>(previousKey) ?? readLocalLedgerCache(previousKey);
    if (previous) {
      return normalizePersistedLedgerCache(timeRange, valuationCurrency, ledgerScope, previous, true, previousKey);
    }
  }
  if (!legacyCacheBelongsToScope(ledgerScope)) return null;
  const legacy = await readIndexedCache<LedgerCache>(legacyKey) ?? readLocalLedgerCache(legacyKey);
  return legacy ? normalizePersistedLedgerCache(timeRange, valuationCurrency, ledgerScope, legacy, true, legacyKey) : null;
}

function runWhenIdle(task: () => void) {
  if (typeof window === "undefined") return;
  const idle = window.requestIdleCallback;
  if (idle) {
    idle(task, { timeout: 1500 });
    return;
  }
  window.setTimeout(task, 0);
}

export function writeLedgerCache(timeRange: TimeRange, cache: LedgerCache, valuationCurrency = "CNY", ledgerScope = apiEndpointLedgerScope()) {
  if (typeof window === "undefined") return;
  writePersistedLedgerCache(ledgerCacheStorageKey(timeRange, valuationCurrency, ledgerScope), cache);
}

function writePersistedLedgerCache(key: string, cache: LedgerCache) {
  const masked = maskSensitiveLedgerCache(cache);
  void writeIndexedCache(key, masked);
  runWhenIdle(() => {
    try {
      localStorage.setItem(key, JSON.stringify(masked));
    } catch {
      // Ignore storage quota/private mode failures. Fresh in-memory data is still shown.
    }
  });
}

export function readPrivacySettings(): PrivacySettings {
  if (typeof window === "undefined") return defaultPrivacySettings;
  try {
    const raw = localStorage.getItem(privacySettingsKey);
    return raw ? { ...defaultPrivacySettings, ...JSON.parse(raw) } : defaultPrivacySettings;
  } catch {
    return defaultPrivacySettings;
  }
}

export function writePrivacySettings(settings: PrivacySettings) {
  if (typeof window === "undefined") return;
  try {
    localStorage.setItem(privacySettingsKey, JSON.stringify(settings));
  } catch {
    // Ignore private mode / storage quota errors. The in-memory setting still works.
  }
}

export function readThemeMode(): ThemeMode {
  if (typeof window === "undefined") return "dark";
  try {
    const raw = localStorage.getItem(themeModeKey);
    return raw === "light" || raw === "dark" || raw === "system" ? raw : "dark";
  } catch {
    return "dark";
  }
}

export function writeThemeMode(mode: ThemeMode) {
  if (typeof window === "undefined") return;
  try {
    if (mode === "system") localStorage.removeItem(themeModeKey);
    else localStorage.setItem(themeModeKey, mode);
  } catch {
    // Ignore private mode / storage quota errors. The in-memory setting still works.
  }
}

export function readMobileTabHrefs(): LedgerNavHref[] {
  if (typeof window === "undefined") return defaultMobileTabHrefs;
  try {
    const raw = localStorage.getItem(mobileTabsKey);
    if (!raw) return defaultMobileTabHrefs;
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return defaultMobileTabHrefs;
    const valid = parsed
      .map((href) => href === "/" ? "/home" : href)
      .filter((href): href is LedgerNavHref => allLedgerNavHrefs.includes(href));
    return valid.length ? Array.from(new Set(valid)).slice(0, 5) : defaultMobileTabHrefs;
  } catch {
    return defaultMobileTabHrefs;
  }
}

export function writeMobileTabHrefs(hrefs: LedgerNavHref[]) {
  if (typeof window === "undefined") return;
  try {
    localStorage.setItem(mobileTabsKey, JSON.stringify(Array.from(new Set(hrefs)).slice(0, 5)));
  } catch {
    // Ignore private mode / storage quota errors. The in-memory setting still works.
  }
}
