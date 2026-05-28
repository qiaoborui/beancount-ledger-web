import { useEffect, useMemo, useState, type CSSProperties, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { ChevronDown, ChevronRight, Eye, EyeOff, Maximize2, SlidersHorizontal, X } from "lucide-react";
import { Area, AreaChart, Bar, BarChart, CartesianGrid, ComposedChart, Legend, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { readJson } from "@/lib/clientFetch";
import { formatCny, formatCompactCny } from "@/lib/money";
import { timeRangeToParams } from "@/lib/timeRange";
import type { TimeRange } from "@/lib/timeRange";
import type { DashboardFilterOption, DashboardSummary } from "./types";

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

type DashboardFilterState = {
  category: string[];
  account: string[];
  payee: string[];
  tag: string[];
  type: string[];
  minAmount: string;
  maxAmount: string;
};

type DashboardPanelId =
  | "dailyExpense"
  | "weekdayExpense"
  | "categoryRank"
  | "payeeRank"
  | "paymentAccounts"
  | "budgetPressure"
  | "anomalies"
  | "categoryTrend"
  | "privateKpis"
  | "cashflow"
  | "netWorth"
  | "accountTrend";

const DEFAULT_DASHBOARD_FILTERS: DashboardFilterState = {
  category: [],
  account: [],
  payee: [],
  tag: [],
  type: [],
  minAmount: "",
  maxAmount: "",
};

export function DashboardPage({ timeRange, visible, onToggleVisible, onSensitiveLocked, onOpenTransactions }: { timeRange: TimeRange; visible: boolean; onToggleVisible: () => void; onSensitiveLocked: () => void; onSelectCategory: (account: string, mode?: "exact" | "prefix") => void; onOpenTransactions: (href: string) => void }) {
  const [filters, setFilters] = useState<DashboardFilterState>(DEFAULT_DASHBOARD_FILTERS);
  const { data, loading, error } = useDashboardSummary(timeRange, filters, onSensitiveLocked);
  const { collapsedRows, toggleRow } = useDashboardRowCollapse();
  const [viewPanelId, setViewPanelId] = useState<DashboardPanelId | null>(null);
  const mask = (value: string) => visible ? value : "••••••";
  const setFilter = (key: keyof DashboardFilterState, value: string | string[]) => setFilters((current) => ({ ...current, [key]: value }));
  const clearFilter = (key: keyof DashboardFilterState) => setFilters((current) => ({ ...current, [key]: Array.isArray(current[key]) ? [] : "" }));
  const clearFilters = () => setFilters(DEFAULT_DASHBOARD_FILTERS);

  useEffect(() => {
    if (!viewPanelId) return;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setViewPanelId(null);
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [viewPanelId]);

  if (loading && !data) return <section className="card p-6 text-sm text-stone">正在加载看板…</section>;
  if (error && !data) return <section className="card p-6 text-sm text-stone">{error}</section>;
  if (!data) return <section className="card p-6 text-sm text-stone">暂无看板数据</section>;

  const maxExpense = data.anomalies[0]?.amount ?? 0;
  const budgetUsed = data.kpis.budgetUsage == null ? "暂无" : `${Math.round(data.kpis.budgetUsage * 100)}%`;
  const topCategory = data.categorySeries[0];
  const topCategoryText = topCategory ? `${topCategory.label} · ${mask(formatCompactCny(topCategory.total / 100))}` : "暂无";
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
      render: () => <CategoryRank rows={data.categorySeries} visible={visible} onOpenTransactions={onOpenTransactions} />,
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
    budgetPressure: {
      title: "预算压力",
      subtitle: visible ? `剩余 ${formatCompactCny(data.kpis.budgetRemaining / 100)}` : "金额已隐藏",
      render: () => <BudgetPressure rows={data.budgetPressure} visible={visible} onSelectCategory={(account) => onOpenTransactions(transactionHref({ category: account }))} />,
    },
    anomalies: {
      title: "高额支出",
      subtitle: `${data.anomalies.length} 笔`,
      render: () => <AnomalyList rows={data.anomalies} visible={visible} onSelectCategory={(account) => onOpenTransactions(transactionHref({ category: account }))} />,
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

    <DashboardInlineRow rowId="monitor" title="消费监控" subtitle="支出、预算、商户和付款来源优先展示" collapsed={collapsedRows.monitor} onToggle={toggleRow} summary={<RowSummary>{mask(formatCompactCny(data.kpis.expense / 100))} 支出 · {budgetUsed} 预算</RowSummary>}>
      <div className="flex flex-col gap-2 lg:flex-row lg:items-center lg:justify-between">
        <div className="grid flex-1 grid-cols-2 divide-x divide-y divide-line overflow-hidden rounded-lg border border-line sm:grid-cols-3 xl:grid-cols-6 xl:divide-y-0">
          <Kpi label="本期支出" value={mask(formatCompactCny(data.kpis.expense / 100))} tone="amount-expense" />
          <Kpi label="预算使用" value={visible ? budgetUsed : "••••••"} tone={data.kpis.budgetUsage != null && data.kpis.budgetUsage >= 1 ? "amount-expense" : "amount-gold"} />
          <Kpi label="最大单笔" value={mask(formatCompactCny(maxExpense / 100))} tone="amount-expense" />
          <Kpi label="高额支出" value={`${data.anomalies.length} 笔`} tone="text-warm" />
          <Kpi label="Top 分类" value={topCategoryText} tone="text-warm" />
          <Kpi label="结余" value={mask(formatCompactCny(data.kpis.net / 100))} tone={tone(data.kpis.net)} />
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

    <DashboardRow rowId="risk" title="预算与异常" subtitle="看超预算风险、异常大额和分类趋势" collapsed={collapsedRows.risk} onToggle={toggleRow} summary={<RowSummary>{data.anomalies.length} 笔高额 · {trendPointCount(data.categorySeries)} 个趋势点</RowSummary>}>
    <div className="dashboard-panel-grid">
      <Panel panelId="budgetPressure" className="xl:col-span-6" onView={setViewPanelId} title={panels.budgetPressure.title} subtitle={panels.budgetPressure.subtitle}>
        {panels.budgetPressure.render()}
      </Panel>
      <Panel panelId="anomalies" className="xl:col-span-6" onView={setViewPanelId} title={panels.anomalies.title} subtitle={panels.anomalies.subtitle}>
        {panels.anomalies.render()}
      </Panel>
      <Panel panelId="categoryTrend" className="xl:col-span-12" onView={setViewPanelId} title={panels.categoryTrend.title} subtitle={panels.categoryTrend.subtitle}>
        {panels.categoryTrend.render()}
      </Panel>
    </div>
    </DashboardRow>

    <DashboardRow rowId="private" title="资产与收入" collapsed={collapsedRows.private} onToggle={toggleRow} summary={<RowSummary>{collapsedRows.private ? "已收起" : "已展开"}</RowSummary>}>
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

function useDashboardSummary(timeRange: TimeRange, filters: DashboardFilterState, onSensitiveLocked: () => void) {
  const [data, setData] = useState<DashboardSummary | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const params = dashboardQueryParams(timeRange, filters);

  useEffect(() => {
    const controller = new AbortController();
    async function load() {
      setLoading(true);
      setError("");
      try {
        const response = await fetch(`/api/ledger/dashboard?${params}`, { signal: controller.signal });
        if (response.status === 423 || response.status === 401) {
          onSensitiveLocked();
          setData(null);
          return;
        }
        const next = await readJson<DashboardSummary & { error?: string }>(response);
        if (!response.ok) throw new Error(next.error || `请求失败：${response.status}`);
        setData(next);
      } catch (err) {
        if (err instanceof DOMException && err.name === "AbortError") return;
        setError(err instanceof Error ? err.message : "看板加载失败");
      } finally {
        if (!controller.signal.aborted) setLoading(false);
      }
    }
    void load();
    return () => controller.abort();
  }, [onSensitiveLocked, params]);

  return { data, loading, error };
}

function dashboardQueryParams(timeRange: TimeRange, filters: DashboardFilterState) {
  const params = new URLSearchParams(timeRangeToParams(timeRange));
  for (const [key, value] of Object.entries(filters)) {
    const trimmed = Array.isArray(value) ? value.join(",") : value.trim();
    if (trimmed) params.set(key, trimmed);
  }
  return params.toString();
}

function DashboardFilterBar({ data, filters, onChange, onClear, onClearAll }: { data: DashboardSummary; filters: DashboardFilterState; onChange: (key: keyof DashboardFilterState, value: string | string[]) => void; onClear: (key: keyof DashboardFilterState) => void; onClearAll: () => void }) {
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

function FilterChip({ chip, onClear }: { chip: { key: keyof DashboardFilterState; label: string }; onClear: (key: keyof DashboardFilterState) => void }) {
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
        {options.length ? options.map((option) => <label key={option.value} className="flex cursor-pointer items-center gap-2 rounded-lg px-2 py-1.5 text-sm hover:bg-tag">
          <input type="checkbox" checked={selected.has(option.value)} onChange={() => toggle(option.value)} />
          <span className="min-w-0 flex-1 truncate text-olive">{option.label}</span>
          {option.count > 0 && <span className="shrink-0 text-xs text-stone">{option.count}</span>}
        </label>) : <div className="px-2 py-3 text-sm text-stone">暂无可选项</div>}
      </div>
    </details>
  </div>;
}

function MoneyFilterInput({ label, value, onChange }: { label: string; value: string; onChange: (value: string) => void }) {
  return <label className="min-w-0">
    <span className="mb-1 block text-[11px] text-stone">{label}</span>
    <input className="w-full min-w-0 rounded-lg border border-line bg-panel px-2 py-2 text-sm text-olive outline-none focus:border-brand" inputMode="decimal" placeholder="全部" value={value} onChange={(event) => onChange(event.target.value)} />
  </label>;
}

function activeFilterChips(data: DashboardSummary, filters: DashboardFilterState) {
  const chips: { key: keyof DashboardFilterState; label: string }[] = [];
  const add = (key: keyof DashboardFilterState, label: string, value: string) => {
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
  return options.find((option) => option.value === value)?.label ?? value;
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
  return <span className="inline-flex max-w-full items-center rounded-full bg-tag px-2.5 py-0.5 text-xs text-stone sm:shrink-0">{children}</span>;
}

function Kpi({ label, value, tone }: { label: string; value: string; tone: string }) {
  return <div className="min-w-0 bg-panel px-2 py-2 text-center"><div className="text-[10px] uppercase tracking-[0.12em] text-stone">{label}</div><div className={`mt-0.5 truncate text-base font-semibold ${tone}`}>{value}</div></div>;
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
        {subtitle && <span className="max-w-[12rem] truncate rounded-full bg-tag px-2 py-1 text-xs text-stone">{subtitle}</span>}
        <button type="button" className="grid h-8 w-8 place-items-center rounded-lg border border-line bg-panel text-stone hover:bg-tag hover:text-brand" onClick={() => onView(panelId)} title="全屏查看" aria-label={`全屏查看 ${title}`}>
          <Maximize2 className="h-4 w-4" />
        </button>
      </div>
    </div>
    {children}
  </section>;
}

function DailyExpenseChart({ data, onOpenTransactions }: { data: DashboardSummary; onOpenTransactions: (href: string) => void }) {
  const rows = data.dailyExpenseSeries.map((row) => ({ date: row.date.slice(5), fullDate: row.date, 支出: row.amount / 100, 笔数: row.txCount }));
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
          <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => name === "笔数" ? [Number(value), "笔数"] : [formatCny(Number(value)), name]} />
          <Bar yAxisId="money" dataKey="支出" fill="rgb(var(--color-expense))" radius={[4, 4, 0, 0]} maxBarSize={22} />
          <Line yAxisId="count" type="monotone" dataKey="笔数" stroke="var(--chart-primary)" strokeWidth={2} dot={{ r: 2 }} />
        </ComposedChart>
      </ResponsiveContainer>
    </ChartBox>
    <AnnotationStrip annotations={annotations} onOpenTransactions={onOpenTransactions} />
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
        <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => name === "笔数" ? [Number(value), "笔数"] : [formatCny(Number(value)), name]} />
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
        <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatCny(Number(value)), name]} />
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
        <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatCny(Number(value)), name]} />
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
            <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatCny(Number(value)), labelForSeries(chartSeries, String(name))]} />
            {visibleSeries.map((series) => {
              const index = chartSeries.findIndex((item) => item.account === series.account);
              return <Area key={series.account} type="monotone" dataKey={series.account} stackId={focusedAccount ? undefined : "expense"} stroke={COLORS[index % COLORS.length]} fill={COLORS[index % COLORS.length]} fillOpacity={0.72} />;
            })}
          </AreaChart>
        </ResponsiveContainer>
      </div>
      <InteractiveLegend series={chartSeries} focusedAccount={focusedAccount} onToggle={toggleFocus} />
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
            <Tooltip contentStyle={tooltipStyle} formatter={(value, name) => [formatCny(Number(value)), labelForSeries(chartSeries, String(name))]} />
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

