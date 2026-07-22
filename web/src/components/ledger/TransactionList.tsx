import { useEffect, useMemo, useRef, useState } from "react";
import { Plus, SlidersHorizontal, Trash2 } from "lucide-react";
import { formatMoney } from "@/lib/money";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { MobileSheet } from "./MobileSheet";
import { ResponsiveValueRow } from "./shared";
import type { ParsedTransaction } from "@/lib/schemas";
import { formatAccountOptionLabel } from "./accountDisplay";
import type { AccountView, MetadataValue, Txn } from "./types";
import { categoryAccounts, filterTransactions, metadataPairs, transactionKey, type TransactionFilterMatchMode } from "./transactionFilters";

function useDebouncedValue<T>(value: T, delay = 160) {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const id = window.setTimeout(() => setDebounced(value), delay);
    return () => window.clearTimeout(id);
  }, [delay, value]);
  return debounced;
}

const ALL_FILTER_VALUE = "__all__";
const FILTER_VIEW_STORAGE_KEY = "ledger.transactionList.filterViews.v1";
const MAX_FILTER_VIEWS = 8;

type TransactionFilterSnapshot = {
  categoryQuery: string;
  metadataQuery: string;
  searchQuery: string;
  matchMode: TransactionFilterMatchMode;
  viewMode: "compact" | "full";
};

type StoredFilterView = {
  id: string;
  name: string;
  filters: TransactionFilterSnapshot;
  createdAt: number;
  lastUsedAt: number;
};

type StoredFilterViews = {
  saved: StoredFilterView[];
  recent: StoredFilterView[];
};

function defaultFilterViews(): StoredFilterViews {
  return { saved: [], recent: [] };
}

function filterSnapshotSignature(filters: TransactionFilterSnapshot): string {
  return JSON.stringify({
    categoryQuery: filters.categoryQuery.trim(),
    metadataQuery: filters.metadataQuery.trim(),
    searchQuery: filters.searchQuery.trim(),
    matchMode: filters.matchMode,
    viewMode: filters.viewMode,
  });
}

function hasFilterSnapshot(filters: TransactionFilterSnapshot): boolean {
  return Boolean(filters.categoryQuery.trim() || filters.metadataQuery.trim() || filters.searchQuery.trim());
}

function filterSnapshotLabel(filters: TransactionFilterSnapshot): string {
  const parts = [
    filters.searchQuery.trim() && `搜索 ${filters.searchQuery.trim()}`,
    filters.categoryQuery.trim() && `分类 ${filters.categoryQuery.trim()} ${filters.matchMode === "exact" ? "精确" : "前缀"}`,
    filters.metadataQuery.trim() && `标签 ${filters.metadataQuery.trim()}`,
    filters.viewMode === "full" && "完整视图",
  ].filter(Boolean);
  return parts.join(" · ") || "全部流水";
}

function loadFilterViews(): StoredFilterViews {
  if (typeof window === "undefined") return defaultFilterViews();
  try {
    const raw = window.localStorage.getItem(FILTER_VIEW_STORAGE_KEY);
    if (!raw) return defaultFilterViews();
    const parsed = JSON.parse(raw) as Partial<StoredFilterViews>;
    return {
      saved: Array.isArray(parsed.saved) ? parsed.saved.slice(0, MAX_FILTER_VIEWS) : [],
      recent: Array.isArray(parsed.recent) ? parsed.recent.slice(0, MAX_FILTER_VIEWS) : [],
    };
  } catch {
    return defaultFilterViews();
  }
}

function saveFilterViews(views: StoredFilterViews) {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(FILTER_VIEW_STORAGE_KEY, JSON.stringify(views));
  } catch {
    // Local storage is an enhancement for the workbench, so unavailable storage should not break filtering.
  }
}

function upsertRecentFilterView(views: StoredFilterViews, filters: TransactionFilterSnapshot, now = Date.now()): StoredFilterViews {
  const signature = filterSnapshotSignature(filters);
  const recent = views.recent.filter((view) => filterSnapshotSignature(view.filters) !== signature);
  const saved = views.saved.map((view) => filterSnapshotSignature(view.filters) === signature ? { ...view, lastUsedAt: now } : view);
  return {
    saved,
    recent: [{ id: `recent-${now}`, name: filterSnapshotLabel(filters), filters, createdAt: now, lastUsedAt: now }, ...recent].slice(0, MAX_FILTER_VIEWS),
  };
}

function saveNamedFilterView(views: StoredFilterViews, filters: TransactionFilterSnapshot, now = Date.now()): StoredFilterViews {
  const signature = filterSnapshotSignature(filters);
  const existing = views.saved.find((view) => filterSnapshotSignature(view.filters) === signature);
  const saved = views.saved.filter((view) => filterSnapshotSignature(view.filters) !== signature);
  return {
    recent: views.recent,
    saved: [{
      id: existing?.id ?? `saved-${now}`,
      name: existing?.name ?? filterSnapshotLabel(filters),
      filters,
      createdAt: existing?.createdAt ?? now,
      lastUsedAt: now,
    }, ...saved].slice(0, MAX_FILTER_VIEWS),
  };
}

function isKeyboardInputTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  if (target.isContentEditable) return true;
  return ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName);
}

function MetadataBadges({ txn, limit }: { txn: Txn; limit?: number }) {
  const items = [
    ...metadataPairs(txn).map(([key, value]) => ({ key: `${key}:${String(value)}`, label: `${key}: ${String(value)}` })),
    ...(txn.tags ?? []).map((tag) => ({ key: `tag:${tag}`, label: `#${tag}` })),
  ];
  const shown = typeof limit === "number" ? items.slice(0, limit) : items;
  if (!shown.length) return null;
  return <div className="mt-2 flex flex-wrap gap-1">{shown.map((item) => <span key={item.key} className="ledger-chip rounded-full px-2 py-0.5 text-[11px]">{item.label}</span>)}{limit && items.length > limit && <span className="ledger-chip rounded-full px-2 py-0.5 text-[11px]">+{items.length - limit}</span>}</div>;
}

function pendingLabel(txn: Txn) {
  if (!txn.pending) return "";
  return txn.pending.kind === "append" ? "待同步新增" : "待同步修改";
}

function sourceLabel(txn: Txn) {
  if (txn.pending?.kind === "append") return "本地待同步";
  return `${txn.source.file}:${txn.source.line}`;
}

