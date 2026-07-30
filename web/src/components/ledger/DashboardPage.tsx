import { useCallback, useEffect, useMemo, useState, type CSSProperties, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { AlertTriangle, ChevronDown, ChevronRight, Eye, EyeOff, Maximize2, RefreshCw, SlidersHorizontal, X } from "lucide-react";
import { Bar, BarChart, CartesianGrid, ComposedChart, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { useBrowserLocation, useBrowserRouter } from "@/lib/browserRouter";
import { readJson } from "@/lib/clientFetch";
import { formatCompactValuation, formatValuation } from "@/lib/money";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import type { TimeRange } from "@/lib/timeRange";
import { formatAccountOptionLabel, isLedgerAccount } from "./accountDisplay";
import { DEFAULT_DASHBOARD_FILTERS, dashboardFiltersToApiQuery, dashboardFiltersToSearchParams, hasActiveDashboardFilters, normalizeDashboardFilters, parseDashboardFiltersFromSearch, type DashboardFilterKey, type DashboardFilterState } from "./dashboardFilters";
import type { DashboardFilterOption, DashboardSummary } from "./types";
import { apiEndpointLedgerScope, apiFetch } from "@/lib/apiEndpoints";
import { ResponsiveValueRow } from "./shared";

const COLORS = [
  "var(--chart-primary)",
  "var(--ink)",
  "var(--stone)",
  "oklch(var(--color-brand) / .62)",
  "oklch(var(--color-brand) / .38)",
];

const dashboardSummaryCache = new Map<string, DashboardSummary>();
const dashboardSummaryInFlight = new Map<string, Promise<DashboardSummary>>();

type DashboardPanelId =
  | "dailyExpense"
  | "weekdayExpense"
  | "categoryRank"
  | "payeeRank"
  | "paymentAccounts"
  | "anomalies"
  | "categoryTrend";

export function DashboardPage({ timeRange, valuationCurrency, visible, onToggleVisible, onSensitiveLocked, onOpenTransactions }: { timeRange: TimeRange; valuationCurrency: string; visible: boolean; onToggleVisible: () => void; onSensitiveLocked: () => void; onOpenTransactions: (href: string) => void }) {
  const router = useBrowserRouter();
  const { pathname, search } = useBrowserLocation();
  const filters = useMemo(() => ({ ...parseDashboardFiltersFromSearch(search), type: [] }), [search]);
  const searchKey = useMemo(() => new URLSearchParams(search).toString(), [search]);
  const canonicalSearch = useMemo(() => dashboardFiltersToSearchParams(filters, new URLSearchParams(search)).toString(), [filters, search]);
  const { data, loading, error, reload } = useDashboardSummary(timeRange, filters, valuationCurrency, onSensitiveLocked);
  const { collapsedRows, toggleRow } = useDashboardRowCollapse();
  const [viewPanelId, setViewPanelId] = useState<DashboardPanelId | null>(null);
  const mask = (value: string) => visible ? value : "••••••";
  const replaceFilters = useCallback((nextFilters: DashboardFilterState) => {
    const query = dashboardFiltersToSearchParams(nextFilters, new URLSearchParams(search)).toString();
    if (query === searchKey) return;
    router.replace(query ? `${pathname}?${query}` : pathname, { scroll: false });
  }, [pathname, router, search, searchKey]);
  const setFilter = useCallback((key: DashboardFilterKey, value: string | string[]) => {
    replaceFilters(normalizeDashboardFilters({ ...filters, [key]: value }));
  }, [filters, replaceFilters]);
  const clearFilter = useCallback((key: DashboardFilterKey) => {
    replaceFilters(normalizeDashboardFilters({ ...filters, [key]: Array.isArray(filters[key]) ? [] : "" }));
  }, [filters, replaceFilters]);
  const clearFilters = useCallback(() => replaceFilters(DEFAULT_DASHBOARD_FILTERS), [replaceFilters]);
  const activeFilters = hasActiveDashboardFilters(filters);
  const dashboardEmpty = data ? isDashboardEmpty(data) : false;

  useEffect(() => {
    if (canonicalSearch === searchKey) return;
    router.replace(canonicalSearch ? `${pathname}?${canonicalSearch}` : pathname, { scroll: false });
  }, [canonicalSearch, pathname, router, searchKey]);

  useEffect(() => {
    if (!viewPanelId) return;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setViewPanelId(null);
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [viewPanelId]);

  if (loading && !data) return <DashboardStatusCard title="正在加载收支分析" detail="正在读取当前时间范围、筛选条件和支出维度。" icon={<RefreshCw className="h-4 w-4 animate-spin text-brand" />} />;
  if (error && !data) return <DashboardStatusCard title="收支分析加载失败" detail={error} icon={<AlertTriangle className="h-4 w-4 amount-danger" />} actionLabel="重试" onAction={reload} />;
  if (!data) return <DashboardStatusCard title="暂无分析数据" detail="服务端暂时没有返回可展示的交易汇总。" actionLabel="重新加载" onAction={reload} />;

  const compact = (value: number) => formatCompactValuation(value, data.currency);
  const maxExpense = data.anomalies[0]?.amount ?? 0;
  const topCategory = data.categorySeries[0];
  const topCategoryText = topCategory ? `${topCategory.label} · ${mask(compact(topCategory.total / 100))}` : "暂无";
  const activeExpenseDays = data.dailyExpenseSeries.length;
  const averageExpense = activeExpenseDays ? data.kpis.expense / activeExpenseDays : 0;
  const panels: Record<DashboardPanelId, DashboardPanelDefinition> = {
    dailyExpense: {
      title: "每日支出节奏",
      subtitle: `${data.dailyExpenseSeries.length} 个支出日`,
      render: () => visible ? <DailyExpenseChart data={data} onOpenTransactions={onOpenTransactions} /> : <HiddenChart />,
    },
    weekdayExpense: {
      title: "星期分布",
      subtitle: "消费节律",
      render: () => visible ? <WeekdayExpenseChart data={data} /> : <HiddenChart />,
    },
    categoryRank: {
      title: "分类排行",
      subtitle: `${data.categorySeries.length} 个分类`,
      render: () => <CategoryRank rows={data.categorySeries} currency={data.currency} visible={visible} onOpenTransactions={onOpenTransactions} />,
    },
    payeeRank: {
      title: "商户排行",
      subtitle: `${data.topPayees.length} 个商户`,
      render: () => <PayeeList data={data} visible={visible} onOpenTransactions={onOpenTransactions} />,
    },
    paymentAccounts: {
      title: "消费来源",
      subtitle: `${data.topPaymentAccounts.length} 个账户`,
      render: () => <PaymentAccounts data={data} visible={visible} onOpenTransactions={onOpenTransactions} />,
    },
    anomalies: {
      title: "高额支出",
      subtitle: `${data.anomalies.length} 笔`,
      render: () => <AnomalyList rows={data.anomalies} currency={data.currency} visible={visible} onSelectCategory={(account) => onOpenTransactions(transactionHref({ category: account }))} />,
    },
    categoryTrend: {
      title: "分类趋势",
      subtitle: `${data.categorySeries.length} 个 Top 分类`,
      render: () => visible ? <CategoryTrendChart data={data} /> : <HiddenChart />,
    },
  };
  const viewPanel = viewPanelId ? panels[viewPanelId] : null;

  return <div className="dashboard-workbench">
    <DashboardFilterBar data={data} filters={filters} onChange={setFilter} onClear={clearFilter} onClearAll={clearFilters} />
    {loading && <DashboardNotice tone="loading" title="正在刷新分析" detail="当前图表先保留，上方筛选或时间范围的数据回来后会自动更新。" />}
    {error && <DashboardNotice tone="error" title="后台刷新失败" detail={error} actionLabel="重试" onAction={reload} />}
    {dashboardEmpty ? <DashboardEmptyState filtered={activeFilters} onClearFilters={clearFilters} onRetry={reload} /> : <>

    <DashboardInlineRow rowId="monitor" title="分析范围" subtitle="所有指标都只针对当前时间和筛选条件" collapsed={collapsedRows.monitor} onToggle={toggleRow} summary={<RowSummary>{mask(compact(data.kpis.expense / 100))} 支出 · {activeExpenseDays} 个活跃日</RowSummary>}>
      <div className="flex flex-col gap-2 lg:flex-row lg:items-center lg:justify-between">
        <div className="grid flex-1 grid-cols-2 divide-x divide-y divide-line overflow-hidden border-y border-line sm:grid-cols-3 xl:grid-cols-5 xl:divide-y-0">
          <Kpi label="筛选后支出" value={mask(compact(data.kpis.expense / 100))} tone="text-warm" />
          <Kpi label="活跃日均" value={mask(compact(averageExpense / 100))} tone="text-warm" />
          <Kpi label="支出活跃日" value={`${activeExpenseDays} 天`} tone="text-warm" />
          <Kpi label="最大单笔" value={mask(compact(maxExpense / 100))} tone="text-warm" />
          <Kpi label="高额支出" value={`${data.anomalies.length} 笔`} tone={data.anomalies.length ? "amount-danger" : "text-warm"} />
        </div>
        <button className="h-10 shrink-0 self-end rounded-md border border-line bg-panel px-2.5 text-sm text-olive hover:bg-tag md:h-8 lg:self-auto" onClick={onToggleVisible} aria-label={visible ? "隐藏分析金额" : "显示分析金额"} title={visible ? "隐藏分析金额" : "显示分析金额"}>
          {visible ? <EyeOff className="inline h-4 w-4 text-brand" /> : <Eye className="inline h-4 w-4 text-brand" />} <span className="ml-1">{visible ? "隐藏金额" : "显示金额"}</span>
        </button>
      </div>
    </DashboardInlineRow>

    <DashboardRow rowId="spending" title="消费节奏" subtitle="只解释支出在什么时候发生，不重复首页的周期结论" collapsed={collapsedRows.spending} onToggle={toggleRow} summary={<RowSummary>{data.dailyExpenseSeries.length} 个支出日 · {data.weekdayExpense.length} 个星期桶</RowSummary>}>
    <div className="dashboard-panel-grid">
      <Panel panelId="dailyExpense" className="xl:col-span-7" onView={setViewPanelId} title={panels.dailyExpense.title} subtitle={panels.dailyExpense.subtitle}>
        {panels.dailyExpense.render()}
      </Panel>
      <Panel panelId="weekdayExpense" className="dashboard-panel-end xl:col-span-5" onView={setViewPanelId} title={panels.weekdayExpense.title} subtitle={panels.weekdayExpense.subtitle}>
        {panels.weekdayExpense.render()}
      </Panel>
    </div>
    </DashboardRow>

    <DashboardRow rowId="risk" title="归因与核查" subtitle="把支出拆到分类、商户、付款账户和异常流水" collapsed={collapsedRows.risk} onToggle={toggleRow} summary={<RowSummary>{topCategoryText} · {data.anomalies.length} 笔高额</RowSummary>}>
    <div className="dashboard-panel-grid">
      <Panel panelId="categoryTrend" className="dashboard-panel-end xl:col-span-12" onView={setViewPanelId} title={panels.categoryTrend.title} subtitle={panels.categoryTrend.subtitle}>
        {panels.categoryTrend.render()}
      </Panel>
      <Panel panelId="anomalies" className="xl:col-span-6" onView={setViewPanelId} title={panels.anomalies.title} subtitle={panels.anomalies.subtitle}>
        {panels.anomalies.render()}
      </Panel>
      <Panel panelId="categoryRank" className="dashboard-panel-end xl:col-span-6" onView={setViewPanelId} title={panels.categoryRank.title} subtitle={panels.categoryRank.subtitle}>
        {panels.categoryRank.render()}
      </Panel>
      <Panel panelId="payeeRank" className="xl:col-span-6" onView={setViewPanelId} title={panels.payeeRank.title} subtitle={panels.payeeRank.subtitle}>
        {panels.payeeRank.render()}
      </Panel>
      <Panel panelId="paymentAccounts" className="dashboard-panel-end xl:col-span-6" onView={setViewPanelId} title={panels.paymentAccounts.title} subtitle={panels.paymentAccounts.subtitle}>
        {panels.paymentAccounts.render()}
      </Panel>
    </div>
    </DashboardRow>
    </>}
    {viewPanel && <DashboardPanelView panel={viewPanel} onClose={() => setViewPanelId(null)} />}
  </div>;
}

type DashboardPanelDefinition = {
  title: string;
  subtitle?: string;
  render: () => ReactNode;
};

const DEFAULT_COLLAPSED_ROWS: Record<DashboardRowId, boolean> = {
  monitor: false,
  spending: false,
  risk: false,
};

type DashboardRowId = "monitor" | "spending" | "risk";

function useDashboardRowCollapse() {
  const [collapsedRows, setCollapsedRows] = useState(DEFAULT_COLLAPSED_ROWS);

  useEffect(() => {
    try {
      const raw = window.localStorage.getItem("ledger.dashboard.collapsedRows");
      if (!raw) return;
      const saved = JSON.parse(raw) as Partial<Record<DashboardRowId, boolean>>;
      setCollapsedRows((current) => ({ ...current, ...saved }));
    } catch {
      setCollapsedRows(DEFAULT_COLLAPSED_ROWS);
    }
  }, []);

  function toggleRow(rowId: DashboardRowId) {
    setCollapsedRows((current) => {
      const next = { ...current, [rowId]: !current[rowId] };
      try {
        window.localStorage.setItem("ledger.dashboard.collapsedRows", JSON.stringify(next));
      } catch {
        // Ignore storage failures; the row still toggles for this session.
      }
      return next;
    });
  }

  return { collapsedRows, toggleRow };
}

function useDashboardSummary(timeRange: TimeRange, filters: DashboardFilterState, valuationCurrency: string, onSensitiveLocked: () => void) {
  const params = dashboardFiltersToApiQuery(timeRange, filters, valuationCurrency);
  const cacheKey = `${apiEndpointLedgerScope()}:${params}`;
  const [data, setData] = useState<DashboardSummary | null>(() => dashboardSummaryCache.get(cacheKey) ?? null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [reloadToken, setReloadToken] = useState(0);
  const reload = useCallback(() => setReloadToken((value) => value + 1), []);

  useEffect(() => {
    let active = true;
    async function load() {
      const cached = reloadToken === 0 ? dashboardSummaryCache.get(cacheKey) : null;
      if (cached) setData(cached);
      setLoading(!cached);
      setError("");
      try {
        const next = await fetchDashboardSummary(params, cacheKey);
        if (!active) return;
        dashboardSummaryCache.set(cacheKey, next);
        setData(next);
      } catch (err) {
        if (!active) return;
        if (err instanceof DashboardLockedError) {
          onSensitiveLocked();
          setData(null);
          return;
        }
        setError(err instanceof Error ? err.message : "收支分析加载失败");
      } finally {
        if (active) setLoading(false);
      }
    }
    void load();
    return () => {
      active = false;
    };
  }, [cacheKey, onSensitiveLocked, params, reloadToken]);

  return { data, loading, error, reload };
}

class DashboardLockedError extends Error {}

async function fetchDashboardSummary(params: string, cacheKey: string) {
  const existing = dashboardSummaryInFlight.get(cacheKey);
  if (existing) return existing;

  const request = (async () => {
    const response = await apiFetch(`/api/ledger/dashboard?${params}`, undefined, { kind: "read" });
    if (response.status === 423 || response.status === 401) {
      throw new DashboardLockedError("Dashboard locked");
    }
    const next = await readJson<DashboardSummary & { error?: string }>(response);
    if (!response.ok) throw new Error(next.error || `请求失败：${response.status}`);
    return next;
  })();

  dashboardSummaryInFlight.set(cacheKey, request);
  try {
    return await request;
  } finally {
    dashboardSummaryInFlight.delete(cacheKey);
  }
}

function DashboardStatusCard({ title, detail, icon, actionLabel, onAction }: { title: string; detail: string; icon?: ReactNode; actionLabel?: string; onAction?: () => void }) {
  return <section className="border-b border-line bg-panel p-4">
    <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex min-w-0 items-start gap-3">
        {icon && <span className="mt-0.5 grid h-8 w-8 shrink-0 place-items-center rounded-md border border-line bg-panel">{icon}</span>}
        <div className="min-w-0">
          <h2 className="text-lg font-semibold tracking-[-0.018em] text-warm">{title}</h2>
          <p className="mt-1 text-sm text-stone">{detail}</p>
        </div>
      </div>
      {actionLabel && onAction && <button type="button" className="inline-flex h-9 shrink-0 items-center justify-center gap-1.5 rounded-md border border-line bg-panel px-3 text-sm text-olive hover:bg-tag" onClick={onAction}>
        <RefreshCw className="h-4 w-4 text-brand" />
        {actionLabel}
      </button>}
    </div>
  </section>;
}

function DashboardNotice({ tone, title, detail, actionLabel, onAction }: { tone: "loading" | "error"; title: string; detail: string; actionLabel?: string; onAction?: () => void }) {
  return <section className={`border-b border-line px-3 py-2 ${tone === "error" ? "bg-panel" : "bg-panel/80"}`}>
    <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex min-w-0 items-center gap-2 text-sm">
        {tone === "loading" ? <RefreshCw className="h-4 w-4 shrink-0 animate-spin text-brand" /> : <AlertTriangle className="h-4 w-4 shrink-0 amount-danger" />}
        <span className="font-medium text-olive">{title}</span>
        <span className="min-w-0 text-stone">{detail}</span>
      </div>
      {actionLabel && onAction && <button type="button" className="inline-flex h-8 shrink-0 items-center justify-center gap-1.5 rounded-md border border-line bg-panel px-2.5 text-xs text-olive hover:bg-tag" onClick={onAction}>
        <RefreshCw className="h-3.5 w-3.5 text-brand" />
        {actionLabel}
      </button>}
    </div>
  </section>;
}

function DashboardEmptyState({ filtered, onClearFilters, onRetry }: { filtered: boolean; onClearFilters: () => void; onRetry: () => void }) {
  return <section className="border-b border-line bg-panel p-5">
    <div className="mx-auto max-w-xl text-center">
      <h2 className="text-xl font-semibold tracking-[-0.018em] text-warm">{filtered ? "没有匹配当前筛选的交易" : "当前时间范围暂无分析数据"}</h2>
      <p className="mt-2 text-sm text-stone">
        {filtered ? "可以放宽分类、账户、商户、标签或金额条件，再查看趋势和排行。" : "这个时间范围还没有可汇总的收入、支出或资产记录。"}
      </p>
      <div className="mt-4 flex flex-wrap justify-center gap-2">
        {filtered && <button type="button" className="inline-flex h-9 items-center justify-center rounded-lg border border-line bg-panel px-3 text-sm text-olive hover:bg-tag" onClick={onClearFilters}>清空筛选</button>}
        <button type="button" className="inline-flex h-9 items-center justify-center gap-1.5 rounded-lg border border-line bg-panel px-3 text-sm text-olive hover:bg-tag" onClick={onRetry}>
          <RefreshCw className="h-4 w-4 text-brand" />
          重试加载
        </button>
      </div>
    </div>
  </section>;
}

function isDashboardEmpty(data: DashboardSummary) {
  return data.kpis.expense === 0
    && data.dailyExpenseSeries.length === 0
    && data.categorySeries.length === 0
    && data.anomalies.length === 0
    && data.topPayees.length === 0
    && data.topPaymentAccounts.length === 0
    && data.annotations.length === 0;
}

function DashboardFilterBar({ data, filters, onChange, onClear, onClearAll }: { data: DashboardSummary; filters: DashboardFilterState; onChange: (key: DashboardFilterKey, value: string | string[]) => void; onClear: (key: DashboardFilterKey) => void; onClearAll: () => void }) {
  const [expanded, setExpanded] = useState(false);
  const chips = activeFilterChips(data, filters);
  const advancedChips = chips.filter((chip) => chip.key !== "query");
  const clearAdvancedFilters = () => advancedChips.forEach((chip) => onClear(chip.key));
  const Icon = expanded ? ChevronDown : ChevronRight;
  return <section className="border-b border-line bg-panel px-3 py-3 transition-colors md:px-4">
    <div className="flex flex-col gap-2 lg:flex-row lg:items-end lg:justify-between">
      <label className="min-w-0 flex-1">
        <span className="mb-1 block text-[11px] text-stone">查询</span>
        <Input className="h-10 w-full min-w-0 rounded-md bg-panel text-sm text-olive md:h-9" placeholder="payee:星巴克 AND amount>30" value={filters.query} onChange={(event) => onChange("query", event.target.value)} />
      </label>
      <button type="button" className="flex h-9 shrink-0 items-center justify-center gap-2 rounded-md border border-line bg-panel px-3 text-left text-sm font-medium text-warm hover:bg-tag hover:text-brand" onClick={() => setExpanded((value) => !value)} aria-expanded={expanded}>
        <span className="grid h-7 w-7 shrink-0 place-items-center rounded-md border border-line bg-panel">
          <SlidersHorizontal className="h-4 w-4 text-brand" />
        </span>
        <span className="min-w-0 truncate">高级筛选</span>
        <span className="shrink-0 rounded-full bg-tag px-2 py-0.5 text-xs font-normal text-stone">{advancedChips.length ? `${advancedChips.length} 个条件` : "未启用"}</span>
        <Icon className="h-4 w-4 shrink-0 text-stone" />
      </button>
    </div>
    {!expanded && advancedChips.length > 0 && <div className="mt-3 flex min-w-0 flex-wrap items-center gap-2">
      {advancedChips.slice(0, 4).map((chip) => <FilterChip key={chip.key} chip={chip} onClear={onClear} />)}
      {advancedChips.length > 4 && <span className="rounded-full bg-tag px-2.5 py-1 text-xs text-stone">+{advancedChips.length - 4}</span>}
      <button type="button" className="rounded-full border border-line px-2.5 py-1 text-xs text-stone hover:bg-tag" onClick={clearAdvancedFilters}>清空高级</button>
    </div>}
    {expanded && <>
      <div className="mt-3 grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
        <MultiFilterSelect label="分类" value={filters.category} onChange={(value) => onChange("category", value)} options={data.filterOptions.categories} />
        <MultiFilterSelect label="账户" value={filters.account} onChange={(value) => onChange("account", value)} options={data.filterOptions.accounts} />
        <MultiFilterSelect label="商户" value={filters.payee} onChange={(value) => onChange("payee", value)} options={data.filterOptions.payees} />
        <MultiFilterSelect label="标签" value={filters.tag} onChange={(value) => onChange("tag", value)} options={data.filterOptions.tags} />
        <MoneyFilterInput label="最小金额" value={filters.minAmount} onChange={(value) => onChange("minAmount", value)} />
        <MoneyFilterInput label="最大金额" value={filters.maxAmount} onChange={(value) => onChange("maxAmount", value)} />
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        {chips.length ? chips.map((chip) => <FilterChip key={chip.key} chip={chip} onClear={onClear} />) : <span className="text-xs text-stone">未添加变量筛选</span>}
        {chips.length > 0 && <button type="button" className="rounded-full border border-line px-2.5 py-1 text-xs text-stone hover:bg-tag" onClick={onClearAll}>清空</button>}
      </div>
    </>}
  </section>;
}

function FilterChip({ chip, onClear }: { chip: { key: DashboardFilterKey; label: string }; onClear: (key: DashboardFilterKey) => void }) {
  return <button type="button" className="inline-flex max-w-full items-center gap-1 rounded-full border border-line bg-tag px-2.5 py-1 text-xs text-olive hover:bg-panel" onClick={() => onClear(chip.key)} title="移除此筛选">
    <span className="truncate">{chip.label}</span>
    <X className="h-3 w-3 shrink-0" />
  </button>;
}

function MultiFilterSelect({ label, value, options, onChange }: { label: string; value: string[]; options: DashboardFilterOption[]; onChange: (value: string[]) => void }) {
  const selected = new Set(value);
  const toggle = (option: string) => onChange(selected.has(option) ? value.filter((item) => item !== option) : [...value, option]);
  return <div className="min-w-0">
    <span className="mb-1 block text-[11px] text-stone">{label}</span>
    <details className="group relative">
      <summary className="flex min-h-10 cursor-pointer list-none items-center justify-between gap-2 rounded-md border border-line bg-panel px-2 py-2 text-sm text-olive outline-none group-open:border-brand md:min-h-8 md:py-1.5">
        <span className="min-w-0 truncate">{value.length ? `${value.length} 项` : "全部"}</span>
        <ChevronDown className="h-3.5 w-3.5 shrink-0 text-stone" />
      </summary>
      <div className="absolute inset-x-0 z-30 mt-1 max-h-72 overflow-auto rounded-md border border-line bg-paper p-2 shadow-lg">
        {options.length ? options.map((option, index) => {
          const optionId = `dashboard-filter-${Array.from(label).map((char) => char.charCodeAt(0).toString(36)).join("-")}-${index}`;
          return <div key={option.value} className="flex items-center gap-2 rounded-lg px-2 py-1.5 text-sm hover:bg-tag">
          <Checkbox id={optionId} checked={selected.has(option.value)} onCheckedChange={() => toggle(option.value)} />
          <label htmlFor={optionId} className="min-w-0 flex-1 cursor-pointer truncate text-olive" title={filterOptionLabel(option)}>{filterOptionLabel(option)}</label>
          {option.count > 0 && <span className="shrink-0 text-xs text-stone">{option.count}</span>}
        </div>;
        }) : <div className="px-2 py-3 text-sm text-stone">暂无可选项</div>}
      </div>
    </details>
  </div>;
}

function MoneyFilterInput({ label, value, onChange }: { label: string; value: string; onChange: (value: string) => void }) {
  return <label className="min-w-0">
    <span className="mb-1 block text-[11px] text-stone">{label}</span>
    <Input className="h-10 w-full min-w-0 rounded-md bg-panel text-sm text-olive md:h-8" inputMode="decimal" placeholder="全部" value={value} onChange={(event) => onChange(event.target.value)} />
  </label>;
}

function activeFilterChips(data: DashboardSummary, filters: DashboardFilterState) {
  const chips: { key: DashboardFilterKey; label: string }[] = [];
  const add = (key: DashboardFilterKey, label: string, value: string) => {
    if (value.trim()) chips.push({ key, label: `${label}: ${value}` });
  };
  if (filters.category.length) chips.push({ key: "category", label: `分类: ${filters.category.map((value) => optionLabel(data.filterOptions.categories, value)).join(" / ")}` });
  add("query", "查询", filters.query);
  if (filters.account.length) chips.push({ key: "account", label: `账户: ${filters.account.map((value) => optionLabel(data.filterOptions.accounts, value)).join(" / ")}` });
  if (filters.payee.length) chips.push({ key: "payee", label: `商户: ${filters.payee.join(" / ")}` });
  if (filters.tag.length) chips.push({ key: "tag", label: `标签: ${filters.tag.join(" / ")}` });
  add("minAmount", "最小", filters.minAmount);
  add("maxAmount", "最大", filters.maxAmount);
  return chips;
}

function optionLabel(options: DashboardFilterOption[], value: string) {
  const option = options.find((item) => item.value === value);
  return option ? filterOptionLabel(option) : value;
}

function filterOptionLabel(option: DashboardFilterOption) {
  return isLedgerAccount(option.value) ? formatAccountOptionLabel(option.value, option.label, option.alias) : option.label;
}

function DashboardRow({ rowId, title, subtitle, collapsed, onToggle, summary, children }: { rowId: DashboardRowId; title: string; subtitle?: string; collapsed: boolean; onToggle: (rowId: DashboardRowId) => void; summary: ReactNode; children: ReactNode }) {
  const Icon = collapsed ? ChevronRight : ChevronDown;
  return <section className="border-b border-line">
    <button type="button" className={`group flex w-full flex-col gap-2 border-b border-line px-3 py-2.5 text-left transition-colors hover:bg-tag sm:flex-row sm:items-center sm:justify-between md:px-4 ${collapsed ? "bg-tag" : "bg-panel"}`} onClick={() => onToggle(rowId)} aria-expanded={!collapsed}>
      <span className="flex min-w-0 items-center gap-2.5">
        <span className="grid h-5 w-5 shrink-0 place-items-center rounded-md border border-line bg-panel text-olive group-hover:text-brand">
          <Icon className="h-3.5 w-3.5" />
        </span>
        <span className="min-w-0">
          <span className="block text-sm font-semibold leading-tight text-ink">{title}</span>
          {subtitle && <span className="mt-0.5 block truncate text-xs text-stone">{subtitle}</span>}
        </span>
      </span>
      {summary}
    </button>
    {!collapsed && children}
  </section>;
}

function DashboardInlineRow({ rowId, title, subtitle, collapsed, onToggle, summary, children }: { rowId: DashboardRowId; title: string; subtitle?: string; collapsed: boolean; onToggle: (rowId: DashboardRowId) => void; summary: ReactNode; children: ReactNode }) {
  const Icon = collapsed ? ChevronRight : ChevronDown;
  return <section className="overflow-hidden border-b border-line bg-panel p-0">
    <button type="button" className="group flex w-full flex-col gap-2 border-b border-line px-3 py-2.5 text-left transition-colors hover:bg-tag sm:flex-row sm:items-center sm:justify-between md:px-4" onClick={() => onToggle(rowId)} aria-expanded={!collapsed}>
      <span className="flex min-w-0 items-center gap-2.5">
        <span className="grid h-5 w-5 shrink-0 place-items-center rounded-md border border-line bg-panel text-olive group-hover:text-brand">
          <Icon className="h-3.5 w-3.5" />
        </span>
        <span className="min-w-0">
          <span className="block text-sm font-semibold leading-tight text-ink">{title}</span>
          {subtitle && <span className="mt-0.5 block truncate text-xs text-stone">{subtitle}</span>}
        </span>
      </span>
      {summary}
    </button>
    {!collapsed && <div>{children}</div>}
  </section>;
}

function RowSummary({ children }: { children: ReactNode }) {
  return <span className="inline-flex max-w-full min-w-0 items-center text-[11px] tabular-nums text-stone sm:shrink-0"><span className="min-w-0 truncate">{children}</span></span>;
}

function Kpi({ label, value, tone }: { label: string; value: string; tone: string }) {
  return <div className="min-w-0 px-2 py-2 text-left"><div className="ledger-label truncate">{label}</div><div className={`mt-0.5 truncate text-sm font-semibold tabular-nums ${tone}`}>{value}</div></div>;
}

function DashboardPanelView({ panel, onClose }: { panel: DashboardPanelDefinition; onClose: () => void }) {
  const viewStyle = {
    "--dashboard-chart-height": "min(68dvh, 720px)",
  } as CSSProperties;
  useEffect(() => {
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = previousOverflow;
    };
  }, []);

  return createPortal(<div className="fixed inset-0 z-[130] bg-[rgba(20,20,19,0.72)] p-3 backdrop-blur-sm sm:p-5" role="dialog" aria-modal="true" aria-label={`${panel.title} 全屏查看`} onClick={onClose}>
    <section className="dashboard-panel-view card mx-auto flex h-[calc(100dvh-1.5rem)] max-w-7xl flex-col p-4 sm:h-[calc(100dvh-2.5rem)] sm:p-5" style={viewStyle} onClick={(event) => event.stopPropagation()}>
      <div className="flex shrink-0 items-start justify-between gap-3 border-b border-line pb-3">
        <div className="min-w-0">
          <h2 className="truncate text-xl font-semibold tracking-[-0.018em]">{panel.title}</h2>
          {panel.subtitle && <p className="mt-1 truncate text-sm text-stone">{panel.subtitle}</p>}
        </div>
        <button type="button" className="grid h-10 w-10 shrink-0 place-items-center rounded-lg border border-line bg-panel text-stone hover:bg-tag hover:text-brand" onClick={onClose} title="关闭" aria-label="关闭全屏面板">
          <X className="h-5 w-5" />
        </button>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto pt-1">
        {panel.render()}
      </div>
    </section>
  </div>, document.body);
}

function Panel({ panelId, title, subtitle, className, onView, children }: { panelId: DashboardPanelId; title: string; subtitle?: string; className?: string; onView: (panelId: DashboardPanelId) => void; children: ReactNode }) {
  return <section className={`dashboard-panel-shell min-w-0 border-b border-line bg-panel ${className ?? ""}`}>
    <div className="flex min-h-11 items-center justify-between gap-3 border-b border-line px-3 py-2 md:px-4">
      <h3 className="min-w-0 truncate text-sm font-semibold tracking-[-0.012em] text-ink">{title}</h3>
      <div className="flex shrink-0 items-center gap-2">
        {subtitle && <span className="max-w-[12rem] truncate text-[10px] tabular-nums text-stone">{subtitle}</span>}
        <button type="button" className="grid h-6 w-6 place-items-center rounded-md text-stone hover:bg-tag hover:text-ink" onClick={() => onView(panelId)} title="全屏查看" aria-label={`全屏查看 ${title}`}>
          <Maximize2 className="h-3.5 w-3.5" />
        </button>
      </div>
    </div>
    <div className="dashboard-panel-body px-3 pb-3 md:px-4">{children}</div>
  </section>;
}

function DailyExpenseChart({ data, onOpenTransactions }: { data: DashboardSummary; onOpenTransactions: (href: string) => void }) {
  const showFullDates = dashboardUsesFullDateLabels(data);
  const rows = data.dailyExpenseSeries.map((row) => ({ date: dashboardDateLabel(row.date, showFullDates), fullDate: row.date, 支出: row.amount / 100, 笔数: row.txCount }));
  const annotations = data.annotations.filter((annotation) => annotation.date >= data.start && annotation.date < data.end);
  return <>
    <ChartBox empty={!rows.length}>
      <ResponsiveContainer width="100%" height="100%">
        <ComposedChart data={rows} margin={{ left: 8, right: 16, top: 14, bottom: 0 }} barCategoryGap="30%" onClick={(state) => {
          const payload = state?.activePayload?.[0]?.payload as { fullDate?: string } | undefined;
          if (payload?.fullDate) onOpenTransactions(transactionHref({ q: payload.fullDate }));
        }}>
          <CartesianGrid stroke="var(--chart-grid)" strokeOpacity={0.72} vertical={false} />
          <XAxis dataKey="date" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={10} />
          <YAxis yAxisId="money" width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} />
          <YAxis yAxisId="count" orientation="right" width={36} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} />
          <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => name === "笔数" ? [Number(value), "笔数"] : [formatValuation(Number(value), data.currency), name]} />
          <Bar yAxisId="money" dataKey="支出" fill="var(--chart-secondary)" radius={0} maxBarSize={16} />
          <Line yAxisId="count" type="linear" dataKey="笔数" stroke="var(--chart-primary)" strokeWidth={1.5} dot={false} activeDot={{ r: 3, strokeWidth: 0 }} />
        </ComposedChart>
      </ResponsiveContainer>
    </ChartBox>
    <AnnotationStrip annotations={annotations} currency={data.currency} showFullDates={showFullDates} onOpenTransactions={onOpenTransactions} />
  </>;
}

