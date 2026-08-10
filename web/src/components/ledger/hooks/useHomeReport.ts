import { useCallback, useEffect, useState } from "react";
import { apiEndpointLedgerScope, apiFetch } from "@/lib/apiEndpoints";
import { readJson } from "@/lib/clientFetch";
import { timeRangeToParams, type TimeRange } from "@/lib/timeRange";
import type { HomeReport } from "../types";
import i18n from "@/i18n";

const reportCache = new Map<string, HomeReport>();
const reportInFlight = new Map<string, Promise<HomeReport>>();

export function useHomeReport({ timeRange, valuationCurrency, ledgerRevision, enabled, onSensitiveLocked }: { timeRange: TimeRange; valuationCurrency: string; ledgerRevision: string; enabled: boolean; onSensitiveLocked: () => void }) {
  const params = `${timeRangeToParams(timeRange)}&valuationCurrency=${encodeURIComponent(valuationCurrency)}`;
  const cacheKey = `${apiEndpointLedgerScope()}:${ledgerRevision}:${params}`;
  const [data, setData] = useState<HomeReport | null>(() => enabled ? reportCache.get(cacheKey) ?? null : null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [reloadToken, setReloadToken] = useState(0);
  const reload = useCallback(() => setReloadToken((value) => value + 1), []);

  useEffect(() => {
    if (!enabled) {
      setData(null);
      setLoading(false);
      setError("");
      return;
    }
    let active = true;
    async function load() {
      const cached = reloadToken === 0 ? reportCache.get(cacheKey) : null;
      if (cached) setData(cached);
      setLoading(!cached);
      setError("");
      try {
        const next = await fetchHomeReport(params, cacheKey);
        if (!active) return;
        reportCache.set(cacheKey, next);
        setData(next);
      } catch (loadError) {
        if (!active) return;
        if (loadError instanceof HomeReportLockedError) {
          setData(null);
          onSensitiveLocked();
          return;
        }
        setError(loadError instanceof Error ? loadError.message : i18n.t("homeReport.loadFailed"));
      } finally {
        if (active) setLoading(false);
      }
    }
    void load();
    return () => {
      active = false;
    };
  }, [cacheKey, enabled, onSensitiveLocked, params, reloadToken]);

  return { data, loading, error, reload };
}

class HomeReportLockedError extends Error {}

async function fetchHomeReport(params: string, cacheKey: string) {
  const existing = reportInFlight.get(cacheKey);
  if (existing) return existing;

  const request = (async () => {
    const response = await apiFetch(`/api/ledger/home-report?${params}`, undefined, { kind: "read" });
    if (response.status === 423 || response.status === 401) throw new HomeReportLockedError(i18n.t("homeReport.locked"));
    const data = await readJson<HomeReport & { error?: string }>(response);
    if (!response.ok) throw new Error(data.error || i18n.t("homeReport.requestFailed", { status: response.status }));
    return data;
  })();

  reportInFlight.set(cacheKey, request);
  try {
    return await request;
  } finally {
    reportInFlight.delete(cacheKey);
  }
}
