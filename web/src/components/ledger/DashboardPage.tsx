import { useCallback, useEffect, useMemo, useState, type CSSProperties, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { AlertTriangle, ChevronDown, ChevronRight, Eye, EyeOff, Maximize2, RefreshCw, SlidersHorizontal, X } from "lucide-react";
import { Area, AreaChart, Bar, BarChart, CartesianGrid, ComposedChart, Legend, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
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
  "var(--chart-palette-1)",
  "var(--chart-palette-2)",
  "var(--chart-palette-3)",
  "var(--chart-palette-4)",
  "var(--chart-palette-5)",
  "var(--chart-palette-6)",
  "var(--chart-primary)",
  "var(--chart-secondary)",
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
  | "categoryTrend"
  | "privateKpis"
  | "cashflow"
  | "netWorth"
  | "accountTrend";

export function DashboardPage({ timeRange, valuationCurrency, visible, onToggleVisible, onSensitiveLocked, onOpenTransactions }: { timeRange: TimeRange; valuationCurrency: string; visible: boolean; onToggleVisible: () => void; onSensitiveLocked: () => void; onSelectCategory: (account: string, mode?: "exact" | "prefix") => void; onOpenTransactions: (href: string) => void }) {
  const router = useBrowserRouter();
  const { pathname, search } = useBrowserLocation();
  const filters = useMemo(() => parseDashboardFiltersFromSearch(search), [search]);
  const searchKey = useMemo(() => new URLSearchParams(search).toString(), [search]);
  const canonicalSearch = useMemo(() => dashboardFiltersToSearchParams(filters, new URLSearchParams(search)).toString(), [filters, search]);
  const { data, loading, error, reload } = useDashboardSummary(timeRange, filters, valuationCurrency, onSensitiveLocked);
  const { collapsedRows, toggleRow } = useDashboardRowCollapse();
  const [viewPanelId, setViewPanelId] = useState<DashboardPanelId | null>(null);
  const [overviewVisible, setOverviewVisible] = useState(false);
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

  useEffect(() => {
    if (!visible) setOverviewVisible(false);
  }, [visible]);

  if (loading && !data) return <DashboardStatusCard title="正在加载趋势看板" detail="正在读取当前时间范围、筛选条件和敏感资产数据。" icon={<RefreshCw className="h-4 w-4 animate-spin text-brand" />} />;
  if (error && !data) return <DashboardStatusCard title="看板加载失败" detail={error} icon={<AlertTriangle className="h-4 w-4 amount-expense" />} actionLabel="重试" onAction={reload} />;
  if (!data) return <DashboardStatusCard title="暂无看板数据" detail="服务端暂时没有返回可展示的汇总数据。" actionLabel="重新加载" onAction={reload} />;

  const compact = (value: number) => formatCompactValuation(value, data.currency);
  const maxExpense = data.anomalies[0]?.amount ?? 0;
  const topCategory = data.categorySeries[0];
  const topCategoryText = topCategory ? `${topCategory.label} · ${mask(compact(topCategory.total / 100))}` : "暂无";
  const privateSummary = visible
    ? `${compact(data.kpis.income / 100)} 收入 · ${compact(data.kpis.netWorth / 100)} 净资产`
    : "金额已隐藏";
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
    privateKpis: {
      title: "资产 KPI",
      subtitle: "敏感",
      render: () => <PrivateKpis data={data} visible={visible} />,
    },
    cashflow: {
      title: "收入与结余",
      subtitle: cashflowSubtitle(data, visible),
      render: () => visible ? <CashflowChart data={data} /> : <HiddenChart compact />,
    },
    netWorth: {
      title: "净资产趋势",
      subtitle: data.netWorthSeries.length ? `${data.netWorthSeries[0].date} ~ ${data.netWorthSeries.at(-1)?.date}` : "暂无",
      render: () => visible ? <NetWorthChart data={data} /> : <HiddenChart compact />,
    },
    accountTrend: {
      title: "账户余额趋势",
      subtitle: `${data.accountBalanceSeries.length} 个主要账户`,
      render: () => visible ? <AccountTrendChart data={data} /> : <HiddenChart />,
    },
  };
  const viewPanel = viewPanelId ? panels[viewPanelId] : null;

  return <div className="space-y-4">
    <DashboardFilterBar data={data} filters={filters} onChange={setFilter} onClear={clearFilter} onClearAll={clearFilters} />
    {loading && <DashboardNotice tone="loading" title="正在刷新看板" detail="当前图表先保留，上方筛选或时间范围的数据回来后会自动更新。" />}
    {error && <DashboardNotice tone="error" title="后台刷新失败" detail={error} actionLabel="重试" onAction={reload} />}
    {dashboardEmpty ? <DashboardEmptyState filtered={activeFilters} onClearFilters={clearFilters} onRetry={reload} /> : <>

    <DashboardOverview data={data} visible={overviewVisible} onToggleVisible={() => setOverviewVisible((value) => !value)} />

    <DashboardInlineRow rowId="monitor" title="消费监控" subtitle="支出、商户和付款来源优先展示" collapsed={collapsedRows.monitor} onToggle={toggleRow} summary={<RowSummary>{mask(compact(data.kpis.expense / 100))} 支出 · {data.anomalies.length} 笔高额</RowSummary>}>
      <div className="flex flex-col gap-2 lg:flex-row lg:items-center lg:justify-between">
        <div className="grid flex-1 grid-cols-2 divide-x divide-y divide-line overflow-hidden rounded-lg border border-line sm:grid-cols-3 xl:grid-cols-5 xl:divide-y-0">
          <Kpi label="本期支出" value={mask(compact(data.kpis.expense / 100))} tone="amount-expense" />
          <Kpi label="最大单笔" value={mask(compact(maxExpense / 100))} tone="amount-expense" />
          <Kpi label="高额支出" value={`${data.anomalies.length} 笔`} tone="text-warm" />
          <Kpi label="Top 分类" value={topCategoryText} tone="text-warm" />
          <Kpi label="结余" value={mask(compact(data.kpis.net / 100))} tone={tone(data.kpis.net)} />
        </div>
        <button className="shrink-0 self-end rounded-lg border border-line bg-panel px-2.5 py-1.5 text-sm text-olive hover:bg-tag lg:self-auto" onClick={onToggleVisible} aria-label={visible ? "隐藏看板金额" : "显示看板金额"} title={visible ? "隐藏看板金额" : "显示看板金额"}>
          {visible ? <EyeOff className="inline h-4 w-4 text-brand" /> : <Eye className="inline h-4 w-4 text-brand" />} <span className="ml-1">{visible ? "隐藏金额" : "显示金额"}</span>
        </button>
      </div>
    </DashboardInlineRow>

    <DashboardRow rowId="spending" title="支出作战室" subtitle="先看每天花了多少，再看花给谁、花在哪" collapsed={collapsedRows.spending} onToggle={toggleRow} summary={<RowSummary>{data.dailyExpenseSeries.length} 个支出日 · {data.topPayees.length} 个商户</RowSummary>}>
    <div className="dashboard-panel-grid">
      <Panel panelId="dailyExpense" className="xl:col-span-7" onView={setViewPanelId} title={panels.dailyExpense.title} subtitle={panels.dailyExpense.subtitle}>
        {panels.dailyExpense.render()}
      </Panel>
      <Panel panelId="weekdayExpense" className="xl:col-span-5" onView={setViewPanelId} title={panels.weekdayExpense.title} subtitle={panels.weekdayExpense.subtitle}>
        {panels.weekdayExpense.render()}
      </Panel>
      <Panel panelId="categoryRank" className="xl:col-span-4" onView={setViewPanelId} title={panels.categoryRank.title} subtitle={panels.categoryRank.subtitle}>
        {panels.categoryRank.render()}
      </Panel>
      <Panel panelId="payeeRank" className="xl:col-span-4" onView={setViewPanelId} title={panels.payeeRank.title} subtitle={panels.payeeRank.subtitle}>
        {panels.payeeRank.render()}
      </Panel>
      <Panel panelId="paymentAccounts" className="xl:col-span-4" onView={setViewPanelId} title={panels.paymentAccounts.title} subtitle={panels.paymentAccounts.subtitle}>
        {panels.paymentAccounts.render()}
      </Panel>
    </div>
    </DashboardRow>

    <DashboardRow rowId="risk" title="异常与趋势" subtitle="看高额支出和分类变化" collapsed={collapsedRows.risk} onToggle={toggleRow} summary={<RowSummary>{data.anomalies.length} 笔高额 · {trendPointCount(data.categorySeries)} 个趋势点</RowSummary>}>
    <div className="dashboard-panel-grid">
      <Panel panelId="anomalies" className="xl:col-span-4" onView={setViewPanelId} title={panels.anomalies.title} subtitle={panels.anomalies.subtitle}>
        {panels.anomalies.render()}
      </Panel>
      <Panel panelId="categoryTrend" className="xl:col-span-8" onView={setViewPanelId} title={panels.categoryTrend.title} subtitle={panels.categoryTrend.subtitle}>
        {panels.categoryTrend.render()}
      </Panel>
    </div>
    </DashboardRow>

    <DashboardRow rowId="private" title="资产与收入" collapsed={collapsedRows.private} onToggle={toggleRow} summary={<RowSummary>{privateSummary}</RowSummary>}>
    <div className="dashboard-panel-grid">
      <Panel panelId="privateKpis" className="xl:col-span-4" onView={setViewPanelId} title={panels.privateKpis.title} subtitle={panels.privateKpis.subtitle}>
        {panels.privateKpis.render()}
      </Panel>
      <Panel panelId="cashflow" className="xl:col-span-4" onView={setViewPanelId} title={panels.cashflow.title} subtitle={panels.cashflow.subtitle}>
        {panels.cashflow.render()}
      </Panel>
      <Panel panelId="netWorth" className="xl:col-span-4" onView={setViewPanelId} title={panels.netWorth.title} subtitle={panels.netWorth.subtitle}>
        {panels.netWorth.render()}
      </Panel>
      <Panel panelId="accountTrend" className="xl:col-span-12" onView={setViewPanelId} title={panels.accountTrend.title} subtitle={panels.accountTrend.subtitle}>
        {panels.accountTrend.render()}
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
  private: true,
};

type DashboardRowId = "monitor" | "spending" | "risk" | "private";

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
        setError(err instanceof Error ? err.message : "看板加载失败");
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
  return <section className="card p-5">
    <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex min-w-0 items-start gap-3">
        {icon && <span className="mt-0.5 grid h-8 w-8 shrink-0 place-items-center rounded-lg border border-line bg-panel">{icon}</span>}
        <div className="min-w-0">
          <h2 className="font-serif text-xl text-warm">{title}</h2>
          <p className="mt-1 text-sm text-stone">{detail}</p>
        </div>
      </div>
      {actionLabel && onAction && <button type="button" className="inline-flex h-9 shrink-0 items-center justify-center gap-1.5 rounded-lg border border-line bg-panel px-3 text-sm text-olive hover:bg-tag" onClick={onAction}>
        <RefreshCw className="h-4 w-4 text-brand" />
        {actionLabel}
      </button>}
    </div>
  </section>;
}

function DashboardNotice({ tone, title, detail, actionLabel, onAction }: { tone: "loading" | "error"; title: string; detail: string; actionLabel?: string; onAction?: () => void }) {
  return <section className={`rounded-lg border border-line px-3 py-2 ${tone === "error" ? "bg-panel" : "bg-panel/80"}`}>
    <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex min-w-0 items-center gap-2 text-sm">
        {tone === "loading" ? <RefreshCw className="h-4 w-4 shrink-0 animate-spin text-brand" /> : <AlertTriangle className="h-4 w-4 shrink-0 amount-expense" />}
        <span className="font-medium text-olive">{title}</span>
        <span className="min-w-0 text-stone">{detail}</span>
      </div>
      {actionLabel && onAction && <button type="button" className="inline-flex h-8 shrink-0 items-center justify-center gap-1.5 rounded-lg border border-line bg-panel px-2.5 text-xs text-olive hover:bg-tag" onClick={onAction}>
        <RefreshCw className="h-3.5 w-3.5 text-brand" />
        {actionLabel}
      </button>}
    </div>
  </section>;
}

function DashboardEmptyState({ filtered, onClearFilters, onRetry }: { filtered: boolean; onClearFilters: () => void; onRetry: () => void }) {
  return <section className="card p-6">
    <div className="mx-auto max-w-xl text-center">
      <h2 className="font-serif text-2xl text-warm">{filtered ? "没有匹配当前筛选的交易" : "当前时间范围暂无看板数据"}</h2>
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
  return data.kpis.income === 0
    && data.kpis.expense === 0
    && data.kpis.net === 0
    && data.netWorthSeries.length === 0
    && data.cashflowSeries.length === 0
    && data.dailyExpenseSeries.length === 0
    && data.categorySeries.length === 0
    && data.accountBalanceSeries.length === 0
    && data.anomalies.length === 0
    && data.topPayees.length === 0
    && data.topPaymentAccounts.length === 0
    && data.annotations.length === 0;
}

function DashboardFilterBar({ data, filters, onChange, onClear, onClearAll }: { data: DashboardSummary; filters: DashboardFilterState; onChange: (key: DashboardFilterKey, value: string | string[]) => void; onClear: (key: DashboardFilterKey) => void; onClearAll: () => void }) {
  const [expanded, setExpanded] = useState(false);
  const chips = activeFilterChips(data, filters);
  const Icon = expanded ? ChevronDown : ChevronRight;
  return <section className={`border border-line transition-colors ${expanded ? "card p-3 md:p-4" : "rounded-lg bg-panel/80 px-3 py-2"}`}>
    <div className="flex flex-col gap-2 lg:flex-row lg:items-center lg:justify-between">
      <button type="button" className="flex min-w-0 items-center gap-2 text-left text-sm font-medium text-warm hover:text-brand" onClick={() => setExpanded((value) => !value)} aria-expanded={expanded}>
        <span className="grid h-7 w-7 shrink-0 place-items-center rounded-md border border-line bg-panel">
          <SlidersHorizontal className="h-4 w-4 text-brand" />
        </span>
        <span className="min-w-0 truncate">筛选</span>
        <span className="shrink-0 rounded-full bg-tag px-2 py-0.5 text-xs font-normal text-stone">{chips.length ? `${chips.length} 个条件` : "全部数据"}</span>
        <Icon className="h-4 w-4 shrink-0 text-stone" />
      </button>
      {!expanded && chips.length > 0 && <div className="flex min-w-0 flex-wrap items-center gap-2 lg:justify-end">
        {chips.slice(0, 4).map((chip) => <FilterChip key={chip.key} chip={chip} onClear={onClear} />)}
        {chips.length > 4 && <span className="rounded-full bg-tag px-2.5 py-1 text-xs text-stone">+{chips.length - 4}</span>}
        <button type="button" className="rounded-full border border-line px-2.5 py-1 text-xs text-stone hover:bg-tag" onClick={onClearAll}>清空</button>
      </div>}
    </div>
    {expanded && <>
      <div className="mt-3 grid gap-2 sm:grid-cols-2 xl:grid-cols-7">
        <MultiFilterSelect label="类型" value={filters.type} onChange={(value) => onChange("type", value)} options={[{ value: "expense", label: "支出", count: 0 }, { value: "income", label: "收入", count: 0 }, { value: "transfer", label: "转账", count: 0 }]} />
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
      <summary className="flex min-h-10 cursor-pointer list-none items-center justify-between gap-2 rounded-lg border border-line bg-panel px-2 py-2 text-sm text-olive outline-none group-open:border-brand">
        <span className="min-w-0 truncate">{value.length ? `${value.length} 项` : "全部"}</span>
        <ChevronDown className="h-3.5 w-3.5 shrink-0 text-stone" />
      </summary>
      <div className="absolute z-30 mt-1 max-h-72 w-72 overflow-auto rounded-xl border border-line bg-paper p-2 shadow-xl">
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
    <Input className="h-10 w-full min-w-0 rounded-lg bg-panel text-sm text-olive" inputMode="decimal" placeholder="全部" value={value} onChange={(event) => onChange(event.target.value)} />
  </label>;
}

function activeFilterChips(data: DashboardSummary, filters: DashboardFilterState) {
  const chips: { key: DashboardFilterKey; label: string }[] = [];
  const add = (key: DashboardFilterKey, label: string, value: string) => {
    if (value.trim()) chips.push({ key, label: `${label}: ${value}` });
  };
  if (filters.type.length) chips.push({ key: "type", label: `类型: ${filters.type.map(typeLabel).join(" / ")}` });
  if (filters.category.length) chips.push({ key: "category", label: `分类: ${filters.category.map((value) => optionLabel(data.filterOptions.categories, value)).join(" / ")}` });
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

function typeLabel(value: string) {
  if (value === "expense") return "支出";
  if (value === "income") return "收入";
  if (value === "transfer") return "转账";
  return value;
}

function DashboardRow({ rowId, title, subtitle, collapsed, onToggle, summary, children }: { rowId: DashboardRowId; title: string; subtitle?: string; collapsed: boolean; onToggle: (rowId: DashboardRowId) => void; summary: ReactNode; children: ReactNode }) {
  const Icon = collapsed ? ChevronRight : ChevronDown;
  return <section className="space-y-2">
    <button type="button" className={`group flex w-full flex-col gap-2 rounded-lg border border-line px-3 py-2 text-left transition-colors hover:bg-tag sm:flex-row sm:items-center sm:justify-between ${collapsed ? "bg-panel" : "bg-transparent"}`} onClick={() => onToggle(rowId)} aria-expanded={!collapsed}>
      <span className="flex min-w-0 items-center gap-2.5">
        <span className="grid h-5 w-5 shrink-0 place-items-center rounded-md border border-line bg-panel text-olive group-hover:text-brand">
          <Icon className="h-3.5 w-3.5" />
        </span>
        <span className="min-w-0">
          <span className="block font-serif text-xl font-medium leading-tight">{title}</span>
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
  return <section className="card overflow-hidden p-0">
    <button type="button" className="group flex w-full flex-col gap-2 px-3 py-2 text-left transition-colors hover:bg-tag sm:flex-row sm:items-center sm:justify-between" onClick={() => onToggle(rowId)} aria-expanded={!collapsed}>
      <span className="flex min-w-0 items-center gap-2.5">
        <span className="grid h-5 w-5 shrink-0 place-items-center rounded-md border border-line bg-panel text-olive group-hover:text-brand">
          <Icon className="h-3.5 w-3.5" />
        </span>
        <span className="min-w-0">
          <span className="block font-serif text-xl font-medium leading-tight">{title}</span>
          {subtitle && <span className="mt-0.5 block truncate text-xs text-stone">{subtitle}</span>}
        </span>
      </span>
      {summary}
    </button>
    {!collapsed && <div className="border-t border-line p-2 md:p-2.5">{children}</div>}
  </section>;
}

function RowSummary({ children }: { children: ReactNode }) {
  return <span className="ledger-chip inline-flex max-w-full min-w-0 items-center rounded-full px-2.5 py-0.5 text-xs sm:shrink-0"><span className="min-w-0 truncate">{children}</span></span>;
}

function Kpi({ label, value, tone }: { label: string; value: string; tone: string }) {
  return <div className="min-w-0 bg-panel px-2 py-2 text-center"><div className="ledger-label truncate">{label}</div><div className={`mt-0.5 truncate text-base font-semibold tabular-nums ${tone}`}>{value}</div></div>;
}

function DashboardOverview({ data, visible, onToggleVisible }: { data: DashboardSummary; visible: boolean; onToggleVisible: () => void }) {
  const mask = (value: string) => visible ? value : "••••••";
  const toggleLabel = visible ? "隐藏首行金额" : "显示首行金额";
  return <section className="grid gap-2 sm:grid-cols-2 xl:grid-cols-4">
    <OverviewMetric label="收入" value={mask(formatCompactValuation(data.kpis.income / 100, data.currency))} tone="amount-income" detail={`${data.cashflowSeries.length} 个趋势点`} action={<button type="button" className="grid h-6 w-6 shrink-0 place-items-center rounded-md border border-line bg-paper text-stone hover:bg-tag hover:text-brand" onClick={onToggleVisible} title={toggleLabel} aria-label={toggleLabel} aria-pressed={visible}>{visible ? <EyeOff className="h-3.5 w-3.5" /> : <Eye className="h-3.5 w-3.5" />}</button>} />
    <OverviewMetric label="支出" value={mask(formatCompactValuation(data.kpis.expense / 100, data.currency))} tone="amount-expense" detail={`${data.dailyExpenseSeries.length} 个支出日`} />
    <OverviewMetric label="结余" value={mask(formatCompactValuation(data.kpis.net / 100, data.currency))} tone={tone(data.kpis.net)} detail={visible ? ratioLabel(data.kpis.savingsRate) : "金额已隐藏"} />
    <OverviewMetric label="净资产" value={mask(formatCompactValuation(data.kpis.netWorth / 100, data.currency))} tone={tone(data.kpis.netWorth)} detail={data.netWorthSeries.at(-1)?.date ?? "暂无"} />
  </section>;
}

function OverviewMetric({ label, value, tone, detail, action }: { label: string; value: string; tone: string; detail: string; action?: ReactNode }) {
  return <div className="min-w-0 rounded-lg border border-line bg-panel px-3 py-2">
    <div className="flex items-center justify-between gap-2">
      <span className="ledger-label">{label}</span>
      <span className="flex min-w-0 items-center justify-end gap-1.5">
        <span className="ledger-label min-w-0 truncate text-right">{detail}</span>
        {action}
      </span>
    </div>
    <div className={`mt-1 truncate text-lg font-semibold tabular-nums ${tone}`}>{value}</div>
  </div>;
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
          <h2 className="truncate font-serif text-2xl">{panel.title}</h2>
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
  return <section className={`dashboard-panel-shell card min-w-0 p-4 ${className ?? ""}`}>
    <div className="flex items-start justify-between gap-3">
      <h3 className="min-w-0 truncate font-serif text-xl">{title}</h3>
      <div className="flex shrink-0 items-center gap-2">
        {subtitle && <span className="ledger-chip max-w-[12rem] truncate rounded-full px-2 py-1 text-xs">{subtitle}</span>}
        <button type="button" className="grid h-8 w-8 place-items-center rounded-lg border border-line bg-panel text-stone hover:bg-tag hover:text-brand" onClick={() => onView(panelId)} title="全屏查看" aria-label={`全屏查看 ${title}`}>
          <Maximize2 className="h-4 w-4" />
        </button>
      </div>
    </div>
    {children}
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
          <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" vertical={false} />
          <XAxis dataKey="date" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={10} />
          <YAxis yAxisId="money" width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} />
          <YAxis yAxisId="count" orientation="right" width={36} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} />
          <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => name === "笔数" ? [Number(value), "笔数"] : [formatValuation(Number(value), data.currency), name]} />
          <Bar yAxisId="money" dataKey="支出" fill="rgb(var(--color-expense))" radius={[4, 4, 0, 0]} maxBarSize={22} />
          <Line yAxisId="count" type="monotone" dataKey="笔数" stroke="var(--chart-primary)" strokeWidth={2} dot={{ r: 2 }} />
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
        <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" vertical={false} />
        <XAxis dataKey="weekday" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} />
        <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} />
        <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => name === "笔数" ? [Number(value), "笔数"] : [formatValuation(Number(value), data.currency), name]} />
        <Bar dataKey="支出" fill="var(--chart-tertiary)" radius={[4, 4, 0, 0]} maxBarSize={34} />
      </BarChart>
    </ResponsiveContainer>
  </ChartBox>;
}