/** 从 account 路径中提取简短名称（最后一个冒号后的部分） */
function shortAccount(account: string): string {
  const idx = account.lastIndexOf(":");
  return idx >= 0 ? account.slice(idx + 1) : account;
}

/** 从一笔交易中提取最关键的金额（优先支出/收入，其次资产变动） */
function primaryPosting(t: Txn): Txn["postings"][number] | null {
  const cat = t.postings.find((p) => p.account.startsWith("Expenses:") || p.account.startsWith("Income:"));
  if (cat) return cat;
  const asset = t.postings.find((p) => p.account.startsWith("Assets:") || p.account.startsWith("Liabilities:"));
  return asset ?? null;
}

/** 金额颜色：支出(借方)=expense红，收入(贷方)=income绿，零或其他=品牌色 */
function amountColor(amount: number): string {
  if (amount > 0) return "amount-expense";
  if (amount < 0) return "amount-income";
  return "amount-gold";
}

/** 格式化流水主金额：支出显示为负，收入显示为正 */
function fmtTxnAmount(amount: number, currency?: string): string {
  const sign = amount <= 0 ? "+" : "-";
  return `${sign}${formatMoney(Math.abs(amount) / 100, currency ?? "CNY")}`;
}

/** 格式化 posting 金额（带符号，正=借/支出方向，负=贷/收入方向） */
function fmtPostingAmount(amount: number, currency?: string): string {
  const sign = amount >= 0 ? "+" : "-";
  return `${sign}${formatMoney(Math.abs(amount) / 100, currency ?? "CNY")}`;
}

/** 紧凑借贷方流向：贷记(贷方) → 借记(借方) */
function PostingFlow({ postings, maxShow = 3 }: { postings: Txn["postings"]; maxShow?: number }) {
  const debits = postings.filter(p => p.amount > 0);
  const credits = postings.filter(p => p.amount < 0);

  // 合并展示：先贷记(负数)，后借记(正数)，中间用箭头分隔
  const allItems: { account: string; amount: number; currency?: string; side: "credit" | "debit" }[] = [
    ...credits.map(p => ({ account: p.account, amount: p.amount, currency: p.currency, side: "credit" as const })),
    ...debits.map(p => ({ account: p.account, amount: p.amount, currency: p.currency, side: "debit" as const })),
  ];

  // 截断：保留所有贷记 + 最多 maxShow-creditCount 个借记
  const creditCount = credits.length;
  const maxDebitShow = Math.max(1, maxShow - creditCount);
  const shownCredits = credits.slice(0, maxShow);
  const shownDebits = debits.slice(0, maxDebitShow);
  const remaining = Math.max(0, credits.length - shownCredits.length) + Math.max(0, debits.length - shownDebits.length);

  if (allItems.length === 0) return null;

  return (
    <div className="mt-1 flex min-w-0 flex-wrap items-center gap-x-1 gap-y-0.5 text-xs">
      {shownCredits.map((p, i) => (
        <span key={`c-${i}`} className="amount-income min-w-0 [overflow-wrap:anywhere]">
          {shortAccount(p.account)} {fmtPostingAmount(p.amount, p.currency)}
        </span>
      ))}
      {shownCredits.length > 0 && shownDebits.length > 0 && (
        <span className="mx-0.5 text-stone/40">→</span>
      )}
      {shownDebits.map((p, i) => (
        <span key={`d-${i}`} className="amount-expense min-w-0 [overflow-wrap:anywhere]">
          {shortAccount(p.account)} {fmtPostingAmount(p.amount, p.currency)}
        </span>
      ))}
      {remaining > 0 && <span className="text-stone/40">… +{remaining}</span>}
    </div>
  );
}

function TransactionCard({ txn, selected, viewMode, onSelect }: { txn: Txn; selected: boolean; viewMode?: "compact" | "full"; onSelect: () => void }) {
  const primary = primaryPosting(txn);
  const amt = primary?.amount ?? null;
  const pending = pendingLabel(txn);
  return (
    <button type="button" className={`transaction-list-card card mb-2 block w-full min-w-0 overflow-hidden p-4 text-left ${selected ? "border-brand bg-[var(--selected-bg)]" : ""}`} onClick={onSelect}>
      <ResponsiveValueRow
        label={<div className="min-w-0">
          <strong className="block truncate text-[15px] leading-5 text-ink">{txn.payee}</strong>
          {pending && <span className="mt-1 inline-block rounded-full bg-brand/10 px-2 py-0.5 text-[11px] text-brand">{pending}</span>}
        </div>}
        labelClassName="truncate"
        value={amt != null ? fmtTxnAmount(amt, primary?.currency) : null}
        valueClassName={amt != null ? `text-base font-semibold ${amountColor(amt)}` : "hidden"}
        valueTitle={amt != null ? fmtTxnAmount(amt, primary?.currency) : undefined}
      />
      <div className="mt-1 text-sm leading-5 text-warm [overflow-wrap:anywhere]">{txn.narration}</div>
      {viewMode === "full" ? (
        <>
          <PostingFlow postings={txn.postings} />
          <MetadataBadges txn={txn} limit={6} />
          <div className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-stone">{txn.date}</div>
        </>
      ) : (
        <>
          <div className="mt-1 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5 text-xs leading-5 text-stone">{txn.date}{txn.postings.filter(p => p.account.startsWith("Expenses:") || p.account.startsWith("Income:")).map((p, j) => <span key={j} className="min-w-0 [overflow-wrap:anywhere]">{p.account}</span>)}</div>
          <MetadataBadges txn={txn} limit={3} />
        </>
      )}
    </button>
  );
}