function WeekdayExpenseChart({ data }: { data: DashboardSummary }) {
  const rows = data.weekdayExpense.map((row) => ({ weekday: row.weekday, 支出: row.amount / 100, 笔数: row.txCount }));
  return <ChartBox empty={!rows.some((row) => row.支出 > 0)}>
    <ResponsiveContainer width="100%" height="100%">
      <BarChart data={rows} margin={{ left: 8, right: 16, top: 14, bottom: 0 }} barCategoryGap="30%">
        <CartesianGrid stroke="var(--chart-grid)" strokeOpacity={0.72} vertical={false} />
        <XAxis dataKey="weekday" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} />
        <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} />
        <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => name === "笔数" ? [Number(value), "笔数"] : [formatValuation(Number(value), data.currency), name]} />
        <Bar dataKey="支出" fill="var(--chart-tertiary)" radius={0} maxBarSize={28} />
      </BarChart>
    </ResponsiveContainer>
  </ChartBox>;
}

function CategoryTrendChart({ data }: { data: DashboardSummary }) {
  const chartSeries = useMemo(() => data.categorySeries.slice(0, 5), [data.categorySeries]);
  const { focusedAccount, visibleSeries, toggleFocus } = useFocusedSeries(chartSeries);
  const rows = useMemo(() => seriesRows(chartSeries), [chartSeries]);
  return <ChartBox empty={!rows.length}>
    <div className="flex h-full min-h-0 flex-col">
      <div className="min-h-0 flex-1">
        <ResponsiveContainer width="100%" height="100%">
          <LineChart data={rows} margin={{ left: 8, right: 16, top: 14, bottom: 0 }}>
            <CartesianGrid stroke="var(--chart-grid)" strokeOpacity={0.72} vertical={false} />
            <XAxis dataKey="month" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={14} />
            <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} />
            <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatValuation(Number(value), data.currency), labelForSeries(chartSeries, String(name))]} />
            {visibleSeries.map((series) => {
              const index = chartSeries.findIndex((item) => item.account === series.account);
              return <Line key={series.account} type="linear" dataKey={series.account} stroke={COLORS[index % COLORS.length]} strokeWidth={index === 0 ? 1.8 : 1.35} strokeDasharray={index === 1 ? "6 3" : index === 3 ? "2 3" : undefined} dot={false} activeDot={{ r: 3, strokeWidth: 0 }} />;
            })}
          </LineChart>
        </ResponsiveContainer>
      </div>
      <InteractiveLegend series={chartSeries} focusedAccount={focusedAccount} onToggle={toggleFocus} expandOnWideScreens />
    </div>
  </ChartBox>;
}