function NetWorthChart({ data }: { data: DashboardSummary }) {
  const rows = data.netWorthSeries.map((row) => ({ month: row.date, 净资产: row.netWorth / 100, 资产: row.assets / 100, 负债: row.liabilities / 100 }));
  return <ChartBox empty={!rows.length} compact>
    <ResponsiveContainer width="100%" height="100%">
      <LineChart data={rows} margin={{ left: 8, right: 16, top: 14, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" vertical={false} />
        <XAxis dataKey="month" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={14} />
        <YAxis width={58} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} domain={["dataMin", "dataMax"]} />
        <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatValuation(Number(value), data.currency), name]} />
        <Legend />
        <Line type="monotone" dataKey="净资产" stroke="var(--chart-primary)" strokeWidth={3} dot={{ r: 3 }} />
        <Line type="monotone" dataKey="资产" stroke="var(--chart-tertiary)" strokeWidth={2} dot={false} />
        <Line type="monotone" dataKey="负债" stroke="var(--chart-secondary)" strokeWidth={2} dot={false} />
      </LineChart>
    </ResponsiveContainer>
  </ChartBox>;
}

function CashflowChart({ data }: { data: DashboardSummary }) {
  const rows = data.cashflowSeries.map((row) => ({ month: row.month, 收入: row.income / 100, 支出: row.expense / 100, 结余: row.net / 100 }));
  return <ChartBox empty={!rows.length} compact>
    <ResponsiveContainer width="100%" height="100%">
      <ComposedChart data={rows} margin={{ left: 8, right: 16, top: 14, bottom: 0 }} barCategoryGap="28%">
        <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" vertical={false} />
        <XAxis dataKey="month" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={14} />
        <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} />
        <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatValuation(Number(value), data.currency), name]} />
        <Legend />
        <Bar dataKey="收入" fill="rgb(var(--color-income))" radius={[4, 4, 0, 0]} maxBarSize={22} />
        <Bar dataKey="支出" fill="rgb(var(--color-expense))" radius={[4, 4, 0, 0]} maxBarSize={22} />
        <Line type="monotone" dataKey="结余" stroke="var(--chart-primary)" strokeWidth={3} dot={{ r: 2 }} />
      </ComposedChart>
    </ResponsiveContainer>
  </ChartBox>;
}