function InteractiveLegend({ series, focusedAccount, onToggle }: { series: { account: string; label: string }[]; focusedAccount: string | null; onToggle: (account: string) => void }) {
  if (!series.length) return null;
  return <div className="mt-2 flex max-h-20 flex-wrap items-center justify-center gap-x-3 gap-y-2 overflow-y-auto px-1 text-xs" aria-label="图例">
    {series.map((item, index) => {
      const selected = focusedAccount === item.account;
      const muted = focusedAccount != null && !selected;
      return <button key={item.account} type="button" className={`flex min-w-0 max-w-full items-center gap-1.5 rounded-full border px-2 py-1 transition ${selected ? "border-brand bg-tag text-ink" : muted ? "border-transparent text-stone opacity-55 hover:bg-tag hover:opacity-100" : "border-transparent text-stone hover:bg-tag"}`} onClick={() => onToggle(item.account)} aria-pressed={selected} title={selected ? "恢复全部显示" : `只显示 ${item.label}`}>
        <span className="h-2.5 w-2.5 shrink-0 rounded-sm" style={{ background: COLORS[index % COLORS.length], opacity: muted ? 0.45 : 1 }} />
        <span className="max-w-[11rem] truncate">{item.label}</span>
      </button>;
    })}
  </div>;
}

