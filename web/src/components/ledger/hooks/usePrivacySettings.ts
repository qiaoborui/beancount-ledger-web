import { useState } from "react";
import { readPrivacySettings, writePrivacySettings } from "../storage";
import type { PrivacySettings } from "../types";

export function usePrivacySettings() {
  const [privacySettings, setPrivacySettings] = useState<PrivacySettings>(() => readPrivacySettings());
  const [allBalancesVisible, setAllBalancesVisible] = useState(() => readPrivacySettings().showAccountBalancesByDefault);
  const [netWorthVisible, setNetWorthVisible] = useState(() => readPrivacySettings().showNetWorthByDefault);
  const [incomeStatementVisible, setIncomeStatementVisible] = useState(() => readPrivacySettings().showIncomeStatementByDefault);
  const [visibleAccountMap, setVisibleAccountMap] = useState<Record<string, boolean>>({});

  function updatePrivacySetting<K extends keyof PrivacySettings>(key: K, value: PrivacySettings[K]) {
    setPrivacySettings((current) => {
      const next = { ...current, [key]: value };
      writePrivacySettings(next);
      return next;
    });
    if (key === "showAccountBalancesByDefault") {
      setAllBalancesVisible(Boolean(value));
      setVisibleAccountMap({});
    }
    if (key === "showNetWorthByDefault") setNetWorthVisible(Boolean(value));
    if (key === "showIncomeStatementByDefault") setIncomeStatementVisible(Boolean(value));
  }

  return {
    privacySettings,
    updatePrivacySetting,
    allBalancesVisible,
    setAllBalancesVisible,
    netWorthVisible,
    setNetWorthVisible,
    incomeStatementVisible,
    setIncomeStatementVisible,
    visibleAccountMap,
    setVisibleAccountMap,
  };
}