function useFocusedSeries<T extends { account: string }>(series: T[]) {
  const [focusedAccount, setFocusedAccount] = useState<string | null>(null);

  useEffect(() => {
    if (focusedAccount && !series.some((item) => item.account === focusedAccount)) {
      setFocusedAccount(null);
    }
  }, [focusedAccount, series]);

  const visibleSeries = useMemo(() => {
    if (!focusedAccount) return series;
    return series.filter((item) => item.account === focusedAccount);
  }, [focusedAccount, series]);

  const toggleFocus = (account: string) => {
    setFocusedAccount((current) => current === account ? null : account);
  };

  return { focusedAccount, visibleSeries, toggleFocus };
}

export function InteractiveLegend({ series, focusedAccount, onToggle, expandOnWideScreens = false }: { series: { account: string; alias?: string | null; label: string }[]; focusedAccount: string | null; onToggle: (account: string) => void; expandOnWideScreens?: boolean }) {
  if (!series.length) return null;
  return <div className={`mt-2 flex max-h-20 flex-wrap items-center justify-center gap-x-3 gap-y-2 overflow-y-auto px-1 text-xs ${expandOnWideScreens ? "sm:max-h-none sm:overflow-visible" : ""}`} aria-label="图例">
    {series.map((item, index) => {
      const selected = focusedAccount === item.account;
      const muted = focusedAccount != null && !selected;
      const label = formatAccountOptionLabel(item.account, item.label, item.alias);
      return <button key={item.account} type="button" className={`flex min-w-0 max-w-full items-center gap-1.5 rounded-full border px-2 py-1 transition ${selected ? "border-brand bg-tag text-ink" : muted ? "border-transparent text-stone opacity-55 hover:bg-tag hover:opacity-100" : "border-transparent text-stone hover:bg-tag"}`} onClick={() => onToggle(item.account)} aria-pressed={selected} title={selected ? "恢复全部显示" : `只显示 ${label}`}>
        <span className="h-2.5 w-2.5 shrink-0 rounded-sm" style={{ background: COLORS[index % COLORS.length], opacity: muted ? 0.45 : 1 }} />
        <span className="max-w-[11rem] truncate">{label}</span>
      </button>;
    })}
  </div>;
}