function CategoryRank({ rows, visible, onOpenTransactions }: { rows: DashboardSummary["categorySeries"]; visible: boolean; onOpenTransactions: (href: string) => void }) {
  if (!rows.length) return <EmptyPanel text="暂无分类支出" />;
  const maxValue = Math.max(1, ...rows.map((row) => row.total));
  return <div className="mt-4 space-y-3">
    {rows.slice(0, 8).map((row, index) => <button key={row.account} className="w-full text-left" onClick={() => onOpenTransactions(transactionHref({ category: row.account }))}>
      <div className="flex items-center justify-between gap-3 text-sm">
        <span className="min-w-0 truncate text-olive">{row.label}</span>
        <strong className="shrink-0 text-warm">{visible ? formatCompactCny(row.total / 100) : "••••••"}</strong>
      </div>
      <div className="mt-1 h-2 overflow-hidden rounded-full bg-line"><div className="h-full" style={{ width: `${row.total / maxValue * 100}%`, background: COLORS[index % COLORS.length] }} /></div>
    </button>)}
  </div>;
}

function PayeeList({ data, visible, onOpenTransactions }: { data: DashboardSummary; visible: boolean; onOpenTransactions: (href: string) => void }) {
  if (!data.topPayees.length) return <EmptyPanel text="暂无商户数据" />;
  const maxValue = Math.max(1, ...data.topPayees.map((row) => row.amount));
  return <div className="mt-4 space-y-3">
    {data.topPayees.slice(0, 8).map((row) => <button key={row.payee} className="w-full text-left" onClick={() => onOpenTransactions(transactionHref({ q: row.payee }))}>
      <div className="flex items-center justify-between gap-3 text-sm">
        <span className="min-w-0 truncate text-olive">{row.payee}</span>
        <strong className="shrink-0 text-warm">{visible ? formatCompactCny(row.amount / 100) : "••••••"}</strong>
      </div>
      <div className="mt-1 flex items-center gap-2">
        <div className="h-2 flex-1 overflow-hidden rounded-full bg-line"><div className="h-full bg-[rgb(var(--color-expense))]" style={{ width: `${row.amount / maxValue * 100}%` }} /></div>
        <span className="w-10 text-right text-xs text-stone">{row.txCount} 笔</span>
      </div>
    </button>)}
  </div>;
}

