import { timeRangeToParams, type TimeRange } from "@/lib/timeRange";

export type DashboardFilterState = {
  category: string[];
  account: string[];
  payee: string[];
  tag: string[];
  type: string[];
  minAmount: string;
  maxAmount: string;
};

export const DEFAULT_DASHBOARD_FILTERS: DashboardFilterState = {
  category: [],
  account: [],
  payee: [],
  tag: [],
  type: [],
  minAmount: "",
  maxAmount: "",
};

const ARRAY_FILTER_KEYS = ["type", "category", "account", "payee", "tag"] as const;
const SCALAR_FILTER_KEYS = ["minAmount", "maxAmount"] as const;
const DASHBOARD_FILTER_KEYS = [...ARRAY_FILTER_KEYS, ...SCALAR_FILTER_KEYS] as const;

type ArrayFilterKey = (typeof ARRAY_FILTER_KEYS)[number];
type ScalarFilterKey = (typeof SCALAR_FILTER_KEYS)[number];

export function normalizeDashboardFilters(filters: DashboardFilterState): DashboardFilterState {
  return {
    type: normalizeArray(filters.type),
    category: normalizeArray(filters.category),
    account: normalizeArray(filters.account),
    payee: normalizeArray(filters.payee),
    tag: normalizeArray(filters.tag),
    minAmount: filters.minAmount.trim(),
    maxAmount: filters.maxAmount.trim(),
  };
}

export function parseDashboardFiltersFromSearch(search: string | URLSearchParams): DashboardFilterState {
  const params = typeof search === "string" ? new URLSearchParams(search) : search;
  return normalizeDashboardFilters({
    type: readArrayFilter(params, "type"),
    category: readArrayFilter(params, "category"),
    account: readArrayFilter(params, "account"),
    payee: readArrayFilter(params, "payee"),
    tag: readArrayFilter(params, "tag"),
    minAmount: params.get("minAmount") ?? "",
    maxAmount: params.get("maxAmount") ?? "",
  });
}

export function dashboardFiltersToSearchParams(filters: DashboardFilterState, base?: URLSearchParams) {
  const params = new URLSearchParams(base?.toString() ?? "");
  const normalized = normalizeDashboardFilters(filters);
  for (const key of DASHBOARD_FILTER_KEYS) params.delete(key);
  for (const key of ARRAY_FILTER_KEYS) {
    const value = normalized[key].join(",");
    if (value) params.set(key, value);
  }
  for (const key of SCALAR_FILTER_KEYS) {
    const value = normalized[key];
    if (value) params.set(key, value);
  }
  return params;
}

export function dashboardFiltersToApiQuery(timeRange: TimeRange, filters: DashboardFilterState, valuationCurrency = "CNY") {
  const params = dashboardFiltersToSearchParams(filters, new URLSearchParams(timeRangeToParams(timeRange)));
  params.set("valuationCurrency", valuationCurrency);
  return params.toString();
}

export function hasActiveDashboardFilters(filters: DashboardFilterState) {
  return DASHBOARD_FILTER_KEYS.some((key) => Array.isArray(filters[key]) ? filters[key].length > 0 : filters[key].trim() !== "");
}

function readArrayFilter(params: URLSearchParams, key: ArrayFilterKey) {
  return params.getAll(key).flatMap((value) => value.split(","));
}

function normalizeArray(values: string[]) {
  return Array.from(new Set(values.map((value) => value.trim()).filter(Boolean))).sort();
}

export type DashboardFilterKey = ArrayFilterKey | ScalarFilterKey;