function TransactionTableRow({ txn, selected, viewMode, onSelect, rowRef, rowId }: { txn: Txn; selected: boolean; viewMode?: "compact" | "full"; onSelect: () => void; rowRef?: (node: HTMLButtonElement | null) => void; rowId?: string }) {
  const primary = primaryPosting(txn);
  const amt = primary?.amount ?? null;
  const categoryRows = categoryAccounts(txn);
  const paymentAccounts = txn.postings.filter((posting) => posting.account.startsWith("Assets:") || posting.account.startsWith("Liabilities:"));
  const meta = metadataPairs(txn);
  const pending = pendingLabel(txn);
  return (
    <button
      id={rowId}
      ref={rowRef}
      type="button"
      className={`transaction-list-card grid w-full grid-cols-[84px_minmax(280px,1.2fr)_140px_minmax(260px,1fr)_minmax(180px,0.75fr)] items-center gap-4 px-4 py-3.5 text-left transition-colors hover:bg-tag focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2 focus-visible:ring-offset-panel ${selected ? "bg-[var(--selected-bg)]" : "bg-panel"}`}
      onClick={onSelect}
    >
      <div className="text-xs font-medium tabular-nums text-stone">
        <div className="text-olive">{txn.date.slice(5)}</div>
        <div className="mt-1 text-[11px] text-stone/70">{txn.date.slice(0, 4)}</div>
      </div>
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <strong className="truncate text-[15px] leading-5 text-ink">{txn.payee}</strong>
          {pending && <span className="shrink-0 rounded-full bg-brand/10 px-2 py-0.5 text-[11px] text-brand">{pending}</span>}
        </div>
        <div className="mt-0.5 truncate text-xs leading-5 text-warm">{txn.narration || "无说明"}</div>
        {viewMode === "full" && <PostingFlow postings={txn.postings} maxShow={4} />}
      </div>
      <div className={`text-right text-base font-semibold tabular-nums ${amt == null ? "text-stone" : amountColor(amt)}`}>{amt == null ? "—" : fmtTxnAmount(amt, primary?.currency)}</div>
      <div className="min-w-0">
        <div className="truncate text-xs font-medium text-warm">{categoryRows.join(" · ") || "未分类"}</div>
        <div className="mt-1 truncate text-[11px] text-stone">{paymentAccounts.map((posting) => shortAccount(posting.account)).join(" / ") || "无付款账户"}</div>
      </div>
      <div className="min-w-0">
        {meta.length || txn.tags?.length ? (
          <div className="flex flex-wrap gap-1">
            {meta.slice(0, 2).map(([key, value]) => <span key={`${key}:${String(value)}`} className="ledger-chip max-w-[120px] truncate rounded-full px-2 py-0.5 text-[11px]">{key}: {String(value)}</span>)}
            {(txn.tags ?? []).slice(0, 1).map((tag) => <span key={tag} className="ledger-chip max-w-[100px] truncate rounded-full px-2 py-0.5 text-[11px]">#{tag}</span>)}
            {meta.length + (txn.tags?.length ?? 0) > 3 && <span className="ledger-chip rounded-full px-2 py-0.5 text-[11px]">+{meta.length + (txn.tags?.length ?? 0) - 3}</span>}
          </div>
        ) : <span className="text-xs text-stone/60">—</span>}
      </div>
    </button>
  );
}

export function TransactionList({ txns, accounts = [], searchable, categoryQuery, setCategoryQuery, metadataQuery, setMetadataQuery, searchQuery, setSearchQuery, matchMode, setMatchMode, viewMode, setViewMode, onUpdate, onDelete, onReverse, showToast }: { txns: Txn[]; accounts?: AccountView[]; searchable?: boolean; categoryQuery?: string; setCategoryQuery?: (value: string) => void; metadataQuery?: string; setMetadataQuery?: (value: string) => void; searchQuery?: string; setSearchQuery?: (value: string) => void; matchMode?: "exact" | "prefix"; setMatchMode?: (mode: "exact" | "prefix") => void; viewMode?: "compact" | "full"; setViewMode?: (mode: "compact" | "full") => void; onUpdate?: (source: Txn["source"], entry: ParsedTransaction) => void; onDelete?: (source: Txn["source"], reason: string) => void; onReverse?: (source: Txn["source"], date: string) => void; showToast?: (kind: "info" | "success" | "error", text: string) => void }) {
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(20);
  const [selected, setSelected] = useState<Txn | null>(null);
  const [activeTxnKey, setActiveTxnKey] = useState<string | null>(null);
  const [mobileFiltersOpen, setMobileFiltersOpen] = useState(false);
  const [filterViews, setFilterViews] = useState<StoredFilterViews>(() => loadFilterViews());
  const desktopRowRefs = useRef(new Map<string, HTMLButtonElement>());
  const categories = useMemo(() => Array.from(new Set(txns.flatMap(categoryAccounts))).sort(), [txns]);
  const accountOptionLabels = useMemo(() => Object.fromEntries(accounts.map((account) => [account.account, formatAccountOptionLabel(account)])), [accounts]);
  const accountOptionLabel = (account: string) => accountOptionLabels[account] ?? account;
  const debouncedCategoryQuery = useDebouncedValue(categoryQuery ?? "");
  const debouncedSearchQuery = useDebouncedValue(searchQuery ?? "");
  const debouncedMetadataQuery = useDebouncedValue(metadataQuery ?? "");
  const query = debouncedCategoryQuery.trim().toLowerCase();
  const metadataOptions = useMemo(() => Array.from(new Set(txns.flatMap((t) => [
    ...metadataPairs(t).map(([key, value]) => `${key}:${String(value)}`),
    ...(t.tags ?? []).map((tag) => `#${tag}`),
  ]))).sort(), [txns]);
  const immediateFilterSnapshot = useMemo<TransactionFilterSnapshot>(() => ({
    categoryQuery: (categoryQuery ?? "").trim(),
    metadataQuery: (metadataQuery ?? "").trim(),
    searchQuery: (searchQuery ?? "").trim(),
    matchMode: matchMode ?? "prefix",
    viewMode: viewMode ?? "compact",
  }), [categoryQuery, metadataQuery, searchQuery, matchMode, viewMode]);
  const currentFilterSnapshot = useMemo<TransactionFilterSnapshot>(() => ({
    categoryQuery: debouncedCategoryQuery.trim(),
    metadataQuery: debouncedMetadataQuery.trim(),
    searchQuery: debouncedSearchQuery.trim(),
    matchMode: matchMode ?? "prefix",
    viewMode: viewMode ?? "compact",
  }), [debouncedCategoryQuery, debouncedMetadataQuery, debouncedSearchQuery, matchMode, viewMode]);
  const rows = useMemo(() => filterTransactions(txns, currentFilterSnapshot), [txns, currentFilterSnapshot]);

  const totalPages = Math.max(1, Math.ceil(rows.length / pageSize));
  const safePage = Math.min(page, totalPages);
  const pageRows = rows.slice((safePage - 1) * pageSize, safePage * pageSize);

  useEffect(() => { setPage(1); }, [debouncedCategoryQuery, debouncedSearchQuery, debouncedMetadataQuery, pageSize, txns.length, matchMode]);
  useEffect(() => { saveFilterViews(filterViews); }, [filterViews]);
  useEffect(() => {
    if (!searchable || !hasFilterSnapshot(currentFilterSnapshot)) return;
    setFilterViews((views) => upsertRecentFilterView(views, currentFilterSnapshot));
  }, [currentFilterSnapshot, searchable]);

  useEffect(() => {
    if (!pageRows.length) {
      setActiveTxnKey(null);
      return;
    }
    if (!activeTxnKey || !pageRows.some((txn) => transactionKey(txn) === activeTxnKey)) {
      setActiveTxnKey(transactionKey(pageRows[0]));
    }
  }, [activeTxnKey, pageRows]);

  const activeFilterCount = [categoryQuery, metadataQuery, searchQuery].filter((value) => Boolean(value?.trim())).length;
  const hasFilters = activeFilterCount > 0;
  const clearFilters = () => {
    setCategoryQuery?.("");
    setMetadataQuery?.("");
    setSearchQuery?.("");
  };
  const applyFilterView = (filters: TransactionFilterSnapshot) => {
    setCategoryQuery?.(filters.categoryQuery);
    setMetadataQuery?.(filters.metadataQuery);
    setSearchQuery?.(filters.searchQuery);
    setMatchMode?.(filters.matchMode);
    setViewMode?.(filters.viewMode);
  };
  const restoreFilterView = (view: StoredFilterView) => {
    const now = Date.now();
    applyFilterView(view.filters);
    setFilterViews((views) => ({
      saved: views.saved.map((item) => item.id === view.id ? { ...item, lastUsedAt: now } : item),
      recent: views.recent.map((item) => item.id === view.id ? { ...item, lastUsedAt: now } : item),
    }));
  };
  const saveCurrentFilterView = () => {
    if (!hasFilterSnapshot(immediateFilterSnapshot)) return;
    setFilterViews((views) => saveNamedFilterView(views, immediateFilterSnapshot));
    showToast?.("success", "当前筛选已保存");
  };
  const filterViewOptions = [
    ...filterViews.saved.map((view) => ({ value: `saved:${view.id}`, label: `已保存 · ${view.name}`, view })),
    ...filterViews.recent.map((view) => ({ value: `recent:${view.id}`, label: `最近 · ${view.name}`, view })),
  ];
  const selectedMatches = (txn: Txn) => {
    const key = transactionKey(txn);
    return activeTxnKey === key || Boolean(selected && transactionKey(selected) === key);
  };
  const desktopRowId = (txn: Txn) => `transaction-row-${transactionKey(txn).replace(/[^a-z0-9_-]+/gi, "-")}`;
  const setDesktopRowRef = (key: string) => (node: HTMLButtonElement | null) => {
    if (node) desktopRowRefs.current.set(key, node);
    else desktopRowRefs.current.delete(key);
  };
  const focusDesktopRow = (key: string) => {
    window.requestAnimationFrame(() => desktopRowRefs.current.get(key)?.focus());
  };
  const handleDesktopListKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (isKeyboardInputTarget(event.target) || pageRows.length === 0) return;
    const activeIndex = activeTxnKey ? pageRows.findIndex((txn) => transactionKey(txn) === activeTxnKey) : -1;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const direction = event.key === "ArrowDown" ? 1 : -1;
      const currentIndex = activeIndex >= 0 ? activeIndex : 0;
      const nextIndex = Math.min(pageRows.length - 1, Math.max(0, currentIndex + direction));
      const nextKey = transactionKey(pageRows[nextIndex]);
      setActiveTxnKey(nextKey);
      focusDesktopRow(nextKey);
      return;
    }
    if (event.key === "Enter") {
      const targetIndex = activeIndex >= 0 ? activeIndex : 0;
      const txn = pageRows[targetIndex];
      if (!txn) return;
      event.preventDefault();
      setActiveTxnKey(transactionKey(txn));
      setSelected(txn);
    }
  };
  const pager = rows.length > 0 && <TransactionPager safePage={safePage} totalPages={totalPages} rowsLength={rows.length} pageSize={pageSize} setPageSize={setPageSize} setPage={setPage} />;
  const renderFilterControls = (idPrefix: string) => (
    <>
      <div className="grid gap-3 xl:grid-cols-[minmax(260px,1fr)_minmax(180px,260px)_minmax(180px,260px)]">
        {setSearchQuery && <Input id={idPrefix === "desktop" ? "transaction-search-input" : `${idPrefix}-transaction-search-input`} className="h-10 rounded-xl bg-paper text-sm" placeholder="搜索商户、说明、账户、metadata" value={searchQuery ?? ""} onChange={(e) => setSearchQuery(e.target.value)} />}
        {setCategoryQuery && (
          <Select value={categories.includes(categoryQuery ?? "") ? categoryQuery : ALL_FILTER_VALUE} onValueChange={(value) => setCategoryQuery(value === ALL_FILTER_VALUE ? "" : value)}>
            <SelectTrigger className="h-10 w-full rounded-xl bg-paper text-sm">
              <SelectValue placeholder="全部分类" />
            </SelectTrigger>
            <SelectContent className="max-h-80">
              <SelectItem value={ALL_FILTER_VALUE}>全部分类</SelectItem>
              {categories.map((category) => <SelectItem key={category} value={category}>{accountOptionLabel(category)}</SelectItem>)}
            </SelectContent>
          </Select>
        )}
        {setMetadataQuery && (
          <Select value={metadataOptions.includes(metadataQuery ?? "") ? metadataQuery : ALL_FILTER_VALUE} onValueChange={(value) => setMetadataQuery(value === ALL_FILTER_VALUE ? "" : value)}>
            <SelectTrigger className="h-10 w-full rounded-xl bg-paper text-sm">
              <SelectValue placeholder="全部 metadata" />
            </SelectTrigger>
            <SelectContent className="max-h-80">
              <SelectItem value={ALL_FILTER_VALUE}>全部 metadata</SelectItem>
              {metadataOptions.map((item) => <SelectItem key={item} value={item}>{item}</SelectItem>)}
            </SelectContent>
          </Select>
        )}
      </div>
      <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2 text-xs text-stone">
          <span className="rounded-full bg-tag px-2 py-1">{rows.length} / {txns.length} 笔</span>
          {setCategoryQuery && <Input list={`${idPrefix}-txn-category-options`} className="h-8 w-full rounded-xl bg-paper text-xs sm:w-60" placeholder="手动分类前缀，如 Expenses:Food" value={categoryQuery ?? ""} onChange={(e) => setCategoryQuery(e.target.value)} />}
          <datalist id={`${idPrefix}-txn-category-options`}>{categories.map((category) => <option key={category} value={category} label={accountOptionLabel(category)} />)}</datalist>
          {setMetadataQuery && <Input list={`${idPrefix}-txn-metadata-options`} className="h-8 w-full rounded-xl bg-paper text-xs sm:w-64" placeholder="metadata/tag，如 person:妈妈 #trip" value={metadataQuery ?? ""} onChange={(e) => setMetadataQuery(e.target.value)} />}
          <datalist id={`${idPrefix}-txn-metadata-options`}>{metadataOptions.map((item) => <option key={item} value={item} />)}</datalist>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {filterViewOptions.length > 0 && (
            <Select value={ALL_FILTER_VALUE} onValueChange={(value) => {
              const option = filterViewOptions.find((item) => item.value === value);
              if (option) restoreFilterView(option.view);
            }}>
              <SelectTrigger className="h-8 w-[180px] rounded-xl bg-paper text-xs">
                <SelectValue placeholder="恢复视图" />
              </SelectTrigger>
              <SelectContent className="max-h-80">
                <SelectItem value={ALL_FILTER_VALUE}>恢复视图</SelectItem>
                {filterViewOptions.map((item) => <SelectItem key={item.value} value={item.value}>{item.label}</SelectItem>)}
              </SelectContent>
            </Select>
          )}
          {hasFilters && <Button type="button" variant="outline" size="xs" className="rounded-xl bg-paper text-stone" onClick={saveCurrentFilterView}>保存当前</Button>}
          {setViewMode && <div className="flex overflow-hidden rounded-lg border border-line">
            <button type="button" className={`px-2 py-1 text-xs transition-colors ${viewMode === "compact" ? "bg-brand text-paper" : "bg-paper text-warm hover:bg-tag"}`} onClick={() => setViewMode("compact")}>简洁</button>
            <button type="button" className={`px-2 py-1 text-xs transition-colors ${viewMode === "full" ? "bg-brand text-paper" : "bg-paper text-warm hover:bg-tag"}`} onClick={() => setViewMode("full")}>完整</button>
          </div>}
          {setCategoryQuery && setMatchMode && categoryQuery && query && <div className="flex overflow-hidden rounded-lg border border-line">
            <button type="button" className={`px-2 py-1 text-xs transition-colors ${matchMode === "prefix" ? "bg-brand text-paper" : "bg-paper text-warm hover:bg-tag"}`} onClick={() => setMatchMode("prefix")}>前缀</button>
            <button type="button" className={`px-2 py-1 text-xs transition-colors ${matchMode === "exact" ? "bg-brand text-paper" : "bg-paper text-warm hover:bg-tag"}`} onClick={() => setMatchMode("exact")}>精确</button>
          </div>}
          {hasFilters && <Button type="button" variant="outline" size="xs" className="rounded-xl bg-paper text-stone" onClick={clearFilters}>清空筛选</Button>}
        </div>
      </div>
    </>
  );

  return <section className="mt-6">
    <div className="min-w-0">
      {searchable && (
        <>
          <div className="mb-3 flex items-center gap-2 lg:hidden">
            <Button type="button" variant="outline" className="flex-1 rounded-xl bg-panel text-warm shadow-sm" onClick={() => setMobileFiltersOpen(true)}>
              <SlidersHorizontal className="h-4 w-4 text-brand" />
              筛选{activeFilterCount ? ` · ${activeFilterCount}` : ""}
            </Button>
            {hasFilters && <Button type="button" variant="outline" className="rounded-xl bg-paper text-stone" onClick={clearFilters}>清空</Button>}
          </div>
          <div className="mb-3 flex items-center justify-between gap-3 text-xs text-stone lg:hidden">
            <span className="rounded-full bg-tag px-2 py-1">{rows.length} / {txns.length} 笔</span>
            {hasFilters && <span className="truncate text-right">已应用筛选</span>}
          </div>
          <div className="mb-4 hidden rounded-2xl border border-line bg-panel p-3 shadow-sm lg:block">
            {renderFilterControls("desktop")}
          </div>
        </>
      )}

      {rows.length === 0 && <div className="card p-6 text-center text-sm text-stone">没有匹配的流水，换个分类关键词试试。</div>}

      {searchable && rows.length > 0 ? (
        <>
          <div
            className="hidden overflow-hidden rounded-2xl border border-line bg-panel shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2 focus-visible:ring-offset-paper lg:block"
            tabIndex={0}
            role="grid"
            aria-label="交易流水"
            aria-activedescendant={activeTxnKey ? desktopRowId(pageRows.find((txn) => transactionKey(txn) === activeTxnKey) ?? pageRows[0]) : undefined}
            onKeyDown={handleDesktopListKeyDown}
          >
            <div className="grid grid-cols-[84px_minmax(280px,1.2fr)_140px_minmax(260px,1fr)_minmax(180px,0.75fr)] gap-4 border-b border-line bg-paper px-4 py-2.5 text-xs font-semibold uppercase tracking-[0.08em] text-olive">
              <span>日期</span>
              <span>交易</span>
              <span className="text-right">金额</span>
              <span>分类 / 账户</span>
              <span>标签</span>
            </div>
            <div className="divide-y divide-line">
              {pageRows.map((txn) => {
                const key = transactionKey(txn);
                return (
                  <TransactionTableRow
                    key={key}
                    rowId={desktopRowId(txn)}
                    rowRef={setDesktopRowRef(key)}
                    txn={txn}
                    selected={Boolean(selectedMatches(txn))}
                    viewMode={viewMode}
                    onSelect={() => {
                      setActiveTxnKey(key);
                      setSelected(txn);
                    }}
                  />
                );
              })}
            </div>
          </div>
          <div className="lg:hidden">
            {pageRows.map((txn) => {
              const key = transactionKey(txn);
              return <TransactionCard key={key} txn={txn} selected={Boolean(selectedMatches(txn))} viewMode={viewMode} onSelect={() => { setActiveTxnKey(key); setSelected(txn); }} />;
            })}
          </div>
        </>
      ) : (
        pageRows.map((txn) => {
          const key = transactionKey(txn);
          return <TransactionCard key={key} txn={txn} selected={Boolean(selectedMatches(txn))} viewMode={viewMode} onSelect={() => { setActiveTxnKey(key); setSelected(txn); }} />;
        })
      )}

      {pager}
    </div>
    {searchable && <MobileSheet open={mobileFiltersOpen} title="筛选流水" onClose={() => setMobileFiltersOpen(false)} footer={<div className="grid grid-cols-2 gap-2"><Button type="button" variant="outline" className="h-11 bg-panel" onClick={clearFilters} disabled={!hasFilters}>清空筛选</Button><Button type="button" className="h-11" onClick={() => setMobileFiltersOpen(false)}>完成</Button></div>}>{renderFilterControls("mobile")}</MobileSheet>}
    {selected && <TransactionDrawer key={`${selected.source.file}:${selected.source.line}:sheet`} txn={selected} accounts={accounts} onClose={() => setSelected(null)} onUpdate={onUpdate} onDelete={(source, reason) => { onDelete?.(source, reason); setSelected(null); }} onReverse={(source, date) => { onReverse?.(source, date); setSelected(null); }} />}
  </section>;
}