function BudgetPressure({ rows, visible, onSelectCategory }: { rows: DashboardSummary["budgetPressure"]; visible: boolean; onSelectCategory: (account: string, mode?: "exact" | "prefix") => void }) {
  if (!rows.length) return <EmptyPanel text="暂无预算数据" />;
  return <div className="mt-4 space-y-3">
    {rows.slice(0, 7).map((row) => {
      const pct = Math.max(0, Math.min(140, (row.ratio ?? 0) * 100));
      return <button key={row.account} className="w-full rounded-xl border border-line bg-panel p-3 text-left hover:bg-tag" onClick={() => onSelectCategory(row.account, "prefix")}>
        <div className="flex items-center justify-between gap-3 text-sm">
          <span className="min-w-0 truncate text-olive">{row.label}</span>
          <strong className={pct >= 100 ? "amount-expense" : pct >= 80 ? "amount-gold" : "amount-income"}>{row.ratio == null ? "暂无" : `${Math.round(pct)}%`}</strong>
        </div>
        <div className="mt-2 h-2 overflow-hidden rounded-full bg-line"><div className={pct >= 100 ? "h-full bg-[rgb(var(--color-expense))]" : "h-full bg-brand"} style={{ width: `${Math.min(pct, 100)}%` }} /></div>
        <div className="mt-1 text-xs text-stone">{visible ? `已用 ${formatCompactCny(row.spent / 100)} · 剩余 ${formatCompactCny(row.remaining / 100)}` : "金额已隐藏"}</div>
      </button>;
    })}
  </div>;
}