function CategoryTrendChart({ data }: { data: DashboardSummary }) {
  const chartSeries = useMemo(() => data.categorySeries.slice(0, 8), [data.categorySeries]);
  const { focusedAccount, visibleSeries, toggleFocus } = useFocusedSeries(chartSeries);
  const rows = useMemo(() => seriesRows(chartSeries), [chartSeries]);
  return <ChartBox empty={!rows.length}>
    <div className="flex h-full min-h-0 flex-col">
      <div className="min-h-0 flex-1">
        <ResponsiveContainer width="100%" height="100%">
          <AreaChart data={rows} margin={{ left: 8, right: 16, top: 14, bottom: 0 }}>
            <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" vertical={false} />
            <XAxis dataKey="month" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={14} />
            <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} />
            <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatValuation(Number(value), data.currency), labelForSeries(chartSeries, String(name))]} />
            {visibleSeries.map((series) => {
              const index = chartSeries.findIndex((item) => item.account === series.account);
              return <Area key={series.account} type="monotone" dataKey={series.account} stackId={focusedAccount ? undefined : "expense"} stroke={COLORS[index % COLORS.length]} fill={COLORS[index % COLORS.length]} fillOpacity={0.72} />;
            })}
          </AreaChart>
        </ResponsiveContainer>
      </div>
      <InteractiveLegend series={chartSeries} focusedAccount={focusedAccount} onToggle={toggleFocus} expandOnWideScreens />
    </div>
  </ChartBox>;
}

