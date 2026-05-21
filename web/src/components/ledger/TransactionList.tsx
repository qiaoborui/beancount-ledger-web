import { useEffect, useMemo, useState } from "react";
import { formatCny } from "@/lib/money";
import { MobileSheet } from "./MobileSheet";
import type { ParsedTransaction } from "@/lib/schemas";
import type { AccountView, MetadataValue, Txn } from "./types";


function metadataPairs(t: Txn): [string, MetadataValue][] {
  return Object.entries(t.metadata ?? {}).filter(([, value]) => value !== "" && value != null);
}

function metadataText(t: Txn): string {
  return [
    ...metadataPairs(t).map(([key, value]) => `${key}:${String(value)}`),
    ...(t.tags ?? []).map((tag) => `#${tag}`),
  ].join(" ");
}

function useDebouncedValue<T>(value: T, delay = 160) {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const id = window.setTimeout(() => setDebounced(value), delay);
    return () => window.clearTimeout(id);
  }, [delay, value]);
  return debounced;
}

function matchesMetadataQuery(t: Txn, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  const pairs = metadataPairs(t);
  const tags = t.tags ?? [];
  return q.split(/\s+/).every((word) => {
    if (word.startsWith("#")) return tags.some((tag) => `#${tag}`.toLowerCase().includes(word));
    const exact = word.match(/^([a-z][a-z0-9_-]*):(.+)$/i);
    if (exact) {
      const [, key, value] = exact;
      return pairs.some(([k, v]) => k.toLowerCase() === key.toLowerCase() && String(v).toLowerCase().includes(value.toLowerCase()));
    }
    return metadataText(t).toLowerCase().includes(word);
  });
}

function MetadataBadges({ txn, limit }: { txn: Txn; limit?: number }) {
  const items = [
    ...metadataPairs(txn).map(([key, value]) => ({ key: `${key}:${String(value)}`, label: `${key}: ${String(value)}` })),
    ...(txn.tags ?? []).map((tag) => ({ key: `tag:${tag}`, label: `#${tag}` })),
  ];
  const shown = typeof limit === "number" ? items.slice(0, limit) : items;
  if (!shown.length) return null;
  return <div className="mt-2 flex flex-wrap gap-1">{shown.map((item) => <span key={item.key} className="rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone">{item.label}</span>)}{limit && items.length > limit && <span className="rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone">+{items.length - limit}</span>}</div>;
}

/** 从 account 路径中提取简短名称（最后一个冒号后的部分） */
function shortAccount(account: string): string {
  const idx = account.lastIndexOf(":");
  return idx >= 0 ? account.slice(idx + 1) : account;
}

/** 从一笔交易中提取最关键的金额（优先支出/收入，其次资产变动） */
function primaryAmount(t: Txn): number | null {
  const cat = t.postings.find((p) => p.account.startsWith("Expenses:") || p.account.startsWith("Income:"));
  if (cat) return cat.amount;
  const asset = t.postings.find((p) => p.account.startsWith("Assets:") || p.account.startsWith("Liabilities:"));
  return asset?.amount ?? null;
}

/** 金额颜色：支出(借方)=expense红，收入(贷方)=income绿，零或其他=品牌色 */
function amountColor(amount: number): string {
  if (amount > 0) return "amount-expense";
  if (amount < 0) return "amount-income";
  return "amount-gold";
}

/** 格式化流水主金额：支出显示为负，收入显示为正 */
function fmtTxnAmount(amount: number): string {
  const sign = amount <= 0 ? "+" : "-";
  return `${sign}${formatCny(Math.abs(amount) / 100)}`;
}

/** 格式化 posting 金额（带符号，正=借/支出方向，负=贷/收入方向） */
function fmtPostingAmount(amount: number): string {
  const sign = amount >= 0 ? "+" : "-";
  return `${sign}${formatCny(Math.abs(amount) / 100)}`;
}