function AnomalyList({ rows, visible, onSelectCategory }: { rows: DashboardSummary["anomalies"]; visible: boolean; onSelectCategory: (account: string, mode?: "exact" | "prefix") => void }) {
  if (!rows.length) return <EmptyPanel text="暂无高额支出" />;
  return <div className="mt-4 divide-y divide-line overflow-hidden rounded-xl border border-line bg-panel">
    {rows.slice(0, 8).map((row) => <button key={`${row.source}:${row.account}`} className="flex w-full items-center justify-between gap-3 p-3 text-left hover:bg-tag" onClick={() => onSelectCategory(row.account, "prefix")}>
      <span className="min-w-0">
        <span className="block truncate text-sm font-medium text-olive">{row.payee || row.narration || row.account}</span>
        <span className="mt-0.5 block truncate text-xs text-stone">{row.date} · {row.account.replace(/^Expenses:/, "")}</span>
      </span>
      <strong className="shrink-0 amount-expense">{visible ? formatCompactCny(row.amount / 100) : "••••••"}</strong>
    </button>)}
  </div>;
}

function PaymentAccounts({ data, visible, onOpenTransactions }: { data: DashboardSummary; visible: boolean; onOpenTransactions: (href: string) => void }) {
  if (!data.topPaymentAccounts.length) return <EmptyPanel text="暂无消费账户" />;
  const rows = data.topPaymentAccounts.slice(0, 7);
  const maxValue = Math.max(1, ...rows.map((row) => row.amount));
  return <div className="mt-4 space-y-3">
    {rows.map((row) => <button key={row.account} className="w-full text-left" onClick={() => onOpenTransactions(transactionHref({ q: row.account }))}>
      <div className="flex items-center justify-between gap-3 text-sm">
        <span className="min-w-0 truncate text-olive">{row.account.replace(/^(Assets|Liabilities):/, "")}</span>
        <strong className="shrink-0 text-warm">{visible ? formatCompactCny(row.amount / 100) : "••••••"}</strong>
      </div>
      <div className="mt-1 h-2 overflow-hidden rounded-full bg-line"><div className="h-full bg-[var(--chart-tertiary)]" style={{ width: `${row.amount / maxValue * 100}%` }} /></div>
    </button>)}
  </div>;
}