function AccountTrendChart({ data }: { data: DashboardSummary }) {
  const chartSeries = data.accountBalanceSeries;
  const { focusedAccount, visibleSeries, toggleFocus } = useFocusedSeries(chartSeries);
  const rows = useMemo(() => seriesRows(chartSeries), [chartSeries]);
  return <ChartBox empty={!rows.length}>
    <div className="flex h-full min-h-0 flex-col">
      <div className="min-h-0 flex-1">
        <ResponsiveContainer width="100%" height="100%">
          <LineChart data={rows} margin={{ left: 8, right: 16, top: 14, bottom: 0 }}>
            <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" vertical={false} />
            <XAxis dataKey="month" tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={{ stroke: "var(--line)" }} minTickGap={14} />
            <YAxis width={56} tick={{ fill: "var(--stone)", fontSize: 11 }} tickLine={false} axisLine={false} tickFormatter={compactChartMoney} />
            <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatValuation(Number(value), data.currency), labelForSeries(chartSeries, String(name))]} />
            {visibleSeries.map((series) => {
              const index = chartSeries.findIndex((item) => item.account === series.account);
              return <Line key={series.account} type="monotone" dataKey={series.account} stroke={COLORS[index % COLORS.length]} strokeWidth={2} dot={{ r: 2 }} />;
            })}
          </LineChart>
        </ResponsiveContainer>
      </div>
      <InteractiveLegend series={chartSeries} focusedAccount={focusedAccount} onToggle={toggleFocus} />
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
  return <div className="mt-4 space-y-3">
    {rows.slice(0, 8).map((row, index) => <button key={row.account} className="w-full text-left" onClick={() => onOpenTransactions(transactionHref({ category: row.account }))}>
      <ResponsiveValueRow label={formatAccountOptionLabel(row.account, row.label, row.alias)} labelClassName="truncate text-sm text-olive" value={visible ? formatCompactValuation(row.total / 100, currency) : "••••••"} valueClassName="text-sm font-semibold text-warm" valueTitle={visible ? formatCompactValuation(row.total / 100, currency) : "金额已隐藏"} />
      <div className="mt-1 h-2 overflow-hidden rounded-full bg-line"><div className="h-full" style={{ width: `${row.total / maxValue * 100}%`, background: COLORS[index % COLORS.length] }} /></div>
    </button>)}
  </div>;
}

