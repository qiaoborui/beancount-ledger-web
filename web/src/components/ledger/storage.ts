import type { LedgerCache, PrivacySettings } from "./types";
import type { TimeRange } from "@/lib/timeRange";
import { timeRangeCacheKey } from "@/lib/timeRange";

export const defaultPrivacySettings: PrivacySettings = {
  showHomeSummaryAmounts: false,
  showHomeCashflowChart: false,
  showAccountBalancesByDefault: false,
  showNetWorthByDefault: false,
  showIncomeStatementByDefault: false,
};

const privacySettingsKey = "ledger_privacy_settings";

export function readLedgerCache(timeRange: TimeRange): LedgerCache | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = localStorage.getItem(timeRangeCacheKey(timeRange));
    return raw ? JSON.parse(raw) as LedgerCache : null;
  } catch {
    return null;
  }
}

export function writeLedgerCache(timeRange: TimeRange, cache: LedgerCache) {
  if (typeof window === "undefined") return;
  try {
    localStorage.setItem(timeRangeCacheKey(timeRange), JSON.stringify(cache));
  } catch {
    // Ignore storage quota/private mode failures. Fresh in-memory data is still shown.
  }
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