function CategoryRank({ rows, currency, visible, onOpenTransactions }: { rows: DashboardSummary["categorySeries"]; currency: string; visible: boolean; onOpenTransactions: (href: string) => void }) {
  if (!rows.length) return <EmptyPanel text="暂无分类支出" />;
  const maxValue = Math.max(1, ...rows.map((row) => row.total));
  return <div className="mt-3 space-y-2.5">
    {rows.slice(0, 8).map((row, index) => <button key={row.account} className="w-full text-left" onClick={() => onOpenTransactions(transactionHref({ category: row.account }))}>
      <ResponsiveValueRow label={formatAccountOptionLabel(row.account, row.label, row.alias)} labelClassName="truncate text-sm text-olive" value={visible ? formatCompactValuation(row.total / 100, currency) : "••••••"} valueClassName="text-sm font-semibold text-warm" valueTitle={visible ? formatCompactValuation(row.total / 100, currency) : "金额已隐藏"} />
      <div className="mt-1 h-1 overflow-hidden bg-line"><div className="h-full bg-brand" style={{ width: visible ? `${row.total / maxValue * 100}%` : "0%", opacity: Math.max(0.35, 1 - index * 0.09) }} /></div>
    </button>)}
  </div>;
}

function PayeeList({ data, visible, onOpenTransactions }: { data: DashboardSummary; visible: boolean; onOpenTransactions: (href: string) => void }) {
  if (!data.topPayees.length) return <EmptyPanel text="暂无商户数据" />;
  const maxValue = Math.max(1, ...data.topPayees.map((row) => row.amount));
  return <div className="mt-3 space-y-2.5">
    {data.topPayees.slice(0, 8).map((row) => <button key={row.payee} className="w-full text-left" onClick={() => onOpenTransactions(transactionHref({ q: row.payee }))}>
      <ResponsiveValueRow label={row.payee} labelClassName="truncate text-sm text-olive" value={visible ? formatCompactValuation(row.amount / 100, data.currency) : "••••••"} valueClassName="text-sm font-semibold text-warm" valueTitle={visible ? formatCompactValuation(row.amount / 100, data.currency) : "金额已隐藏"} />
      <div className="mt-1 flex items-center gap-2">
        <div className="h-1 flex-1 overflow-hidden bg-line"><div className="h-full bg-[var(--chart-secondary)]" style={{ width: visible ? `${row.amount / maxValue * 100}%` : "0%" }} /></div>
        <span className="w-10 text-right text-xs text-stone">{row.txCount} 笔</span>
      </div>
    </button>)}
  </div>;
}