function PrivateKpis({ data, visible }: { data: DashboardSummary; visible: boolean }) {
  const mask = (value: string) => visible ? value : "••••••";
  return <div className="mt-4 grid grid-cols-2 gap-3">
    <SmallMetric label="资产" value={mask(formatCompactCny(data.kpis.assets / 100))} tone="amount-income" />
    <SmallMetric label="负债" value={mask(formatCompactCny(data.kpis.liabilities / 100))} tone="amount-expense" />
    <SmallMetric label="净资产" value={mask(formatCompactCny(data.kpis.netWorth / 100))} tone={tone(data.kpis.netWorth)} />
    <SmallMetric label="收入" value={mask(formatCompactCny(data.kpis.income / 100))} tone="amount-income" />
    <SmallMetric label="结余率" value={visible ? ratioLabel(data.kpis.savingsRate) : "••••••"} tone={tone(data.kpis.net)} />
    <SmallMetric label="预算剩余" value={mask(formatCompactCny(data.kpis.budgetRemaining / 100))} tone={data.kpis.budgetRemaining >= 0 ? "amount-income" : "amount-expense"} />
  </div>;
}

function SmallMetric({ label, value, tone }: { label: string; value: string; tone: string }) {
  return <div className="rounded-xl border border-line bg-panel p-3"><div className="text-[11px] uppercase tracking-[0.14em] text-stone">{label}</div><div className={`mt-1 truncate text-base font-semibold ${tone}`}>{value}</div></div>;
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

function AnnotationStrip({ annotations, onOpenTransactions }: { annotations: DashboardSummary["annotations"]; onOpenTransactions: (href: string) => void }) {
  if (!annotations.length) return null;
  return <div className="mt-3 flex gap-2 overflow-x-auto pb-1">
    {annotations.slice(0, 8).map((annotation) => <button key={`${annotation.date}-${annotation.kind}-${annotation.payee}`} className="shrink-0 rounded-full border border-line bg-panel px-3 py-1.5 text-left text-xs text-stone hover:bg-tag" onClick={() => onOpenTransactions(annotation.drilldown)}>
      <span className={annotation.severity === "warning" ? "amount-expense" : "text-brand"}>{annotation.date.slice(5)} {annotation.label}</span>
      {annotation.payee && <span className="ml-1 text-olive">{annotation.payee}</span>}
      {annotation.amount ? <span className="ml-1 tabular-nums">{formatCompactCny(annotation.amount / 100)}</span> : null}
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
  return months.map((month) => {
    const row: Record<string, string | number> = { month };
    for (const item of series) {
      row[item.account] = (item.values.find((value) => value.month === month)?.value ?? 0) / 100;
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

function trendPointCount(series: { values: { month: string }[] }[]) {
  return bucketLabels(series).length;
}

function labelForSeries(series: { account: string; label: string }[], account: string) {
  return series.find((row) => row.account === account)?.label ?? account;
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
  return latest ? `${latest.month} 结余 ${formatCompactCny(latest.net / 100)}` : "暂无";
}