/** 紧凑借贷方流向：贷记(贷方) → 借记(借方) */
function PostingFlow({ postings, maxShow = 3 }: { postings: Txn["postings"]; maxShow?: number }) {
  const debits = postings.filter(p => p.amount > 0);
  const credits = postings.filter(p => p.amount < 0);

  // 合并展示：先贷记(负数)，后借记(正数)，中间用箭头分隔
  const allItems: { account: string; amount: number; side: "credit" | "debit" }[] = [
    ...credits.map(p => ({ account: p.account, amount: p.amount, side: "credit" as const })),
    ...debits.map(p => ({ account: p.account, amount: p.amount, side: "debit" as const })),
  ];

  // 截断：保留所有贷记 + 最多 maxShow-creditCount 个借记
  const creditCount = credits.length;
  const maxDebitShow = Math.max(1, maxShow - creditCount);
  const shownCredits = credits.slice(0, maxShow);
  const shownDebits = debits.slice(0, maxDebitShow);
  const remaining = Math.max(0, credits.length - shownCredits.length) + Math.max(0, debits.length - shownDebits.length);

  if (allItems.length === 0) return null;

  return (
    <div className="mt-1 flex flex-wrap items-center gap-x-1 gap-y-0.5 text-xs">
      {shownCredits.map((p, i) => (
        <span key={`c-${i}`} className="amount-income">
          {shortAccount(p.account)} {fmtPostingAmount(p.amount)}
        </span>
      ))}
      {shownCredits.length > 0 && shownDebits.length > 0 && (
        <span className="mx-0.5 text-stone/40">→</span>
      )}
      {shownDebits.map((p, i) => (
        <span key={`d-${i}`} className="amount-expense">
          {shortAccount(p.account)} {fmtPostingAmount(p.amount)}
        </span>
      ))}
      {remaining > 0 && <span className="text-stone/40">… +{remaining}</span>}
    </div>
  );
}

function TransactionCard({ txn, selected, viewMode, onSelect }: { txn: Txn; selected: boolean; viewMode?: "compact" | "full"; onSelect: () => void }) {
  const amt = primaryAmount(txn);
  return (
    <button className={`card mb-1.5 block w-full p-4 text-left ${selected ? "border-brand bg-[var(--selected-bg)]" : ""}`} onClick={onSelect}>
      <div className="flex items-baseline justify-between gap-3">
        <div className="min-w-0">
          <strong className="block truncate">{txn.payee}</strong>
          {txn.pending && <span className="ml-2 rounded-full bg-brand/10 px-2 py-0.5 text-[11px] text-brand">待同步修改</span>}
        </div>
        {amt != null && <span className={`shrink-0 font-medium tabular-nums ${amountColor(amt)}`}>{fmtTxnAmount(amt)}</span>}
      </div>
      <div className="mt-0.5 text-sm text-olive">{txn.narration}</div>
      {viewMode === "full" ? (
        <>
          <PostingFlow postings={txn.postings} />
          <MetadataBadges txn={txn} limit={6} />
          <div className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-stone">{txn.date}</div>
        </>
      ) : (
        <>
          <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-stone">{txn.date}{txn.postings.filter(p => p.account.startsWith("Expenses:") || p.account.startsWith("Income:")).map((p, j) => <span key={j}>{p.account}</span>)}</div>
          <MetadataBadges txn={txn} limit={3} />
        </>
      )}
    </button>
  );
}

