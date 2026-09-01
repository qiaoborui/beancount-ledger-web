import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { Plus, SlidersHorizontal, Tag, Trash2 } from "lucide-react";
import { formatMoney } from "@/lib/money";
import i18n from "@/i18n";
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
import { Checkbox } from "@/components/ui/checkbox";
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
    filters.searchQuery.trim() && i18n.t("transactionList.filterSearchLabel", { query: filters.searchQuery.trim() }),
    filters.categoryQuery.trim() && i18n.t("transactionList.filterCategoryLabel", { query: filters.categoryQuery.trim(), mode: filters.matchMode === "exact" ? i18n.t("transactionList.exact") : i18n.t("transactionList.prefix") }),
    filters.metadataQuery.trim() && i18n.t("transactionList.filterMetadataLabel", { query: filters.metadataQuery.trim() }),
    filters.viewMode === "full" && i18n.t("transactionList.fullViewLabel"),
  ].filter(Boolean);
  return parts.join(" · ") || i18n.t("transactionList.allTransactions");
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
  return txn.pending.kind === "append" ? i18n.t("transactionList.pendingAppend") : i18n.t("transactionList.pendingUpdate");
}

function sourceLabel(txn: Txn) {
  if (txn.pending?.kind === "append") return i18n.t("transactionList.localPending");
  return `${txn.source.file}:${txn.source.line}`;
}

/** 从 account 路径中提取简短名称（最后一个冒号后的部分） */
function shortAccount(account: string): string {
  const idx = account.lastIndexOf(":");
  return idx >= 0 ? account.slice(idx + 1) : account;
}

export type TransactionDisplayAmount = {
  account: string;
  amount: number;
  currency: string;
  direction: "outflow" | "inflow" | "transfer";
};

export function transactionDisplayAmount(txn: Txn, accounts: AccountView[] = []): TransactionDisplayAmount | null {
  const groupByAccount = new Map(accounts.map((account) => [account.account, account.group]));
  const categories = txn.postings.filter((posting) => posting.account.startsWith("Expenses:") || posting.account.startsWith("Income:"));
  const financial = txn.postings.filter((posting) => posting.account.startsWith("Assets:") || posting.account.startsWith("Liabilities:"));
  const settlement = financial.filter((posting) => {
    const group = groupByAccount.get(posting.account);
    return group === "cash" || group === "credit" || group === "liability" || group === "receivable";
  });
  const touchesWealth = financial.some((posting) => groupByAccount.get(posting.account) === "wealth");
  const complex = categories.length > 1 || touchesWealth;

  if (!complex && categories.length === 1) {
    const posting = categories[0];
    return {
      account: posting.account,
      amount: Math.abs(posting.amount),
      currency: posting.currency ?? "CNY",
      direction: posting.amount > 0 ? "outflow" : "inflow",
    };
  }

  const settlementPosting = [...settlement].sort((a, b) => Math.abs(b.amount) - Math.abs(a.amount))[0];
  if (settlementPosting) {
    const isAsset = settlementPosting.account.startsWith("Assets:");
    const expenseTotal = categories.filter((posting) => posting.account.startsWith("Expenses:")).reduce((sum, posting) => sum + posting.amount, 0);
    const incomeTotal = categories.filter((posting) => posting.account.startsWith("Income:")).reduce((sum, posting) => sum + posting.amount, 0);
    const direction = categories.length === 0
      ? "transfer"
      : isAsset
      ? settlementPosting.amount > 0 ? "inflow" : "outflow"
      : expenseTotal > 0 ? "outflow" : incomeTotal < 0 ? "inflow" : "transfer";
    return {
      account: settlementPosting.account,
      amount: Math.abs(settlementPosting.amount),
      currency: settlementPosting.currency ?? "CNY",
      direction,
    };
  }

  if (categories.length) {
    const posting = [...categories].sort((a, b) => Math.abs(b.amount) - Math.abs(a.amount))[0];
    const sameCurrency = categories.every((candidate) => (candidate.currency ?? "CNY") === (posting.currency ?? "CNY"));
    const amount = sameCurrency ? categories.reduce((sum, candidate) => sum + candidate.amount, 0) : posting.amount;
    return {
      account: posting.account,
      amount: Math.abs(amount),
      currency: posting.currency ?? "CNY",
      direction: amount > 0 ? "outflow" : "inflow",
    };
  }

  const posting = [...financial].sort((a, b) => Math.abs(b.amount) - Math.abs(a.amount))[0] ?? txn.postings[0];
  if (!posting) return null;
  return {
    account: posting.account,
    amount: Math.abs(posting.amount),
    currency: posting.currency ?? "CNY",
    direction: "transfer",
  };
}

/** 金额颜色：支出(借方)=expense红，收入(贷方)=income绿，零或其他=品牌色 */
function amountColor(amount: number): string {
  if (amount > 0) return "amount-expense";
  if (amount < 0) return "amount-income";
  return "amount-gold";
}

function transactionAmountColor(display: TransactionDisplayAmount): string {
  if (display.direction === "outflow") return "amount-expense";
  if (display.direction === "inflow") return "amount-income";
  return "amount-gold";
}