function AnomalyList({ rows, currency, visible, onSelectCategory }: { rows: DashboardSummary["anomalies"]; currency: string; visible: boolean; onSelectCategory: (account: string, mode?: "exact" | "prefix") => void }) {
  if (!rows.length) return <EmptyPanel text="暂无高额支出" />;
  return <div className="mt-3 divide-y divide-line border-y border-line bg-panel">
    {rows.slice(0, 8).map((row) => <button key={`${row.source}:${row.account}`} className="w-full p-2.5 text-left hover:bg-tag" onClick={() => onSelectCategory(row.account, "prefix")}>
      <ResponsiveValueRow label={row.payee || row.narration || row.account} labelClassName="truncate text-sm font-medium text-olive" value={visible ? formatCompactValuation(row.amount / 100, currency) : "••••••"} valueClassName="font-semibold amount-danger" valueTitle={visible ? formatCompactValuation(row.amount / 100, currency) : "金额已隐藏"} detail={`${row.date} · ${row.account.replace(/^Expenses:/, "")}`} detailClassName="truncate text-xs text-stone" />
    </button>)}
  </div>;
}

function PaymentAccounts({ data, visible, onOpenTransactions }: { data: DashboardSummary; visible: boolean; onOpenTransactions: (href: string) => void }) {
  if (!data.topPaymentAccounts.length) return <EmptyPanel text="暂无消费账户" />;
  const rows = data.topPaymentAccounts.slice(0, 7);
  const maxValue = Math.max(1, ...rows.map((row) => row.amount));
  return <div className="mt-3 space-y-2.5">
    {rows.map((row) => <button key={row.account} className="w-full text-left" onClick={() => onOpenTransactions(transactionHref({ q: row.account }))}>
      <ResponsiveValueRow label={formatAccountOptionLabel(row.account, row.label, row.alias)} labelClassName="truncate text-sm text-olive" value={visible ? formatCompactValuation(row.amount / 100, data.currency) : "••••••"} valueClassName="text-sm font-semibold text-warm" valueTitle={visible ? formatCompactValuation(row.amount / 100, data.currency) : "金额已隐藏"} />
      <div className="mt-1 h-1 overflow-hidden bg-line"><div className="h-full bg-[var(--chart-tertiary)]" style={{ width: visible ? `${row.amount / maxValue * 100}%` : "0%" }} /></div>
    </button>)}
  </div>;
}