function TransactionTableRow({ txn, selected, viewMode, onSelect }: { txn: Txn; selected: boolean; viewMode?: "compact" | "full"; onSelect: () => void }) {
  const amt = primaryAmount(txn);
  const categoryAccounts = txn.postings.filter((posting) => posting.account.startsWith("Expenses:") || posting.account.startsWith("Income:"));
  const paymentAccounts = txn.postings.filter((posting) => posting.account.startsWith("Assets:") || posting.account.startsWith("Liabilities:"));
  const meta = metadataPairs(txn);
  return (
    <button
      type="button"
      className={`grid w-full grid-cols-[84px_140px_minmax(260px,1.2fr)_minmax(260px,1fr)_minmax(180px,0.75fr)] items-center gap-4 px-4 py-3 text-left transition-colors hover:bg-tag ${selected ? "bg-[var(--selected-bg)]" : "bg-panel"}`}
      onClick={onSelect}
    >
      <div className="text-xs tabular-nums text-stone">
        <div>{txn.date.slice(5)}</div>
        <div className="mt-1 text-[11px] text-stone/70">{txn.date.slice(0, 4)}</div>
      </div>
      <div className={`text-right text-base font-semibold tabular-nums ${amt == null ? "text-stone" : amountColor(amt)}`}>{amt == null ? "—" : fmtTxnAmount(amt)}</div>
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <strong className="truncate text-sm text-ink">{txn.payee}</strong>
          {txn.pending && <span className="shrink-0 rounded-full bg-brand/10 px-2 py-0.5 text-[11px] text-brand">待同步</span>}
        </div>
        <div className="mt-0.5 truncate text-xs text-olive">{txn.narration || "无说明"}</div>
        {viewMode === "full" && <PostingFlow postings={txn.postings} maxShow={4} />}
      </div>
      <div className="min-w-0">
        <div className="truncate text-xs text-warm">{categoryAccounts.map((posting) => posting.account).join(" · ") || "未分类"}</div>
        <div className="mt-1 truncate text-[11px] text-stone">{paymentAccounts.map((posting) => shortAccount(posting.account)).join(" / ") || "无付款账户"}</div>
      </div>
      <div className="min-w-0">
        {meta.length || txn.tags?.length ? (
          <div className="flex flex-wrap gap-1">
            {meta.slice(0, 2).map(([key, value]) => <span key={`${key}:${String(value)}`} className="max-w-[120px] truncate rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone">{key}: {String(value)}</span>)}
            {(txn.tags ?? []).slice(0, 1).map((tag) => <span key={tag} className="max-w-[100px] truncate rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone">#{tag}</span>)}
            {meta.length + (txn.tags?.length ?? 0) > 3 && <span className="rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone">+{meta.length + (txn.tags?.length ?? 0) - 3}</span>}
          </div>
        ) : <span className="text-xs text-stone/60">—</span>}
      </div>
    </button>
  );
}

export function TransactionList({ txns, accounts = [], searchable, categoryQuery, setCategoryQuery, metadataQuery, setMetadataQuery, searchQuery, setSearchQuery, matchMode, setMatchMode, viewMode, setViewMode, onUpdate, onDelete, onReverse }: { txns: Txn[]; accounts?: AccountView[]; searchable?: boolean; categoryQuery?: string; setCategoryQuery?: (value: string) => void; metadataQuery?: string; setMetadataQuery?: (value: string) => void; searchQuery?: string; setSearchQuery?: (value: string) => void; matchMode?: "exact" | "prefix"; setMatchMode?: (mode: "exact" | "prefix") => void; viewMode?: "compact" | "full"; setViewMode?: (mode: "compact" | "full") => void; onUpdate?: (source: Txn["source"], entry: ParsedTransaction) => void; onDelete?: (source: Txn["source"], reason: string) => void; onReverse?: (source: Txn["source"], date: string) => void }) {
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(20);
  const [selected, setSelected] = useState<Txn | null>(null);
  const categories = useMemo(() => Array.from(new Set(txns.flatMap((t) => t.postings.filter((p) => p.account.startsWith("Expenses:") || p.account.startsWith("Income:")).map((p) => p.account)))).sort(), [txns]);
  const debouncedCategoryQuery = useDebouncedValue(categoryQuery ?? "");
  const debouncedSearchQuery = useDebouncedValue(searchQuery ?? "");
  const debouncedMetadataQuery = useDebouncedValue(metadataQuery ?? "");
  const query = debouncedCategoryQuery.trim().toLowerCase();
  const searchWords = debouncedSearchQuery.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const metadataOptions = useMemo(() => Array.from(new Set(txns.flatMap((t) => [
    ...metadataPairs(t).map(([key, value]) => `${key}:${String(value)}`),
    ...(t.tags ?? []).map((tag) => `#${tag}`),
  ]))).sort(), [txns]);
  const metadataQ = debouncedMetadataQuery.trim();

  // 组合过滤：分类 AND 关键词搜索
  const rows = useMemo(() => {
    let filtered = txns;

    // 分类筛选
    if (query) {
      if (matchMode === "prefix") {
        filtered = filtered.filter((t) =>
          t.postings.some((p) => (p.account.startsWith("Expenses:") || p.account.startsWith("Income:")) && p.account.toLowerCase().startsWith(query))
        );
      } else {
        // 精确匹配（忽略大小写）
        filtered = filtered.filter((t) =>
          t.postings.some((p) => (p.account.startsWith("Expenses:") || p.account.startsWith("Income:")) && p.account.toLowerCase() === query)
        );
      }
    }

    // 关键词搜索：payee / narration / posting.account
    if (searchWords.length > 0) {
      filtered = filtered.filter((t) =>
        searchWords.every((word) =>
          t.payee.toLowerCase().includes(word) ||
          t.narration.toLowerCase().includes(word) ||
          t.postings.some((p) => p.account.toLowerCase().includes(word)) ||
          metadataText(t).toLowerCase().includes(word)
        )
      );
    }

    if (metadataQ) {
      filtered = filtered.filter((t) => matchesMetadataQuery(t, metadataQ));
    }

    return filtered;
  }, [txns, query, debouncedSearchQuery, metadataQ, matchMode]);

  const totalPages = Math.max(1, Math.ceil(rows.length / pageSize));
  const safePage = Math.min(page, totalPages);
  const pageRows = rows.slice((safePage - 1) * pageSize, safePage * pageSize);

  useEffect(() => { setPage(1); }, [debouncedCategoryQuery, debouncedSearchQuery, debouncedMetadataQuery, pageSize, txns.length, matchMode]);

  const hasFilters = Boolean((categoryQuery ?? "").trim() || (metadataQuery ?? "").trim() || (searchQuery ?? "").trim());
  const selectedMatches = (txn: Txn) => selected?.source.file === txn.source.file && selected.source.line === txn.source.line && selected.source.hash === txn.source.hash;
  const pager = rows.length > 0 && <TransactionPager safePage={safePage} totalPages={totalPages} rowsLength={rows.length} pageSize={pageSize} setPageSize={setPageSize} setPage={setPage} />;

  return <section className="mt-6">
    <div className="min-w-0">
      {searchable && (
        <div className="mb-4 rounded-2xl border border-line bg-panel p-3 shadow-sm">
          <div className="grid gap-3 xl:grid-cols-[minmax(260px,1fr)_minmax(180px,260px)_minmax(180px,260px)]">
            {setSearchQuery && <input id="transaction-search-input" className="w-full rounded-xl border border-line bg-paper px-3 py-2 text-sm" placeholder="搜索商户、说明、账户、metadata" value={searchQuery ?? ""} onChange={(e) => setSearchQuery(e.target.value)} />}
            {setCategoryQuery && <select className="w-full rounded-xl border border-line bg-paper px-3 py-2 text-sm" value={categories.includes(categoryQuery ?? "") ? categoryQuery : ""} onChange={(e) => setCategoryQuery(e.target.value)}><option value="">全部分类</option>{categories.map((category) => <option key={category} value={category}>{category}</option>)}</select>}
            {setMetadataQuery && <select className="w-full rounded-xl border border-line bg-paper px-3 py-2 text-sm" value={metadataOptions.includes(metadataQuery ?? "") ? metadataQuery : ""} onChange={(e) => setMetadataQuery(e.target.value)}><option value="">全部 metadata</option>{metadataOptions.map((item) => <option key={item} value={item}>{item}</option>)}</select>}
          </div>
          <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
            <div className="flex flex-wrap items-center gap-2 text-xs text-stone">
              <span className="rounded-full bg-tag px-2 py-1">{rows.length} / {txns.length} 笔</span>
              {setCategoryQuery && <input list="txn-category-options" className="w-60 rounded-xl border border-line bg-paper px-3 py-1.5 text-xs" placeholder="手动分类前缀，如 Expenses:Food" value={categoryQuery ?? ""} onChange={(e) => setCategoryQuery(e.target.value)} />}
              <datalist id="txn-category-options">{categories.map((category) => <option key={category} value={category} />)}</datalist>
              {setMetadataQuery && <input list="txn-metadata-options" className="w-64 rounded-xl border border-line bg-paper px-3 py-1.5 text-xs" placeholder="metadata/tag，如 person:妈妈 #trip" value={metadataQuery ?? ""} onChange={(e) => setMetadataQuery(e.target.value)} />}
              <datalist id="txn-metadata-options">{metadataOptions.map((item) => <option key={item} value={item} />)}</datalist>
            </div>
            <div className="flex flex-wrap items-center gap-2">
              {setViewMode && <div className="flex overflow-hidden rounded-lg border border-line">
                <button className={`px-2 py-1 text-xs transition-colors ${viewMode === "compact" ? "bg-brand text-paper" : "bg-paper text-warm hover:bg-tag"}`} onClick={() => setViewMode("compact")}>简洁</button>
                <button className={`px-2 py-1 text-xs transition-colors ${viewMode === "full" ? "bg-brand text-paper" : "bg-paper text-warm hover:bg-tag"}`} onClick={() => setViewMode("full")}>完整</button>
              </div>}
              {setCategoryQuery && setMatchMode && categoryQuery && query && <div className="flex overflow-hidden rounded-lg border border-line">
                <button className={`px-2 py-1 text-xs transition-colors ${matchMode === "prefix" ? "bg-brand text-paper" : "bg-paper text-warm hover:bg-tag"}`} onClick={() => setMatchMode("prefix")}>前缀</button>
                <button className={`px-2 py-1 text-xs transition-colors ${matchMode === "exact" ? "bg-brand text-paper" : "bg-paper text-warm hover:bg-tag"}`} onClick={() => setMatchMode("exact")}>精确</button>
              </div>}
              {hasFilters && <button className="rounded-xl border border-line bg-paper px-3 py-1.5 text-xs text-stone hover:bg-tag" onClick={() => { setCategoryQuery?.(""); setMetadataQuery?.(""); setSearchQuery?.(""); }}>清除筛选</button>}
            </div>
          </div>
        </div>
      )}

      {rows.length === 0 && <div className="card p-6 text-center text-sm text-stone">没有匹配的流水，换个分类关键词试试。</div>}

      {searchable && rows.length > 0 ? (
        <>
          <div className="hidden overflow-hidden rounded-2xl border border-line bg-panel shadow-sm lg:block">
            <div className="grid grid-cols-[84px_140px_minmax(260px,1.2fr)_minmax(260px,1fr)_minmax(180px,0.75fr)] gap-4 border-b border-line bg-paper px-4 py-2 text-[11px] uppercase tracking-[0.16em] text-stone">
              <span>日期</span>
              <span className="text-right">金额</span>
              <span>交易</span>
              <span>分类 / 账户</span>
              <span>标签</span>
            </div>
            <div className="divide-y divide-line">
              {pageRows.map((txn, index) => <TransactionTableRow key={`${txn.source.file}-${txn.source.line}-${index}`} txn={txn} selected={Boolean(selectedMatches(txn))} viewMode={viewMode} onSelect={() => setSelected(txn)} />)}
            </div>
          </div>
          <div className="lg:hidden">
            {pageRows.map((txn, index) => <TransactionCard key={`${txn.source.file}-${txn.source.line}-${index}`} txn={txn} selected={Boolean(selectedMatches(txn))} viewMode={viewMode} onSelect={() => setSelected(txn)} />)}
          </div>
        </>
      ) : (
        pageRows.map((txn, index) => <TransactionCard key={`${txn.source.file}-${txn.source.line}-${index}`} txn={txn} selected={Boolean(selectedMatches(txn))} viewMode={viewMode} onSelect={() => setSelected(txn)} />)
      )}

      {pager}
    </div>
    {selected && <TransactionDrawer key={`${selected.source.file}:${selected.source.line}:sheet`} txn={selected} accounts={accounts} onClose={() => setSelected(null)} onUpdate={onUpdate} onDelete={(source, reason) => { onDelete?.(source, reason); setSelected(null); }} onReverse={(source, date) => { onReverse?.(source, date); setSelected(null); }} />}
  </section>;
}

function TransactionPager({ safePage, totalPages, rowsLength, pageSize, setPageSize, setPage }: { safePage: number; totalPages: number; rowsLength: number; pageSize: number; setPageSize: (value: number) => void; setPage: React.Dispatch<React.SetStateAction<number>> }) {
  return <div className="mt-4 flex flex-col gap-3 rounded-xl border border-line bg-panel p-3 text-sm sm:flex-row sm:items-center sm:justify-between">
    <div className="text-stone">第 {safePage} / {totalPages} 页，显示 {(safePage - 1) * pageSize + 1}-{Math.min(safePage * pageSize, rowsLength)} 条</div>
    <div className="flex items-center gap-2">
      <select className="rounded-xl border border-line bg-panel px-2 py-2" value={pageSize} onChange={(e) => setPageSize(Number(e.target.value))}><option value={10}>10 条/页</option><option value={20}>20 条/页</option><option value={50}>50 条/页</option><option value={100}>100 条/页</option></select>
      <button className="rounded-xl border border-line px-3 py-2 disabled:opacity-40" disabled={safePage <= 1} onClick={() => setPage((value) => Math.max(1, value - 1))}>上一页</button>
      <button className="rounded-xl border border-line px-3 py-2 disabled:opacity-40" disabled={safePage >= totalPages} onClick={() => setPage((value) => Math.min(totalPages, value + 1))}>下一页</button>
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

function TransactionDrawer({ txn, accounts, onClose, onUpdate, onDelete, onReverse }: TransactionDrawerProps) {
  const [editing, setEditing] = useState(false);
  const [date, setDate] = useState(txn.date);
  const [payee, setPayee] = useState(txn.payee);
  const [narration, setNarration] = useState(txn.narration);
  const [postings, setPostings] = useState(() => txn.postings.map((p) => ({ account: p.account, amount: (p.amount / 100).toFixed(2) })));
  const [metadata, setMetadata] = useState(() => JSON.stringify(txn.metadata ?? {}, null, 2));
  const [tags, setTags] = useState(() => (txn.tags ?? []).join(" "));
  const accountOptions = useMemo(() => accounts.filter((account) => account.active || postings.some((posting) => posting.account === account.account)), [accounts, postings]);
  const optionLabel = (account: AccountView) => `${account.label} · ${account.account}`;
  const reverseDate = new Date().toISOString().slice(0, 10);
  const hasUnsavedChanges = editing && (
    date !== txn.date ||
    payee !== txn.payee ||
    narration !== txn.narration ||
    metadata !== JSON.stringify(txn.metadata ?? {}, null, 2) ||
    tags !== (txn.tags ?? []).join(" ") ||
    postings.some((posting, index) => posting.account !== txn.postings[index]?.account || posting.amount !== ((txn.postings[index]?.amount ?? 0) / 100).toFixed(2))
  );
  const shouldClose = () => !hasUnsavedChanges || confirm("有未保存的修改，确定关闭吗？");
  function save() {
    let parsedMetadata: Record<string, MetadataValue> = {};
    try {
      parsedMetadata = metadata.trim() ? JSON.parse(metadata) : {};
    } catch {
      alert("metadata 必须是合法 JSON 对象");
      return;
    }
    if (!parsedMetadata || Array.isArray(parsedMetadata) || typeof parsedMetadata !== "object") {
      alert("metadata 必须是 JSON 对象");
      return;
    }
    onUpdate?.(txn.source, { kind: "transaction", date, payee, narration, metadata: parsedMetadata, tags: tags.split(/\s+/).map((tag) => tag.replace(/^#/, "")).filter(Boolean), confidence: 1, needsReview: false, questions: [], postings: postings.map((p) => ({ account: p.account, amount: p.amount, currency: "CNY" })) });
    setEditing(false);
    onClose();
  }

  const footer = editing ? <div className="grid grid-cols-2 gap-2">
    <button className="border border-line bg-panel px-4 py-3" onClick={() => setEditing(false)}>取消</button>
    <button className="bg-brand px-4 py-3 text-paper" onClick={save}>保存修改</button>
  </div> : <div className="grid gap-2 sm:grid-cols-3">
    <button className="border border-line bg-panel px-4 py-3" onClick={() => setEditing(true)}>编辑</button>
    <button className="border border-line px-4 py-3 text-[var(--danger)]" onClick={() => { const reason = prompt("删除原因（会注释原交易，不会物理删除）", "记错/重复记账") ?? ""; if (confirm("确认注释删除这笔交易？")) onDelete?.(txn.source, reason); }}>注释删除</button>
    <button className="bg-brand px-4 py-3 text-paper" onClick={() => { const date = prompt("冲销日期", reverseDate) || reverseDate; onReverse?.(txn.source, date); }}>冲销</button>
  </div>;

  const body = <>
    <div className="mb-4 text-xs text-stone">{txn.source.file}:{txn.source.line}{txn.pending && <span className="ml-2 rounded-full bg-brand/10 px-2 py-0.5 text-brand">待同步修改</span>}</div>
    {editing ? <div className="grid gap-3">
          <input className="border border-line bg-panel p-3" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          <input className="border border-line bg-panel p-3" value={payee} onChange={(e) => setPayee(e.target.value)} />
          <input className="border border-line bg-panel p-3" value={narration} onChange={(e) => setNarration(e.target.value)} />
          <textarea className="min-h-28 border border-line bg-panel p-3 font-mono text-xs" value={metadata} onChange={(e) => setMetadata(e.target.value)} placeholder={'{"platform":"taobao","channel":"online"}'} />
          <input className="border border-line bg-panel p-3" value={tags} onChange={(e) => setTags(e.target.value)} placeholder="tags，用空格分隔，不需要 #" />
          {postings.map((p, i) => <div key={i} className="grid gap-2 sm:grid-cols-[1fr_140px]">
            <div>
              <select className="w-full border border-line bg-panel p-3" value={accountOptions.some((account) => account.account === p.account) ? p.account : ""} onChange={(e) => setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, account: e.target.value } : row))}>
                <option value="">选择账户 / 分类</option>
                {accountOptions.map((account) => <option key={account.account} value={account.account}>{optionLabel(account)}</option>)}
              </select>
              <input list={`txn-account-options-${i}`} className="mt-2 w-full border border-line bg-panel p-3 text-sm" value={p.account} placeholder="或手动输入账户" onChange={(e) => setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, account: e.target.value } : row))} />
              <datalist id={`txn-account-options-${i}`}>{accountOptions.map((account) => <option key={account.account} value={account.account}>{optionLabel(account)}</option>)}</datalist>
            </div>
            <input className="border border-line bg-panel p-3" inputMode="decimal" value={p.amount} onChange={(e) => setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, amount: e.target.value } : row))} />
          </div>)}
    </div> : <div>
      <div className="text-lg font-medium">{txn.date} {txn.payee}</div>
      <div className="text-olive">{txn.narration}</div>
      <MetadataBadges txn={txn} />
      <div className="mt-4 space-y-2">{txn.postings.map((p, i) => <div key={i} className="flex justify-between gap-3 rounded-xl border border-line bg-panel p-3 text-sm"><span className="min-w-0 truncate">{p.account}</span><strong className="shrink-0">{formatCny(p.amount / 100)}</strong></div>)}</div>
    </div>}
  </>;

  return <MobileSheet open title="流水详情" onClose={onClose} shouldClose={shouldClose} footer={footer}>{body}</MobileSheet>;
}