function PayeeList({ data, visible, onOpenTransactions }: { data: DashboardSummary; visible: boolean; onOpenTransactions: (href: string) => void }) {
  if (!data.topPayees.length) return <EmptyPanel text="暂无商户数据" />;
  const maxValue = Math.max(1, ...data.topPayees.map((row) => row.amount));
  return <div className="mt-4 space-y-3">
    {data.topPayees.slice(0, 8).map((row) => <button key={row.payee} className="w-full text-left" onClick={() => onOpenTransactions(transactionHref({ q: row.payee }))}>
      <ResponsiveValueRow label={row.payee} labelClassName="truncate text-sm text-olive" value={visible ? formatCompactValuation(row.amount / 100, data.currency) : "••••••"} valueClassName="text-sm font-semibold text-warm" valueTitle={visible ? formatCompactValuation(row.amount / 100, data.currency) : "金额已隐藏"} />
      <div className="mt-1 flex items-center gap-2">
        <div className="h-2 flex-1 overflow-hidden rounded-full bg-line"><div className="h-full bg-[rgb(var(--color-expense))]" style={{ width: `${row.amount / maxValue * 100}%` }} /></div>
        <span className="w-10 text-right text-xs text-stone">{row.txCount} 笔</span>
      </div>
    </button>)}
  </div>;
}