function ChartBox({ empty, compact = false, children }: { empty: boolean; compact?: boolean; children: ReactNode }) {
  if (empty) return <EmptyPanel text="暂无趋势数据" compact={compact} />;
  return <div className="mt-3 min-w-0 max-w-full overflow-hidden pb-1">
    <div className={`ledger-chart dashboard-chart-canvas min-w-0 max-w-full ${compact ? "dashboard-chart-canvas-compact" : ""}`}>
      {children}
    </div>
  </div>;
}

function HiddenChart({ compact = false }: { compact?: boolean }) {
  return <div className={`dashboard-chart-canvas mt-3 grid place-items-center border border-line bg-panel text-sm text-stone ${compact ? "dashboard-chart-canvas-compact" : ""}`}>金额已隐藏</div>;
}

function EmptyPanel({ text, compact = false }: { text: string; compact?: boolean }) {
  return <div className={`mt-3 grid place-items-center border border-line bg-panel p-4 text-center text-sm text-stone ${compact ? "min-h-28" : "min-h-36"}`}>{text}</div>;
}

function AnnotationStrip({ annotations, currency, showFullDates, onOpenTransactions }: { annotations: DashboardSummary["annotations"]; currency: string; showFullDates: boolean; onOpenTransactions: (href: string) => void }) {
  if (!annotations.length) return null;
  return <div className="mt-3 flex gap-2 overflow-x-auto pb-1">
    {annotations.slice(0, 8).map((annotation) => <button key={`${annotation.date}-${annotation.kind}-${annotation.payee}`} className="shrink-0 rounded-full border border-line bg-panel px-3 py-1.5 text-left text-xs text-stone hover:bg-tag" onClick={() => onOpenTransactions(annotation.drilldown)}>
      <span className={annotation.severity === "warning" ? "amount-danger" : "text-brand"}>{dashboardDateLabel(annotation.date, showFullDates)} {annotation.label}</span>
      {annotation.payee && <span className="ml-1 text-olive">{annotation.payee}</span>}
      {annotation.amount ? <span className="ml-1 tabular-nums">{formatCompactValuation(annotation.amount / 100, currency)}</span> : null}
    </button>)}
  </div>;
}