function fmtTxnAmount(display: TransactionDisplayAmount): string {
  const sign = display.direction === "outflow" ? "-" : display.direction === "inflow" ? "+" : "";
  return `${sign}${formatMoney(display.amount / 100, display.currency)}`;
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

const MemoTransactionCard = memo(function TransactionCard({ txn, accounts, selected, bulkSelected, bulkDisabled, viewMode, onSelect, onToggleBulk }: { txn: Txn; accounts: AccountView[]; selected: boolean; bulkSelected: boolean; bulkDisabled: boolean; viewMode?: "compact" | "full"; onSelect: (key: string, txn: Txn) => void; onToggleBulk: (txn: Txn, checked: boolean) => void }) {
  const { t } = useTranslation();
  const displayAmount = transactionDisplayAmount(txn, accounts);
  const pending = pendingLabel(txn);
  return (
    <article className={`transaction-list-card card relative mb-2 min-w-0 overflow-hidden ${selected ? "border-brand bg-[var(--selected-bg)]" : ""}`}>
      <div className="absolute left-3 top-4 z-10 grid h-8 w-8 place-items-center">
        <Checkbox className="relative after:absolute after:-inset-3" checked={bulkSelected} disabled={bulkDisabled} onCheckedChange={(checked) => onToggleBulk(txn, checked === true)} aria-label={i18n.t("transactionList.selectForBulkTags", { payee: txn.payee || txn.narration })} />
      </div>
      <button type="button" className="block w-full min-w-0 p-4 pl-14 text-left" onClick={() => onSelect(transactionKey(txn), txn)}>
      <ResponsiveValueRow
        label={<div className="min-w-0">
          <strong className="block truncate text-[15px] leading-5 text-ink">{txn.payee}</strong>
          {pending && <span className="mt-1 inline-block rounded-full bg-brand/10 px-2 py-0.5 text-[11px] text-brand">{pending}</span>}
        </div>}
        labelClassName="truncate"
        value={displayAmount ? fmtTxnAmount(displayAmount) : null}
        valueClassName={displayAmount ? `text-base font-semibold ${transactionAmountColor(displayAmount)}` : "hidden"}
        valueTitle={displayAmount ? fmtTxnAmount(displayAmount) : undefined}
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
    </article>
  );
});

const MemoTransactionTableRow = memo(function TransactionTableRow({ txn, accounts, selected, bulkSelected, bulkDisabled, viewMode, onSelect, onToggleBulk, rowRef, rowId }: { txn: Txn; accounts: AccountView[]; selected: boolean; bulkSelected: boolean; bulkDisabled: boolean; viewMode?: "compact" | "full"; onSelect: (key: string, txn: Txn) => void; onToggleBulk: (txn: Txn, checked: boolean) => void; rowRef?: (node: HTMLButtonElement | null) => void; rowId?: string }) {
  const { t } = useTranslation();
  const displayAmount = transactionDisplayAmount(txn, accounts);
  const categoryRows = categoryAccounts(txn);
  const paymentAccounts = txn.postings.filter((posting) => posting.account.startsWith("Assets:") || posting.account.startsWith("Liabilities:"));
  const meta = metadataPairs(txn);
  const pending = pendingLabel(txn);
  return (
    <div className={`grid grid-cols-[2.75rem_minmax(0,1fr)] items-stretch ${selected ? "bg-[var(--selected-bg)]" : "bg-transparent"}`} role="row">
      <div className="grid place-items-center" role="gridcell">
        <Checkbox className="relative after:absolute after:-inset-3" checked={bulkSelected} disabled={bulkDisabled} onCheckedChange={(checked) => onToggleBulk(txn, checked === true)} aria-label={i18n.t("transactionList.selectForBulkTags", { payee: txn.payee || txn.narration })} />
      </div>
      <button
        id={rowId}
        ref={rowRef}
        type="button"
        className="transaction-list-card grid w-full grid-cols-[72px_minmax(240px,1.15fr)_124px_minmax(220px,1fr)_minmax(150px,0.72fr)] items-center gap-3 px-3 py-2.5 text-left transition-colors hover:bg-tag focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand md:px-4"
        onClick={() => onSelect(transactionKey(txn), txn)}
      >
      <div className="text-xs font-medium tabular-nums text-stone">
        <div className="text-olive">{txn.date.slice(5)}</div>
        <div className="mt-1 text-[11px] text-stone/70">{txn.date.slice(0, 4)}</div>
      </div>
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <strong className="truncate text-sm leading-5 text-ink">{txn.payee}</strong>
          {pending && <span className="shrink-0 rounded-full bg-brand/10 px-2 py-0.5 text-[11px] text-brand">{pending}</span>}
        </div>
        <div className="mt-0.5 truncate text-xs leading-5 text-warm">{txn.narration || t("transactionList.noNarration")}</div>
        {viewMode === "full" && <PostingFlow postings={txn.postings} maxShow={4} />}
      </div>
      <div className={`text-right text-sm font-semibold tabular-nums ${displayAmount ? transactionAmountColor(displayAmount) : "text-stone"}`}>{displayAmount ? fmtTxnAmount(displayAmount) : "—"}</div>
      <div className="min-w-0">
        <div className="truncate text-xs font-medium text-warm">{categoryRows.join(" · ") || t("transactionList.uncategorized")}</div>
        <div className="mt-1 truncate text-[11px] text-stone">{paymentAccounts.map((posting) => shortAccount(posting.account)).join(" / ") || t("transactionList.noPaymentAccount")}</div>
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
    </div>
  );
});

export function TransactionList({ txns, accounts = [], searchable, categoryQuery, setCategoryQuery, metadataQuery, setMetadataQuery, searchQuery, setSearchQuery, serverFilteredSearch, serverSearchLoading, serverSearchError, matchMode, setMatchMode, viewMode, setViewMode, onUpdate, onDelete, onReverse, onAddTags, showToast }: { txns: Txn[]; accounts?: AccountView[]; searchable?: boolean; categoryQuery?: string; setCategoryQuery?: (value: string) => void; metadataQuery?: string; setMetadataQuery?: (value: string) => void; searchQuery?: string; setSearchQuery?: (value: string) => void; serverFilteredSearch?: boolean; serverSearchLoading?: boolean; serverSearchError?: string; matchMode?: "exact" | "prefix"; setMatchMode?: (mode: "exact" | "prefix") => void; viewMode?: "compact" | "full"; setViewMode?: (mode: "compact" | "full") => void; onUpdate?: (source: Txn["source"], entry: ParsedTransaction) => void; onDelete?: (source: Txn["source"], reason: string) => void; onReverse?: (source: Txn["source"], date: string) => void; onAddTags?: (sources: Txn["source"][], tags: string[]) => void; showToast?: (kind: "info" | "success" | "error", text: string) => void }) {
  const { t } = useTranslation();
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(20);
  const [selected, setSelected] = useState<Txn | null>(null);
  const [drawerTxn, setDrawerTxn] = useState<Txn | null>(null);
  const [activeTxnKey, setActiveTxnKey] = useState<string | null>(null);
  const [mobileFiltersOpen, setMobileFiltersOpen] = useState(false);
  const [filterViews, setFilterViews] = useState<StoredFilterViews>(() => loadFilterViews());
  const [bulkSelectedKeys, setBulkSelectedKeys] = useState<Set<string>>(new Set());
  const [bulkTagInput, setBulkTagInput] = useState("");
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
    searchQuery: serverFilteredSearch ? "" : debouncedSearchQuery.trim(),
    matchMode: matchMode ?? "prefix",
    viewMode: viewMode ?? "compact",
  }), [debouncedCategoryQuery, debouncedMetadataQuery, debouncedSearchQuery, serverFilteredSearch, matchMode, viewMode]);
  const rows = useMemo(() => filterTransactions(txns, currentFilterSnapshot), [txns, currentFilterSnapshot]);

  const totalPages = Math.max(1, Math.ceil(rows.length / pageSize));
  const safePage = Math.min(page, totalPages);
  const pageRows = rows.slice((safePage - 1) * pageSize, safePage * pageSize);
  const bulkEligibleRows = pageRows.filter((txn) => Boolean(txn.source.hash) && !txn.pending);
  const allPageRowsBulkSelected = bulkEligibleRows.length > 0 && bulkEligibleRows.every((txn) => bulkSelectedKeys.has(transactionKey(txn)));

  useEffect(() => { setPage(1); }, [debouncedCategoryQuery, debouncedSearchQuery, debouncedMetadataQuery, pageSize, txns.length, matchMode]);
  useEffect(() => { saveFilterViews(filterViews); }, [filterViews]);
  useEffect(() => {
    const available = new Set(txns.filter((txn) => txn.source.hash && !txn.pending).map(transactionKey));
    setBulkSelectedKeys((current) => new Set([...current].filter((key) => available.has(key))));
  }, [txns]);
  useEffect(() => {
    if (!searchable || !hasFilterSnapshot(currentFilterSnapshot)) return;
    setFilterViews((views) => upsertRecentFilterView(views, currentFilterSnapshot));
  }, [currentFilterSnapshot, searchable]);

  useEffect(() => {
    if (!pageRows.length) {
      setActiveTxnKey(null);
      return;
    }
    if (activeTxnKey && !pageRows.some((txn) => transactionKey(txn) === activeTxnKey)) {
      setActiveTxnKey(null);
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
    showToast?.("success", t("transactionList.savedFilterToast"));
  };
  const filterViewOptions = [
    ...filterViews.saved.map((view) => ({ value: `saved:${view.id}`, label: `${t("transactionList.savedPrefix", { name: view.name })}`, view })),
    ...filterViews.recent.map((view) => ({ value: `recent:${view.id}`, label: `${t("transactionList.recentPrefix", { name: view.name })}`, view })),
  ];
  const selectedMatches = (txn: Txn) => {
    const key = transactionKey(txn);
    return activeTxnKey === key || Boolean(selected && transactionKey(selected) === key);
  };
  const desktopRowId = (txn: Txn) => `transaction-row-${transactionKey(txn).replace(/[^a-z0-9_-]+/gi, "-")}`;
  const setDesktopRowRef = useCallback((key: string) => (node: HTMLButtonElement | null) => {
    if (node) desktopRowRefs.current.set(key, node);
    else desktopRowRefs.current.delete(key);
  }, []);
  const handleSelectRow = useCallback((key: string, txn: Txn) => {
    setActiveTxnKey(key);
    setSelected(txn);
  }, []);
  const handleSelectCard = useCallback((key: string, txn: Txn) => {
    setActiveTxnKey(key);
    setSelected(txn);
    setDrawerTxn(txn);
  }, []);
  const toggleBulkTransaction = useCallback((txn: Txn, checked: boolean) => {
    const key = transactionKey(txn);
    if (checked && bulkSelectedKeys.size >= 200) {
      showToast?.("info", t("transactionList.selectionLimit"));
      return;
    }
    setBulkSelectedKeys((current) => {
      const next = new Set(current);
      if (checked && next.size < 200) next.add(key);
      else if (!checked) next.delete(key);
      return next;
    });
  }, [bulkSelectedKeys.size, showToast, t]);
  const toggleCurrentPageBulk = (checked: boolean) => {
    setBulkSelectedKeys((current) => {
      const next = new Set(current);
      for (const txn of bulkEligibleRows) {
        const key = transactionKey(txn);
        if (!checked) next.delete(key);
        else if (next.size < 200) next.add(key);
      }
      return next;
    });
  };
  const applyBulkTags = () => {
    const tags = [...new Set(bulkTagInput.split(/[\s,]+/).map((tag) => tag.trim().replace(/^#+/, "")).filter(Boolean))];
    if (!bulkSelectedKeys.size) return showToast?.("info", t("transactionList.selectBeforeTagging"));
    if (!tags.length || tags.length > 50 || tags.some((tag) => tag.length > 64 || !/^[A-Za-z0-9_-]+$/.test(tag))) return showToast?.("error", t("transactionList.tagFormatError"));
    const selectedTxns = txns.filter((txn) => bulkSelectedKeys.has(transactionKey(txn)) && txn.source.hash && !txn.pending).slice(0, 200);
    if (!selectedTxns.length) return;
    onAddTags?.(selectedTxns.map((txn) => txn.source), tags);
    setBulkSelectedKeys(new Set());
    setBulkTagInput("");
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
      const nextIndex = activeIndex >= 0
        ? Math.min(pageRows.length - 1, Math.max(0, activeIndex + direction))
        : direction > 0 ? 0 : pageRows.length - 1;
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
        {setSearchQuery && <Input id={idPrefix === "desktop" ? "transaction-search-input" : `${idPrefix}-transaction-search-input`} className="h-9 rounded-md bg-paper text-sm" placeholder={t("transactionList.filterSearchPlaceholder")} value={searchQuery ?? ""} onChange={(e) => setSearchQuery(e.target.value)} />}
        {setCategoryQuery && (
          <Select value={categories.includes(categoryQuery ?? "") ? categoryQuery : ALL_FILTER_VALUE} onValueChange={(value) => setCategoryQuery(value === ALL_FILTER_VALUE ? "" : value)}>
            <SelectTrigger className="h-9 w-full rounded-md bg-paper text-sm">
              <SelectValue placeholder={t("transactionList.allCategories")} />
            </SelectTrigger>
            <SelectContent className="max-h-80">
              <SelectItem value={ALL_FILTER_VALUE}>{t("transactionList.allCategories")}</SelectItem>
              {categories.map((category) => <SelectItem key={category} value={category}>{accountOptionLabel(category)}</SelectItem>)}
            </SelectContent>
          </Select>
        )}
        {setMetadataQuery && (
          <Select value={metadataOptions.includes(metadataQuery ?? "") ? metadataQuery : ALL_FILTER_VALUE} onValueChange={(value) => setMetadataQuery(value === ALL_FILTER_VALUE ? "" : value)}>
            <SelectTrigger className="h-9 w-full rounded-md bg-paper text-sm">
              <SelectValue placeholder={t("transactionList.allMetadata")} />
            </SelectTrigger>
            <SelectContent className="max-h-80">
              <SelectItem value={ALL_FILTER_VALUE}>{t("transactionList.allMetadata")}</SelectItem>
              {metadataOptions.map((item) => <SelectItem key={item} value={item}>{item}</SelectItem>)}
            </SelectContent>
          </Select>
        )}
      </div>
      <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2 text-xs text-stone">
          <span className="rounded-md bg-tag px-2 py-1">{serverSearchLoading ? t("transactionList.searching") : t("transactionList.countLabel", { count: rows.length, total: txns.length })}</span>
          {serverFilteredSearch && <span className="rounded-md bg-brand/10 px-2 py-1 text-brand">{t("transactionList.backendQuery")}</span>}
          {serverSearchError && <span className="rounded-md bg-red-50 px-2 py-1 text-red-700">{serverSearchError}</span>}
          {setCategoryQuery && <Input list={`${idPrefix}-txn-category-options`} className="h-8 w-full rounded-md bg-paper text-xs sm:w-60" placeholder={t("transactionList.categoryPrefixPlaceholder")} value={categoryQuery ?? ""} onChange={(e) => setCategoryQuery(e.target.value)} />}
          <datalist id={`${idPrefix}-txn-category-options`}>{categories.map((category) => <option key={category} value={category} label={accountOptionLabel(category)} />)}</datalist>
          {setMetadataQuery && <Input list={`${idPrefix}-txn-metadata-options`} className="h-8 w-full rounded-md bg-paper text-xs sm:w-64" placeholder={t("transactionList.metadataPlaceholder")} value={metadataQuery ?? ""} onChange={(e) => setMetadataQuery(e.target.value)} />}
          <datalist id={`${idPrefix}-txn-metadata-options`}>{metadataOptions.map((item) => <option key={item} value={item} />)}</datalist>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {filterViewOptions.length > 0 && (
            <Select value={ALL_FILTER_VALUE} onValueChange={(value) => {
              const option = filterViewOptions.find((item) => item.value === value);
              if (option) restoreFilterView(option.view);
            }}>
              <SelectTrigger className="h-8 w-[180px] rounded-md bg-paper text-xs">
                <SelectValue placeholder={t("transactionList.restoreView")} />
              </SelectTrigger>
              <SelectContent className="max-h-80">
                <SelectItem value={ALL_FILTER_VALUE}>{t("transactionList.restoreView")}</SelectItem>
                {filterViewOptions.map((item) => <SelectItem key={item.value} value={item.value}>{item.label}</SelectItem>)}
              </SelectContent>
            </Select>
          )}
          {hasFilters && <Button type="button" variant="outline" size="xs" className="rounded-md bg-paper text-stone" onClick={saveCurrentFilterView}>{t("transactionList.saveCurrent")}</Button>}
          {setViewMode && <div className="flex overflow-hidden rounded-lg border border-line">
            <button type="button" className={`px-2 py-1 text-xs transition-colors ${viewMode === "compact" ? "bg-brand text-paper" : "bg-paper text-warm hover:bg-tag"}`} onClick={() => setViewMode("compact")}>{t("transactionList.compact")}</button>
            <button type="button" className={`px-2 py-1 text-xs transition-colors ${viewMode === "full" ? "bg-brand text-paper" : "bg-paper text-warm hover:bg-tag"}`} onClick={() => setViewMode("full")}>{t("transactionList.full")}</button>
          </div>}
          {setCategoryQuery && setMatchMode && categoryQuery && query && <div className="flex overflow-hidden rounded-lg border border-line">
            <button type="button" className={`px-2 py-1 text-xs transition-colors ${matchMode === "prefix" ? "bg-brand text-paper" : "bg-paper text-warm hover:bg-tag"}`} onClick={() => setMatchMode("prefix")}>{t("transactionList.prefix")}</button>
            <button type="button" className={`px-2 py-1 text-xs transition-colors ${matchMode === "exact" ? "bg-brand text-paper" : "bg-paper text-warm hover:bg-tag"}`} onClick={() => setMatchMode("exact")}>{t("transactionList.exact")}</button>
          </div>}
          {hasFilters && <Button type="button" variant="outline" size="xs" className="rounded-md bg-paper text-stone" onClick={clearFilters}>{t("transactionList.clearFilters")}</Button>}
        </div>
      </div>
    </>
  );

  return <section className={searchable ? "transaction-workbench" : "border-b border-line"}>
    <div className="min-w-0">
      {searchable && (
        <>
          <div className="mb-3 flex items-center gap-2 lg:hidden">
            <Button type="button" variant="outline" className="flex-1 rounded-md bg-panel text-warm shadow-sm" onClick={() => setMobileFiltersOpen(true)}>
              <SlidersHorizontal className="h-4 w-4 text-brand" />
              {t("transactionList.filter")}{activeFilterCount ? ` · ${activeFilterCount}` : ""}
            </Button>
            {hasFilters && <Button type="button" variant="outline" className="rounded-md bg-paper text-stone" onClick={clearFilters}>{t("transactionList.clear")}</Button>}
          </div>
          <div className="mb-3 flex items-center justify-between gap-3 text-xs text-stone lg:hidden">
            <span className="rounded-md bg-tag px-2 py-1">{serverSearchLoading ? t("transactionList.searching") : t("transactionList.countLabel", { count: rows.length, total: txns.length })}</span>
            {serverFilteredSearch && <span className="truncate text-right text-brand">{t("transactionList.backendQuery")}</span>}
            {serverSearchError ? <span className="truncate text-right amount-danger">{serverSearchError}</span> : hasFilters && <span className="truncate text-right">{t("transactionList.appliedFilters")}</span>}
          </div>
          <div className="hidden border-b border-line bg-panel px-3 py-3 lg:block md:px-4">
            {renderFilterControls("desktop")}
          </div>
        </>
      )}

      {!searchable && rows.length > 0 && <div className="flex min-h-11 items-center justify-between gap-3 border-b border-line bg-tag px-3 py-2 md:px-4">
        <div className="min-w-0"><h2 className="text-sm font-semibold text-ink">{t("transactionList.recentTransactions")}</h2><p className="mt-0.5 text-xs text-stone">{t("transactionList.recentHint")}</p></div>
        <span className="shrink-0 text-[11px] tabular-nums text-stone">{t("transactionList.countShort", { count: rows.length })}</span>
      </div>}

      {searchable && onAddTags && rows.length > 0 && (
        <div className="flex min-w-0 flex-col gap-2 border-b border-line bg-panel px-3 py-3 sm:flex-row sm:items-center md:px-4">
          <div className="flex shrink-0 items-center gap-2">
            <Checkbox
              id="transaction-select-page"
              className="relative after:absolute after:-inset-3"
              checked={allPageRowsBulkSelected ? true : bulkEligibleRows.some((txn) => bulkSelectedKeys.has(transactionKey(txn))) ? "indeterminate" : false}
              onCheckedChange={(checked) => toggleCurrentPageBulk(checked === true)}
              disabled={bulkEligibleRows.length === 0}
            />
            <label htmlFor="transaction-select-page" className="cursor-pointer text-sm text-ink">{t("transactionList.selectedCount", { count: bulkSelectedKeys.size })}</label>
            <span className="text-xs text-stone">{t("transactionList.selectPageHint")}</span>
          </div>
          <div className="grid min-w-0 flex-1 grid-cols-2 items-center gap-2 sm:ml-2 sm:flex">
            <div className="relative col-span-2 min-w-0 flex-1">
              <Tag className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-stone" />
              <Input
                className="h-11 min-w-0 bg-paper pl-9 sm:h-9"
                value={bulkTagInput}
                onChange={(event) => setBulkTagInput(event.target.value)}
                placeholder={t("transactionList.bulkTagPlaceholder")}
                aria-label={t("transactionList.bulkTagPlaceholder")}
                maxLength={1024}
                onKeyDown={(event) => { if (event.key === "Enter") applyBulkTags(); }}
              />
            </div>
            <Button type="button" size="sm" className="h-11 sm:h-9" onClick={applyBulkTags} disabled={!bulkSelectedKeys.size}>{t("transactionList.addTags")}</Button>
            {bulkSelectedKeys.size > 0 && <Button type="button" size="sm" variant="ghost" className="h-11 text-stone sm:h-9" onClick={() => setBulkSelectedKeys(new Set())}>{t("transactionList.clearSelection")}</Button>}
          </div>
        </div>
      )}

      {rows.length === 0 && <div className="border-b border-line bg-panel p-6 text-center text-sm text-stone">{serverSearchLoading ? t("transactionList.searchingMatches") : t("transactionList.noMatches")}</div>}

      {rows.length > 0 && (
        <div className={searchable ? "xl:grid xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start" : ""}>
          <div className="min-w-0">
          <div
            className="hidden overflow-hidden bg-panel focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand lg:block"
            tabIndex={0}
            role="grid"
            aria-label={t("transactionList.transactionGridLabel")}
            aria-activedescendant={activeTxnKey ? desktopRowId(pageRows.find((txn) => transactionKey(txn) === activeTxnKey) ?? pageRows[0]) : undefined}
            onKeyDown={handleDesktopListKeyDown}
          >
            <div className="grid grid-cols-[2.75rem_minmax(0,1fr)] border-b border-line bg-tag text-xs font-semibold text-stone">
              <span className="sr-only">{t("transactionList.selection")}</span>
              <div className="grid grid-cols-[72px_minmax(240px,1.15fr)_124px_minmax(220px,1fr)_minmax(150px,0.72fr)] gap-3 px-3 py-2 md:px-4">
                <span>{t("transactionList.date")}</span>
                <span>{t("transactionList.transaction")}</span>
                <span className="text-right">{t("transactionList.amount")}</span>
                <span>{t("transactionList.categoryAccount")}</span>
                <span>{t("transactionList.tags")}</span>
              </div>
            </div>
            <div className="divide-y divide-line">
              {pageRows.map((txn) => {
                const key = transactionKey(txn);
                return (
                  <MemoTransactionTableRow
                    key={key}
                    rowId={desktopRowId(txn)}
                    rowRef={setDesktopRowRef(key)}
                    txn={txn}
                    accounts={accounts}
                    selected={Boolean(selectedMatches(txn))}
                    bulkSelected={bulkSelectedKeys.has(key)}
                    bulkDisabled={!txn.source.hash || Boolean(txn.pending)}
                    viewMode={viewMode}
                    onSelect={handleSelectRow}
                    onToggleBulk={toggleBulkTransaction}
                  />
                );
              })}
            </div>
          </div>
          <div className="lg:hidden">
            {pageRows.map((txn) => {
              const key = transactionKey(txn);
              return <MemoTransactionCard key={key} txn={txn} accounts={accounts} selected={Boolean(selectedMatches(txn))} bulkSelected={bulkSelectedKeys.has(key)} bulkDisabled={!txn.source.hash || Boolean(txn.pending)} viewMode={viewMode} onSelect={handleSelectCard} onToggleBulk={toggleBulkTransaction} />;
            })}
          </div>
          {pager}
          </div>
          {searchable && <TransactionInspector txn={selected} accounts={accounts} visibleRows={pageRows.length} totalRows={rows.length} onOpenDetails={(txn) => setDrawerTxn(txn)} />}
        </div>
      )}
    </div>
    {searchable && <MobileSheet open={mobileFiltersOpen} title={t("transactionList.filterSheetTitle")} onClose={() => setMobileFiltersOpen(false)} footer={<div className="grid grid-cols-2 gap-2"><Button type="button" variant="outline" className="h-11 bg-panel" onClick={clearFilters} disabled={!hasFilters}>{t("transactionList.clearFilters")}</Button><Button type="button" className="h-11" onClick={() => setMobileFiltersOpen(false)}>{t("transactionList.done")}</Button></div>}>{renderFilterControls("mobile")}</MobileSheet>}
    {drawerTxn && <TransactionDrawer key={`${drawerTxn.source.file}:${drawerTxn.source.line}:sheet`} txn={drawerTxn} accounts={accounts} onClose={() => setDrawerTxn(null)} onUpdate={onUpdate} onDelete={(source, reason) => { onDelete?.(source, reason); setDrawerTxn(null); }} onReverse={(source, date) => { onReverse?.(source, date); setDrawerTxn(null); }} />}
  </section>;
}

function TransactionInspector({ txn, accounts, visibleRows, totalRows, onOpenDetails }: { txn?: Txn | null; accounts: AccountView[]; visibleRows: number; totalRows: number; onOpenDetails: (txn: Txn) => void }) {
  const { t } = useTranslation();
  if (!txn) return <aside className="transaction-inspector hidden border-l border-line bg-panel xl:block">
    <div className="sticky top-[3.25rem] p-4 text-sm text-stone">{t("transactionList.selectRow")}</div>
  </aside>;
  const displayAmount = transactionDisplayAmount(txn, accounts);
  const categoryRows = categoryAccounts(txn);
  const paymentAccounts = txn.postings.filter((posting) => posting.account.startsWith("Assets:") || posting.account.startsWith("Liabilities:"));
  const meta = metadataPairs(txn);
  const pending = pendingLabel(txn);
  return <aside className="transaction-inspector hidden border-l border-line bg-panel xl:block">
    <div className="sticky top-[3.25rem] max-h-[calc(100dvh-3.25rem)] overflow-y-auto">
      <div className="border-b border-line px-4 py-3">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <h3 className="text-sm font-semibold tracking-[-0.012em] text-ink">{t("transactionList.inspectorTitle")}</h3>
            <p className="mt-1 text-[11px] tabular-nums text-stone">{t("transactionList.thisPageCount", { visible: visibleRows, total: totalRows })}</p>
          </div>
          <button type="button" className="h-7 shrink-0 rounded-md border border-line bg-paper px-2 text-xs text-olive hover:bg-tag hover:text-ink" onClick={() => onOpenDetails(txn)}>{t("transactionList.edit")}</button>
        </div>
      </div>

      <div className="divide-y divide-line">
        <section className="px-4 py-4">
          <div className="text-[11px] font-semibold text-stone">{t("transactionList.payee")}</div>
          <div className="mt-1 truncate text-lg font-semibold tracking-[-0.018em] text-ink" title={txn.payee}>{txn.payee || t("transactionList.noPayee")}</div>
          <div className="mt-1 text-sm leading-5 text-olive [overflow-wrap:anywhere]">{txn.narration || t("transactionList.noNarrationShort")}</div>
          <div className="mt-3 flex flex-wrap gap-1.5">
            {pending && <span className="rounded-md border border-line bg-tag px-2 py-1 text-[11px] text-ink">{pending}</span>}
            <span className="rounded-md border border-line bg-tag px-2 py-1 text-[11px] tabular-nums text-stone">{txn.date}</span>
          </div>
        </section>

        <InspectorMetric label={t("transactionList.mainAmount")} value={displayAmount ? fmtTxnAmount(displayAmount) : "—"} tone={displayAmount ? transactionAmountColor(displayAmount) : "text-stone"} detail={displayAmount?.account ?? t("transactionList.noMainPosting")} />
        <InspectorMetric label={t("transactionList.category")} value={categoryRows.map(shortAccount).join(" / ") || t("transactionList.uncategorized")} tone="text-ink" detail={categoryRows.join(" · ") || t("transactionList.noCategory")} />
        <InspectorMetric label={t("transactionList.paymentAccount")} value={paymentAccounts.map((posting) => shortAccount(posting.account)).join(" / ") || t("transactionList.none")} tone="text-ink" detail={paymentAccounts.map((posting) => posting.account).join(" · ") || t("transactionList.noPaymentAccounts")} />

        <section className="px-4 py-3.5">
          <div className="mb-2 flex items-center justify-between gap-3">
            <h4 className="text-[11px] font-semibold text-stone">{t("transactionList.postingDetail")}</h4>
            <span className="text-[11px] tabular-nums text-stone">{t("transactionList.postingCount", { count: txn.postings.length })}</span>
          </div>
          <div className="divide-y divide-line border-y border-line">
            {txn.postings.map((posting, index) => <div key={`${posting.account}-${index}`} className="grid grid-cols-[minmax(0,1fr)_auto] gap-3 py-2.5">
              <span className="min-w-0 truncate text-xs text-olive" title={posting.account}>{posting.account}</span>
              <span className={`shrink-0 text-right text-xs tabular-nums ${amountColor(posting.amount)}`}>{fmtPostingAmount(posting.amount, posting.currency)}</span>
            </div>)}
          </div>
        </section>

        <section className="px-4 py-3.5">
          <div className="mb-2 flex items-center justify-between gap-3">
            <h4 className="text-[11px] font-semibold text-stone">{t("transactionList.sourceAndTags")}</h4>
            <span className="text-[11px] tabular-nums text-stone">{t("transactionList.sourceAndTagsCount", { count: meta.length + (txn.tags?.length ?? 0) })}</span>
          </div>
          <div className="text-xs leading-5 text-stone [overflow-wrap:anywhere]">{sourceLabel(txn)}</div>
          <div className="mt-2 flex flex-wrap gap-1.5">
            {meta.slice(0, 6).map(([key, value]) => <span key={`${key}:${String(value)}`} className="ledger-chip rounded-md px-2 py-1 text-[11px]">{key}: {String(value)}</span>)}
            {(txn.tags ?? []).slice(0, 4).map((tag) => <span key={tag} className="ledger-chip rounded-md px-2 py-1 text-[11px]">#{tag}</span>)}
            {!meta.length && !txn.tags?.length && <span className="text-xs text-stone">{t("transactionList.noMetadata")}</span>}
          </div>
        </section>
      </div>
    </div>
  </aside>;
}

function InspectorMetric({ label, value, tone, detail }: { label: string; value: string; tone: string; detail: string }) {
  return <section className="px-4 py-3.5">
    <div className="text-[11px] font-semibold text-stone">{label}</div>
    <div className={`mt-1 truncate text-base font-semibold tracking-[-0.014em] tabular-nums ${tone}`} title={value}>{value}</div>
    <div className="mt-1 truncate text-xs text-stone" title={detail}>{detail}</div>
  </section>;
}

function TransactionPager({ safePage, totalPages, rowsLength, pageSize, setPageSize, setPage }: { safePage: number; totalPages: number; rowsLength: number; pageSize: number; setPageSize: (value: number) => void; setPage: React.Dispatch<React.SetStateAction<number>> }) {
  const { t } = useTranslation();
  return <div className="flex flex-col gap-3 border-t border-line bg-panel px-3 py-2.5 text-xs sm:flex-row sm:items-center sm:justify-between md:px-4">
    <div className="tabular-nums text-stone">{t("transactionList.pageRange", { page: safePage, total: totalPages, start: (safePage - 1) * pageSize + 1, end: Math.min(safePage * pageSize, rowsLength), rows: rowsLength })}</div>
    <div className="flex items-center gap-2">
      <Select value={String(pageSize)} onValueChange={(value) => setPageSize(Number(value))}>
        <SelectTrigger className="h-8 w-[104px] rounded-md bg-panel text-xs">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="10">{t("transactionList.pageSize", { count: 10 })}</SelectItem>
          <SelectItem value="20">{t("transactionList.pageSize", { count: 20 })}</SelectItem>
          <SelectItem value="50">{t("transactionList.pageSize", { count: 50 })}</SelectItem>
          <SelectItem value="100">{t("transactionList.pageSize", { count: 100 })}</SelectItem>
        </SelectContent>
      </Select>
      <Button variant="outline" size="sm" className="h-8 rounded-md" disabled={safePage <= 1} onClick={() => setPage((value) => Math.max(1, value - 1))}>{t("transactionList.prevPage")}</Button>
      <Button variant="outline" size="sm" className="h-8 rounded-md" disabled={safePage >= totalPages} onClick={() => setPage((value) => Math.min(totalPages, value + 1))}>{t("transactionList.nextPage")}</Button>
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
  const { t } = useTranslation();
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
  const displayAmount = transactionDisplayAmount(txn, accounts);
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
      setFormError(t("transactionList.metadataInvalid"));
      return;
    }
    if (!parsedMetadata || Array.isArray(parsedMetadata) || typeof parsedMetadata !== "object") {
      setFormError(t("transactionList.metadataObjectRequired"));
      return;
    }
    const cleanedPostings = postings.map((p) => ({ account: p.account.trim(), amount: p.amount.trim(), currency: p.currency.trim().toUpperCase() || "CNY" }));
    if (cleanedPostings.length < 2) {
      setFormError(t("transactionList.atLeastTwoPostings"));
      return;
    }
    if (cleanedPostings.some((p) => !p.account)) {
      setFormError(t("transactionList.postingsNeedAccount"));
      return;
    }
    if (cleanedPostings.some((p) => !p.amount || Number.isNaN(Number(p.amount)))) {
      setFormError(t("transactionList.postingsNeedAmount"));
      return;
    }
    onUpdate?.(txn.source, { kind: "transaction", date, payee, narration, metadata: parsedMetadata, tags: tags.split(/\s+/).map((tag) => tag.replace(/^#/, "")).filter(Boolean), confidence: 1, needsReview: false, questions: [], postings: cleanedPostings });
    setEditing(false);
    onClose();
  }

  const footer = pendingAppend ? <div className="text-sm leading-6 text-olive">
    {t("transactionList.pendingAppendHint")}
  </div> : editing ? <div className="grid grid-cols-2 gap-2">
    <Button variant="outline" className="h-11 bg-panel" onClick={() => { resetForm(); setEditing(false); }}>{t("transactionList.cancelEdit")}</Button>
    <Button className="h-11" onClick={save}>{t("transactionList.saveChanges")}</Button>
  </div> : <div className="grid gap-2 sm:grid-cols-3">
    <Button variant="outline" className="h-11 bg-panel" onClick={() => setEditing(true)}>{t("transactionList.edit")}</Button>
    <Button variant="outline" className="h-11 border-destructive/40 text-destructive hover:bg-destructive/10 hover:text-destructive" onClick={() => setPendingAction({ kind: "delete", reason: t("transactionList.deleteReason") })}>{t("transactionList.annotateDelete")}</Button>
    <Button className="h-11" onClick={() => setPendingAction({ kind: "reverse", date: reverseDate })}>{t("transactionList.reverse")}</Button>
  </div>;

  const body = <>
    <div className="flex min-w-0 flex-wrap items-center gap-2 border-b border-line bg-tag px-4 py-2 text-xs text-stone sm:px-5">
      <span className="min-w-0 [overflow-wrap:anywhere]">{sourceLabel(txn)}</span>
      {pending && <span className="shrink-0 rounded-full bg-brand/10 px-2 py-0.5 text-brand">{pending}</span>}
    </div>
    {editing ? <div className="grid min-w-0">
      {formError && <div className="mx-4 mt-4 sm:mx-5"><Alert variant="destructive"><AlertDescription>{formError}</AlertDescription></Alert></div>}
      <section className="grid min-w-0 gap-3 border-b border-line px-4 py-4 sm:grid-cols-[10rem_minmax(0,1fr)] sm:px-5">
        <label className="grid gap-1 text-xs text-stone">
          <span>{t("transactionList.date")}</span>
          <Input className="h-11 bg-panel" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
        </label>
        <label className="grid min-w-0 gap-1 text-xs text-stone">
          <span>{t("transactionList.payee")}</span>
          <Input className="h-11 min-w-0 bg-panel" value={payee} onChange={(e) => setPayee(e.target.value)} />
        </label>
        <label className="grid min-w-0 gap-1 text-xs text-stone sm:col-span-2">
          <span>{t("transactionList.narrationLabel")}</span>
          <Input className="h-11 min-w-0 bg-panel" value={narration} onChange={(e) => setNarration(e.target.value)} />
        </label>
      </section>

      <section className="@container min-w-0 border-b border-line">
        <div className="flex items-center justify-between gap-3 px-4 py-3 sm:px-5">
          <div>
            <h3 className="font-medium text-warm">{t("transactionList.postingsFlow")}</h3>
            <p className="mt-0.5 text-xs text-stone">{t("transactionList.postingsFlowHint")}</p>
          </div>
          <Button
            type="button"
            variant="outline"
            className="h-9 shrink-0 rounded-md bg-panel px-3 text-sm"
            onClick={() => setPostings((rows) => [...rows, { account: "", amount: "", currency: rows.at(-1)?.currency || "CNY" }])}
          >
            <Plus className="h-4 w-4" />
            <span>{t("transactionList.add")}</span>
          </Button>
        </div>
        <div className="min-w-0 divide-y divide-line border-t border-line">
          {postings.map((p, i) => <div key={i} className="grid min-w-0 gap-2 px-4 py-3 sm:px-5 @lg:grid-cols-[minmax(0,1fr)_minmax(7.5rem,9rem)_5.5rem_2.75rem]">
            <div className="min-w-0">
              <div className="mb-1 flex items-center justify-between gap-2 text-xs text-stone">
                <span>{t("transactionList.accountLabel", { index: i + 1 })}</span>
                <span className="shrink-0">{p.account ? shortAccount(p.account) : t("transactionList.notSelected")}</span>
              </div>
              <Select value={accountOptions.some((account) => account.account === p.account) ? p.account : ALL_FILTER_VALUE} onValueChange={(value) => value !== ALL_FILTER_VALUE && setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, account: value } : row))}>
                <SelectTrigger className="h-10 w-full min-w-0 bg-panel">
                  <SelectValue placeholder={t("transactionList.selectAccount")} />
                </SelectTrigger>
                <SelectContent className="max-h-80">
                  <SelectItem value={ALL_FILTER_VALUE}>{t("transactionList.selectAccount")}</SelectItem>
                  {accountOptions.map((account) => <SelectItem key={account.account} value={account.account}>{optionLabel(account)}</SelectItem>)}
                </SelectContent>
              </Select>
              <Input list={`txn-account-options-${i}`} className="mt-2 h-10 min-w-0 bg-panel text-sm" value={p.account} placeholder={t("transactionList.manualAccountPlaceholder")} onChange={(e) => setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, account: e.target.value } : row))} />
              <datalist id={`txn-account-options-${i}`}>{accountOptions.map((account) => <option key={account.account} value={account.account} label={optionLabel(account)} />)}</datalist>
            </div>
            <label className="grid gap-1 text-xs text-stone">
              <span>{t("transactionList.amountLabel")}</span>
              <Input className="h-10 bg-panel text-right tabular-nums" inputMode="decimal" value={p.amount} onChange={(e) => setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, amount: e.target.value } : row))} />
            </label>
            <label className="grid gap-1 text-xs text-stone">
              <span>{t("transactionList.currencyLabel")}</span>
              <Input className="h-10 bg-panel uppercase" value={p.currency} onChange={(e) => setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, currency: e.target.value.toUpperCase() } : row))} />
            </label>
            <Button
              type="button"
              variant="outline"
              className="h-10 self-end rounded-md bg-panel px-0 text-stone hover:text-destructive"
              disabled={postings.length <= 2}
              title={postings.length <= 2 ? t("transactionList.atLeastTwo") : t("transactionList.deletePosting")}
              onClick={() => setPostings((rows) => rows.filter((_, idx) => idx !== i))}
            >
              <Trash2 className="h-4 w-4" />
            </Button>
          </div>)}
        </div>
      </section>

      <section className="grid min-w-0 gap-3 px-4 py-4 sm:px-5">
        <label className="grid min-w-0 gap-1 text-xs text-stone">
          <span>{t("transactionList.tagsLabel")}</span>
          <Input className="h-11 min-w-0 bg-panel" value={tags} onChange={(e) => setTags(e.target.value)} placeholder={t("transactionList.tagsPlaceholder")} />
        </label>
        <label className="grid min-w-0 gap-1 text-xs text-stone">
          <span>Metadata</span>
          <Textarea className="min-h-36 min-w-0 bg-panel font-mono text-xs" value={metadata} onChange={(e) => setMetadata(e.target.value)} placeholder={'{"platform":"taobao","channel":"online"}'} />
        </label>
      </section>
    </div> : <div className="grid min-w-0">
      <section className="@container min-w-0 border-b border-line px-4 py-4 sm:px-5">
        <div className="flex min-w-0 flex-col gap-3 @sm:flex-row @sm:items-start @sm:justify-between">
          <div className="min-w-0">
            <div className="text-xs text-stone">{txn.date}</div>
            <div className="mt-1 text-lg font-medium text-warm [overflow-wrap:anywhere]">{txn.payee || t("transactionList.noPayee")}</div>
            <div className="mt-1 text-sm text-olive [overflow-wrap:anywhere]">{txn.narration || t("transactionList.noNarrationShort")}</div>
            <MetadataBadges txn={txn} />
          </div>
          {displayAmount && <div className="min-w-0 border-t border-line pt-3 text-left @sm:shrink-0 @sm:border-l @sm:border-t-0 @sm:pl-4 @sm:pt-0 @sm:text-right">
            <div className="text-[11px] text-stone">{t("transactionList.mainAmount")}</div>
            <div className={`mt-0.5 truncate text-lg font-semibold ${transactionAmountColor(displayAmount)}`} title={fmtTxnAmount(displayAmount)}>{fmtTxnAmount(displayAmount)}</div>
          </div>}
        </div>
      </section>

      <section className="@container min-w-0">
        <div className="flex items-center justify-between gap-3 border-b border-line px-4 py-3 sm:px-5">
          <h3 className="font-medium text-warm">{t("transactionList.postingsFlow")}</h3>
          <span className="rounded-full bg-tag px-2 py-0.5 text-xs text-stone">{t("transactionList.postingCount", { count: txn.postings.length })}</span>
        </div>
        <div className="min-w-0 divide-y divide-line">{txn.postings.map((p, i) => <div key={`${p.account}-${i}`} className="grid min-w-0 gap-2 px-4 py-3 sm:px-5 @sm:grid-cols-[minmax(0,1fr)_auto] @sm:items-center">
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
      onDelete?.(txn.source, pendingAction.reason.trim() || t("transactionList.deleteReason"));
    } else {
      onReverse?.(txn.source, pendingAction.date || reverseDate);
    }
    setPendingAction(null);
  };

  return <>
    <MobileSheet open title={editing ? t("transactionList.editTitle") : t("transactionList.detailTitle")} onClose={onClose} shouldClose={shouldClose} footer={footer} size="xl" panelClassName="sm:max-w-3xl" bodyClassName="overflow-x-hidden !px-0 !py-0">{body}</MobileSheet>
    <AlertDialog open={Boolean(pendingAction)} onOpenChange={(open) => !open && setPendingAction(null)}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{pendingAction?.kind === "delete" ? t("transactionList.deleteTitle") : t("transactionList.reverseTitle")}</AlertDialogTitle>
          <AlertDialogDescription>
            {pendingAction?.kind === "delete" ? t("transactionList.deleteDesc") : t("transactionList.reverseDesc")}
          </AlertDialogDescription>
        </AlertDialogHeader>
        {pendingAction?.kind === "delete" && (
          <div className="grid gap-2">
            <label className="text-sm font-medium text-warm" htmlFor="delete-reason">{t("transactionList.deleteReasonLabel")}</label>
            <Input id="delete-reason" value={pendingAction.reason} onChange={(event) => setPendingAction({ kind: "delete", reason: event.target.value })} />
          </div>
        )}
        {pendingAction?.kind === "reverse" && (
          <div className="grid gap-2">
            <label className="text-sm font-medium text-warm" htmlFor="reverse-date">{t("transactionList.reverseDateLabel")}</label>
            <Input id="reverse-date" type="date" value={pendingAction.date} onChange={(event) => setPendingAction({ kind: "reverse", date: event.target.value })} />
          </div>
        )}
        <AlertDialogFooter>
          <AlertDialogCancel>{t("transactionList.cancel")}</AlertDialogCancel>
          <AlertDialogAction className={pendingAction?.kind === "delete" ? "bg-destructive text-white hover:bg-destructive/90" : undefined} onClick={confirmPendingAction}>
            {pendingAction?.kind === "delete" ? t("transactionList.confirmDelete") : t("transactionList.confirmReverse")}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
    <AlertDialog open={discardDialogOpen} onOpenChange={setDiscardDialogOpen}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{t("transactionList.discardTitle")}</AlertDialogTitle>
          <AlertDialogDescription>{t("transactionList.discardDesc")}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>{t("transactionList.keepEditing")}</AlertDialogCancel>
          <AlertDialogAction onClick={() => { setDiscardDialogOpen(false); onClose(); }}>{t("transactionList.discardChanges")}</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  </>;
}