function AnomalyList({ rows, currency, visible, onSelectCategory }: { rows: DashboardSummary["anomalies"]; currency: string; visible: boolean; onSelectCategory: (account: string, mode?: "exact" | "prefix") => void }) {
  if (!rows.length) return <EmptyPanel text="暂无高额支出" />;
  return <div className="mt-4 divide-y divide-line overflow-hidden rounded-xl border border-line bg-panel">
    {rows.slice(0, 8).map((row) => <button key={`${row.source}:${row.account}`} className="w-full p-3 text-left hover:bg-tag" onClick={() => onSelectCategory(row.account, "prefix")}>
      <ResponsiveValueRow label={row.payee || row.narration || row.account} labelClassName="truncate text-sm font-medium text-olive" value={visible ? formatCompactValuation(row.amount / 100, currency) : "••••••"} valueClassName="font-semibold amount-expense" valueTitle={visible ? formatCompactValuation(row.amount / 100, currency) : "金额已隐藏"} detail={`${row.date} · ${row.account.replace(/^Expenses:/, "")}`} detailClassName="truncate text-xs text-stone" />
    </button>)}
  </div>;
}

function PaymentAccounts({ data, visible, onOpenTransactions }: { data: DashboardSummary; visible: boolean; onOpenTransactions: (href: string) => void }) {
  if (!data.topPaymentAccounts.length) return <EmptyPanel text="暂无消费账户" />;
  const rows = data.topPaymentAccounts.slice(0, 7);
  const maxValue = Math.max(1, ...rows.map((row) => row.amount));
  return <div className="mt-4 space-y-3">
    {rows.map((row) => <button key={row.account} className="w-full text-left" onClick={() => onOpenTransactions(transactionHref({ q: row.account }))}>
      <ResponsiveValueRow label={formatAccountOptionLabel(row.account, row.label, row.alias)} labelClassName="truncate text-sm text-olive" value={visible ? formatCompactValuation(row.amount / 100, data.currency) : "••••••"} valueClassName="text-sm font-semibold text-warm" valueTitle={visible ? formatCompactValuation(row.amount / 100, data.currency) : "金额已隐藏"} />
      <div className="mt-1 h-2 overflow-hidden rounded-full bg-line"><div className="h-full bg-[var(--chart-tertiary)]" style={{ width: `${row.amount / maxValue * 100}%` }} /></div>
    </button>)}
  </div>;
}