function TransactionPager({ safePage, totalPages, rowsLength, pageSize, setPageSize, setPage }: { safePage: number; totalPages: number; rowsLength: number; pageSize: number; setPageSize: (value: number) => void; setPage: React.Dispatch<React.SetStateAction<number>> }) {
  return <div className="mt-4 flex flex-col gap-3 rounded-xl border border-line bg-panel p-3 text-sm sm:flex-row sm:items-center sm:justify-between">
    <div className="text-stone">第 {safePage} / {totalPages} 页，显示 {(safePage - 1) * pageSize + 1}-{Math.min(safePage * pageSize, rowsLength)} 条</div>
    <div className="flex items-center gap-2">
      <Select value={String(pageSize)} onValueChange={(value) => setPageSize(Number(value))}>
        <SelectTrigger className="h-9 w-[112px] rounded-xl bg-panel">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="10">10 条/页</SelectItem>
          <SelectItem value="20">20 条/页</SelectItem>
          <SelectItem value="50">50 条/页</SelectItem>
          <SelectItem value="100">100 条/页</SelectItem>
        </SelectContent>
      </Select>
      <Button variant="outline" className="rounded-xl" disabled={safePage <= 1} onClick={() => setPage((value) => Math.max(1, value - 1))}>上一页</Button>
      <Button variant="outline" className="rounded-xl" disabled={safePage >= totalPages} onClick={() => setPage((value) => Math.min(totalPages, value + 1))}>下一页</Button>
    </div>
  </div>;
}

