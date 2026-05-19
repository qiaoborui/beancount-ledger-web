import type { LedgerCache, LedgerNavHref, PrivacySettings, ThemeMode } from "./types";
import type { TimeRange } from "@/lib/timeRange";
import { timeRangeCacheKey } from "@/lib/timeRange";

export const defaultPrivacySettings: PrivacySettings = {
  showHomeSummaryAmounts: true,
  showAccountBalancesByDefault: false,
  showNetWorthByDefault: false,
  showIncomeStatementByDefault: false,
};

export const defaultMobileTabHrefs: LedgerNavHref[] = ["/", "/transactions", "/accounts"];

const allLedgerNavHrefs: LedgerNavHref[] = ["/", "/transactions", "/accounts", "/budgets", "/imports", "/net-worth", "/income-statement", "/reconcile", "/settings"];
const privacySettingsKey = "ledger_privacy_settings";
const themeModeKey = "ledger_theme_mode";
const mobileTabsKey = "ledger_mobile_tabs";

export function readLedgerCache(timeRange: TimeRange): LedgerCache | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = localStorage.getItem(timeRangeCacheKey(timeRange));
    return raw ? JSON.parse(raw) as LedgerCache : null;
  } catch {
    return null;
  }
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

export function writeLedgerCache(timeRange: TimeRange, cache: LedgerCache) {
  if (typeof window === "undefined") return;
  const key = timeRangeCacheKey(timeRange);
  runWhenIdle(() => {
    try {
      localStorage.setItem(key, JSON.stringify(cache));
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
  if (typeof window === "undefined") return "system";
  try {
    const raw = localStorage.getItem(themeModeKey);
    return raw === "light" || raw === "dark" || raw === "system" ? raw : "system";
  } catch {
    return "system";
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
    const valid = parsed.filter((href): href is LedgerNavHref => allLedgerNavHrefs.includes(href));
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