function PrivateKpis({ data, visible }: { data: DashboardSummary; visible: boolean }) {
  const mask = (value: string) => visible ? value : "••••••";
  return <div className="mt-4 grid grid-cols-2 gap-3">
    <SmallMetric label="资产" value={mask(formatCompactValuation(data.kpis.assets / 100, data.currency))} tone="amount-income" />
    <SmallMetric label="负债" value={mask(formatCompactValuation(data.kpis.liabilities / 100, data.currency))} tone="amount-expense" />
    <SmallMetric label="净资产" value={mask(formatCompactValuation(data.kpis.netWorth / 100, data.currency))} tone={tone(data.kpis.netWorth)} />
    <SmallMetric label="收入" value={mask(formatCompactValuation(data.kpis.income / 100, data.currency))} tone="amount-income" />
    <SmallMetric label="支出" value={mask(formatCompactValuation(data.kpis.expense / 100, data.currency))} tone="amount-expense" />
    <SmallMetric label="结余率" value={visible ? ratioLabel(data.kpis.savingsRate) : "••••••"} tone={tone(data.kpis.net)} />
  </div>;
}

function SmallMetric({ label, value, tone }: { label: string; value: string; tone: string }) {
  return <div className="rounded-xl border border-line bg-panel p-3"><div className="ledger-kicker truncate">{label}</div><div className={`mt-1 truncate text-base font-semibold tabular-nums ${tone}`}>{value}</div></div>;
}