type TransactionDrawerProps = {
  txn: Txn;
  accounts: AccountView[];
  onClose: () => void;
  onUpdate?: (source: Txn["source"], entry: ParsedTransaction) => void;
  onDelete?: (source: Txn["source"], reason: string) => void;
  onReverse?: (source: Txn["source"], date: string) => void;
};

type PendingTransactionAction =
  | { kind: "delete"; reason: string }
  | { kind: "reverse"; date: string };

type EditablePosting = {
  account: string;
  amount: string;
  currency: string;
};

function toEditablePostings(postings: Txn["postings"]): EditablePosting[] {
  return postings.map((p) => ({ account: p.account, amount: (p.amount / 100).toFixed(2), currency: p.currency ?? "CNY" }));
}

function TransactionDrawer({ txn, accounts, onClose, onUpdate, onDelete, onReverse }: TransactionDrawerProps) {
  const [editing, setEditing] = useState(false);
  const [date, setDate] = useState(txn.date);
  const [payee, setPayee] = useState(txn.payee);
  const [narration, setNarration] = useState(txn.narration);
  const [postings, setPostings] = useState<EditablePosting[]>(() => toEditablePostings(txn.postings));
  const [metadata, setMetadata] = useState(() => JSON.stringify(txn.metadata ?? {}, null, 2));
  const [tags, setTags] = useState(() => (txn.tags ?? []).join(" "));
  const [formError, setFormError] = useState<string | null>(null);
  const [pendingAction, setPendingAction] = useState<PendingTransactionAction | null>(null);
  const [discardDialogOpen, setDiscardDialogOpen] = useState(false);
  const accountOptions = useMemo(() => accounts.filter((account) => account.active || postings.some((posting) => posting.account === account.account)), [accounts, postings]);
  const optionLabel = (account: AccountView) => formatAccountOptionLabel(account);
  const reverseDate = new Date().toISOString().slice(0, 10);
  const primary = primaryPosting(txn);
  const pending = pendingLabel(txn);
  const pendingAppend = txn.pending?.kind === "append";
  const resetForm = () => {
    setDate(txn.date);
    setPayee(txn.payee);
    setNarration(txn.narration);
    setPostings(toEditablePostings(txn.postings));
    setMetadata(JSON.stringify(txn.metadata ?? {}, null, 2));
    setTags((txn.tags ?? []).join(" "));
    setFormError(null);
  };
  const hasUnsavedChanges = editing && (
    date !== txn.date ||
    payee !== txn.payee ||
    narration !== txn.narration ||
    metadata !== JSON.stringify(txn.metadata ?? {}, null, 2) ||
    tags !== (txn.tags ?? []).join(" ") ||
    postings.length !== txn.postings.length ||
    postings.some((posting, index) => posting.account !== txn.postings[index]?.account || posting.amount !== ((txn.postings[index]?.amount ?? 0) / 100).toFixed(2) || posting.currency !== (txn.postings[index]?.currency ?? "CNY"))
  );
  const shouldClose = () => {
    if (!hasUnsavedChanges) return true;
    setDiscardDialogOpen(true);
    return false;
  };
  function save() {
    setFormError(null);
    let parsedMetadata: Record<string, MetadataValue> = {};
    try {
      parsedMetadata = metadata.trim() ? JSON.parse(metadata) : {};
    } catch {
      setFormError("metadata 必须是合法 JSON 对象");
      return;
    }
    if (!parsedMetadata || Array.isArray(parsedMetadata) || typeof parsedMetadata !== "object") {
      setFormError("metadata 必须是 JSON 对象");
      return;
    }
    const cleanedPostings = postings.map((p) => ({ account: p.account.trim(), amount: p.amount.trim(), currency: p.currency.trim().toUpperCase() || "CNY" }));
    if (cleanedPostings.length < 2) {
      setFormError("资金流向至少需要 2 行");
      return;
    }
    if (cleanedPostings.some((p) => !p.account)) {
      setFormError("每条资金流向都需要账户");
      return;
    }
    if (cleanedPostings.some((p) => !p.amount || Number.isNaN(Number(p.amount)))) {
      setFormError("每条资金流向都需要有效金额");
      return;
    }
    onUpdate?.(txn.source, { kind: "transaction", date, payee, narration, metadata: parsedMetadata, tags: tags.split(/\s+/).map((tag) => tag.replace(/^#/, "")).filter(Boolean), confidence: 1, needsReview: false, questions: [], postings: cleanedPostings });
    setEditing(false);
    onClose();
  }

  const footer = pendingAppend ? <div className="rounded-xl border border-line bg-panel px-4 py-3 text-sm leading-6 text-olive">
    这笔交易还在本地待同步，落账后可编辑、删除或冲销。
  </div> : editing ? <div className="grid grid-cols-2 gap-2">
    <Button variant="outline" className="h-11 bg-panel" onClick={() => { resetForm(); setEditing(false); }}>取消</Button>
    <Button className="h-11" onClick={save}>保存修改</Button>
  </div> : <div className="grid gap-2 sm:grid-cols-3">
    <Button variant="outline" className="h-11 bg-panel" onClick={() => setEditing(true)}>编辑</Button>
    <Button variant="outline" className="h-11 border-destructive/40 text-destructive hover:bg-destructive/10 hover:text-destructive" onClick={() => setPendingAction({ kind: "delete", reason: "记错/重复记账" })}>注释删除</Button>
    <Button className="h-11" onClick={() => setPendingAction({ kind: "reverse", date: reverseDate })}>冲销</Button>
  </div>;

  const body = <>
    <div className="mb-4 flex min-w-0 flex-wrap items-center gap-2 text-xs text-stone">
      <span className="min-w-0 [overflow-wrap:anywhere]">{sourceLabel(txn)}</span>
      {pending && <span className="shrink-0 rounded-full bg-brand/10 px-2 py-0.5 text-brand">{pending}</span>}
    </div>
    {editing ? <div className="grid min-w-0 gap-4">
      {formError && <Alert variant="destructive"><AlertDescription>{formError}</AlertDescription></Alert>}
      <section className="grid min-w-0 gap-3 rounded-2xl border border-line bg-panel/60 p-3 sm:grid-cols-[10rem_minmax(0,1fr)]">
        <label className="grid gap-1 text-xs text-stone">
          <span>日期</span>
          <Input className="h-11 bg-panel" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
        </label>
        <label className="grid min-w-0 gap-1 text-xs text-stone">
          <span>交易对象</span>
          <Input className="h-11 min-w-0 bg-panel" value={payee} onChange={(e) => setPayee(e.target.value)} />
        </label>
        <label className="grid min-w-0 gap-1 text-xs text-stone sm:col-span-2">
          <span>摘要</span>
          <Input className="h-11 min-w-0 bg-panel" value={narration} onChange={(e) => setNarration(e.target.value)} />
        </label>
      </section>

      <section className="@container min-w-0 rounded-2xl border border-line bg-panel/60 p-3">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h3 className="font-medium text-warm">资金流向</h3>
            <p className="mt-0.5 text-xs text-stone">每一行对应一条 Beancount posting，可继续添加参与账户。</p>
          </div>
          <Button
            type="button"
            variant="outline"
            className="h-9 shrink-0 rounded-xl bg-panel px-3 text-sm"
            onClick={() => setPostings((rows) => [...rows, { account: "", amount: "", currency: rows.at(-1)?.currency || "CNY" }])}
          >
            <Plus className="h-4 w-4" />
            <span>添加</span>
          </Button>
        </div>
        <div className="mt-3 grid min-w-0 gap-3">
          {postings.map((p, i) => <div key={i} className="grid min-w-0 gap-2 rounded-xl border border-line bg-paper p-3 @lg:grid-cols-[minmax(0,1fr)_minmax(7.5rem,9rem)_5.5rem_2.75rem]">
            <div className="min-w-0">
              <div className="mb-1 flex items-center justify-between gap-2 text-xs text-stone">
                <span>账户 {i + 1}</span>
                <span className="shrink-0">{p.account ? shortAccount(p.account) : "未选择"}</span>
              </div>
              <Select value={accountOptions.some((account) => account.account === p.account) ? p.account : ALL_FILTER_VALUE} onValueChange={(value) => value !== ALL_FILTER_VALUE && setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, account: value } : row))}>
                <SelectTrigger className="h-10 w-full min-w-0 bg-panel">
                  <SelectValue placeholder="选择账户 / 分类" />
                </SelectTrigger>
                <SelectContent className="max-h-80">
                  <SelectItem value={ALL_FILTER_VALUE}>选择账户 / 分类</SelectItem>
                  {accountOptions.map((account) => <SelectItem key={account.account} value={account.account}>{optionLabel(account)}</SelectItem>)}
                </SelectContent>
              </Select>
              <Input list={`txn-account-options-${i}`} className="mt-2 h-10 min-w-0 bg-panel text-sm" value={p.account} placeholder="或手动输入账户" onChange={(e) => setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, account: e.target.value } : row))} />
              <datalist id={`txn-account-options-${i}`}>{accountOptions.map((account) => <option key={account.account} value={account.account} label={optionLabel(account)} />)}</datalist>
            </div>
            <label className="grid gap-1 text-xs text-stone">
              <span>金额</span>
              <Input className="h-10 bg-panel text-right tabular-nums" inputMode="decimal" value={p.amount} onChange={(e) => setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, amount: e.target.value } : row))} />
            </label>
            <label className="grid gap-1 text-xs text-stone">
              <span>币种</span>
              <Input className="h-10 bg-panel uppercase" value={p.currency} onChange={(e) => setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, currency: e.target.value.toUpperCase() } : row))} />
            </label>
            <Button
              type="button"
              variant="outline"
              className="h-10 self-end rounded-xl bg-panel px-0 text-stone hover:text-destructive"
              disabled={postings.length <= 2}
              title={postings.length <= 2 ? "至少保留 2 条资金流向" : "删除这条资金流向"}
              onClick={() => setPostings((rows) => rows.filter((_, idx) => idx !== i))}
            >
              <Trash2 className="h-4 w-4" />
            </Button>
          </div>)}
        </div>
      </section>

      <section className="grid min-w-0 gap-3 rounded-2xl border border-line bg-panel/60 p-3">
        <label className="grid min-w-0 gap-1 text-xs text-stone">
          <span>标签</span>
          <Input className="h-11 min-w-0 bg-panel" value={tags} onChange={(e) => setTags(e.target.value)} placeholder="tags，用空格分隔，不需要 #" />
        </label>
        <label className="grid min-w-0 gap-1 text-xs text-stone">
          <span>Metadata</span>
          <Textarea className="min-h-36 min-w-0 bg-panel font-mono text-xs" value={metadata} onChange={(e) => setMetadata(e.target.value)} placeholder={'{"platform":"taobao","channel":"online"}'} />
        </label>
      </section>
    </div> : <div className="grid min-w-0 gap-4">
      <section className="@container min-w-0 rounded-2xl border border-line bg-panel/70 p-4">
        <div className="flex min-w-0 flex-col gap-3 @sm:flex-row @sm:items-start @sm:justify-between">
          <div className="min-w-0">
            <div className="text-xs text-stone">{txn.date}</div>
            <div className="mt-1 text-lg font-medium text-warm [overflow-wrap:anywhere]">{txn.payee || "无收付款方"}</div>
            <div className="mt-1 text-sm text-olive [overflow-wrap:anywhere]">{txn.narration || "无摘要"}</div>
            <MetadataBadges txn={txn} />
          </div>
          {primary && <div className="min-w-0 rounded-xl border border-line bg-paper px-3 py-2 text-left @sm:shrink-0 @sm:text-right">
            <div className="text-[11px] text-stone">主金额</div>
            <div className={`mt-0.5 truncate text-lg font-semibold ${amountColor(primary.amount)}`} title={fmtTxnAmount(primary.amount, primary.currency)}>{fmtTxnAmount(primary.amount, primary.currency)}</div>
          </div>}
        </div>
      </section>

      <section className="@container min-w-0 rounded-2xl border border-line bg-panel/70 p-4">
        <div className="flex items-center justify-between gap-3">
          <h3 className="font-medium text-warm">资金流向</h3>
          <span className="rounded-full bg-tag px-2 py-0.5 text-xs text-stone">{txn.postings.length} 条</span>
        </div>
        <div className="mt-3 grid min-w-0 gap-2">{txn.postings.map((p, i) => <div key={`${p.account}-${i}`} className="grid min-w-0 gap-2 rounded-xl border border-line bg-paper p-3 @sm:grid-cols-[minmax(0,1fr)_auto] @sm:items-center">
          <div className="min-w-0">
            <div className="text-xs text-stone">#{i + 1} {shortAccount(p.account)}</div>
            <div className="mt-0.5 text-sm text-warm [overflow-wrap:anywhere]">{p.account}</div>
          </div>
          <strong className={`min-w-0 truncate text-left text-sm tabular-nums @sm:text-right ${amountColor(p.amount)}`} title={fmtPostingAmount(p.amount, p.currency)}>{fmtPostingAmount(p.amount, p.currency)}</strong>
        </div>)}</div>
      </section>
    </div>}
  </>;

  const confirmPendingAction = () => {
    if (!pendingAction) return;
    if (pendingAction.kind === "delete") {
      onDelete?.(txn.source, pendingAction.reason.trim() || "记错/重复记账");
    } else {
      onReverse?.(txn.source, pendingAction.date || reverseDate);
    }
    setPendingAction(null);
  };

  return <>
    <MobileSheet open title="流水详情" onClose={onClose} shouldClose={shouldClose} footer={footer} size="xl" panelClassName="sm:max-w-3xl" bodyClassName="overflow-x-hidden">{body}</MobileSheet>
    <AlertDialog open={Boolean(pendingAction)} onOpenChange={(open) => !open && setPendingAction(null)}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{pendingAction?.kind === "delete" ? "注释删除这笔交易？" : "生成冲销交易？"}</AlertDialogTitle>
          <AlertDialogDescription>
            {pendingAction?.kind === "delete" ? "原交易会保留在账本中并被注释，不会物理删除。" : "将基于当前交易生成一笔反向冲销记录。"}
          </AlertDialogDescription>
        </AlertDialogHeader>
        {pendingAction?.kind === "delete" && (
          <div className="grid gap-2">
            <label className="text-sm font-medium text-warm" htmlFor="delete-reason">删除原因</label>
            <Input id="delete-reason" value={pendingAction.reason} onChange={(event) => setPendingAction({ kind: "delete", reason: event.target.value })} />
          </div>
        )}
        {pendingAction?.kind === "reverse" && (
          <div className="grid gap-2">
            <label className="text-sm font-medium text-warm" htmlFor="reverse-date">冲销日期</label>
            <Input id="reverse-date" type="date" value={pendingAction.date} onChange={(event) => setPendingAction({ kind: "reverse", date: event.target.value })} />
          </div>
        )}
        <AlertDialogFooter>
          <AlertDialogCancel>取消</AlertDialogCancel>
          <AlertDialogAction className={pendingAction?.kind === "delete" ? "bg-destructive text-white hover:bg-destructive/90" : undefined} onClick={confirmPendingAction}>
            {pendingAction?.kind === "delete" ? "确认注释删除" : "确认冲销"}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
    <AlertDialog open={discardDialogOpen} onOpenChange={setDiscardDialogOpen}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>放弃未保存修改？</AlertDialogTitle>
          <AlertDialogDescription>当前编辑内容还没有保存，关闭后会丢失这些改动。</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>继续编辑</AlertDialogCancel>
          <AlertDialogAction onClick={() => { setDiscardDialogOpen(false); onClose(); }}>放弃修改</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  </>;
}