function transactionHref({ category, q, metadata }: { category?: string; q?: string; metadata?: string }) {
  const params = new URLSearchParams();
  if (category) {
    params.set("category", category);
    params.set("mode", "prefix");
  }
  if (q) params.set("q", q);
  if (metadata) params.set("metadata", metadata);
  const query = params.toString();
  return query ? `/transactions?${query}` : "/transactions";
}

function seriesRows(series: { account: string; values: { month: string; value: number }[] }[]) {
  const months = bucketLabels(series);
  const valuesByAccount = new Map(series.map((item) => [item.account, new Map(item.values.map((value) => [value.month, value.value]))]));
  return months.map((month) => {
    const row: Record<string, string | number> = { month };
    for (const item of series) {
      row[item.account] = (valuesByAccount.get(item.account)?.get(month) ?? 0) / 100;
    }
    return row;
  });
}

function bucketLabels(series: { values: { month: string }[] }[]) {
  const labels: string[] = [];
  const seen = new Set<string>();
  for (const item of series) {
    for (const value of item.values) {
      if (seen.has(value.month)) continue;
      seen.add(value.month);
      labels.push(value.month);
    }
  }
  return labels;
}

function dashboardUsesFullDateLabels(data: Pick<DashboardSummary, "start" | "end">) {
  const start = dashboardDateMs(data.start);
  const end = dashboardDateMs(data.end);
  return start != null && end != null && (end - start) / 86400000 > 730;
}

function dashboardDateMs(value: string) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return null;
  return Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
}

function dashboardDateLabel(value: string, showFullDate: boolean) {
  return showFullDate ? value : value.slice(5);
}

function labelForSeries(series: { account: string; alias?: string | null; label: string }[], account: string) {
  const row = series.find((item) => item.account === account);
  return row ? formatAccountOptionLabel(row.account, row.label, row.alias) : account;
}

const tooltipStyle = { background: "var(--ivory)", border: "1px solid var(--line)", borderRadius: 4, color: "var(--ink)", boxShadow: "0 10px 28px oklch(0.20 0.012 255 / 0.14)" };

function compactChartMoney(value: number) {
  return new Intl.NumberFormat("zh-CN", { notation: "compact", compactDisplay: "short", maximumFractionDigits: 1 }).format(value);
}