function ChartBox({ empty, compact = false, children }: { empty: boolean; compact?: boolean; children: ReactNode }) {
  if (empty) return <EmptyPanel text="暂无趋势数据" compact={compact} />;
  return <div className="mt-4 min-w-0 max-w-full overflow-hidden pb-2">
    <div className={`ledger-chart dashboard-chart-canvas min-w-0 max-w-full ${compact ? "dashboard-chart-canvas-compact" : ""}`}>
      {children}
    </div>
  </div>;
}

function HiddenChart({ compact = false }: { compact?: boolean }) {
  return <div className={`dashboard-chart-canvas mt-4 grid place-items-center rounded-xl border border-line bg-panel text-sm text-stone ${compact ? "dashboard-chart-canvas-compact" : ""}`}>金额已隐藏</div>;
}

function EmptyPanel({ text, compact = false }: { text: string; compact?: boolean }) {
  return <div className={`mt-4 grid place-items-center rounded-xl border border-line bg-panel p-6 text-center text-sm text-stone ${compact ? "min-h-32" : "min-h-40"}`}>{text}</div>;
}

function AnnotationStrip({ annotations, currency, showFullDates, onOpenTransactions }: { annotations: DashboardSummary["annotations"]; currency: string; showFullDates: boolean; onOpenTransactions: (href: string) => void }) {
  if (!annotations.length) return null;
  return <div className="mt-3 flex gap-2 overflow-x-auto pb-1">
    {annotations.slice(0, 8).map((annotation) => <button key={`${annotation.date}-${annotation.kind}-${annotation.payee}`} className="shrink-0 rounded-full border border-line bg-panel px-3 py-1.5 text-left text-xs text-stone hover:bg-tag" onClick={() => onOpenTransactions(annotation.drilldown)}>
      <span className={annotation.severity === "warning" ? "amount-expense" : "text-brand"}>{dashboardDateLabel(annotation.date, showFullDates)} {annotation.label}</span>
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

function trendPointCount(series: { values: { month: string }[] }[]) {
  return bucketLabels(series).length;
}

function labelForSeries(series: { account: string; alias?: string | null; label: string }[], account: string) {
  const row = series.find((item) => item.account === account);
  return row ? formatAccountOptionLabel(row.account, row.label, row.alias) : account;
}

const tooltipStyle = { background: "var(--ivory)", border: "1px solid var(--line)", borderRadius: 12, color: "var(--ink)" };

function compactChartMoney(value: number) {
  return new Intl.NumberFormat("zh-CN", { notation: "compact", compactDisplay: "short", maximumFractionDigits: 1 }).format(value);
}

function ratioLabel(value: number | null) {
  if (value == null) return "暂无";
  return `${(value * 100).toFixed(1)}%`;
}

function tone(value: number) {
  return value >= 0 ? "amount-income" : "amount-expense";
}

function cashflowSubtitle(data: DashboardSummary, visible: boolean) {
  if (!visible) return "金额已隐藏";
  if (!data.cashflowSeries.length) return "暂无";
  const latest = data.cashflowSeries.at(-1);
  return latest ? `${latest.month} 结余 ${formatCompactValuation(latest.net / 100, data.currency)}` : "暂无";
}
