import type { LedgerCache, PrivacySettings, ThemeMode } from "./types";
import type { TimeRange } from "@/lib/timeRange";
import { timeRangeCacheKey } from "@/lib/timeRange";

export const defaultPrivacySettings: PrivacySettings = {
  showHomeSummaryAmounts: true,
  showHomeCashflowChart: false,
  showAccountBalancesByDefault: false,
  showNetWorthByDefault: false,
  showIncomeStatementByDefault: false,
};

const privacySettingsKey = "ledger_privacy_settings";
const themeModeKey = "ledger_theme_mode";

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
