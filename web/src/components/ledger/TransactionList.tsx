import { useEffect, useMemo, useState } from "react";
import { formatCny } from "@/lib/money";
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

  return <section className="mt-6"><div className="mb-3 flex flex-col gap-3">
    {/* 搜索框 */}
    {searchable && setSearchQuery && (
      <input
        className="w-full rounded-xl border border-line bg-panel px-3 py-2 text-sm"
        placeholder="搜索商户名、说明、账户、metadata…（空格分多个关键词）"
        value={searchQuery ?? ""}
        onChange={(e) => setSearchQuery(e.target.value)}
      />
    )}
    <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex items-center gap-3">
        <h2 className="text-sm text-stone">账单明细{searchable && <span className="ml-2 text-stone">{rows.length} / {txns.length}</span>}</h2>
        {/* 视图切换 */}
        {searchable && setViewMode && (
          <div className="flex rounded-lg border border-line overflow-hidden">
            <button
              className={`px-2 py-0.5 text-xs transition-colors ${viewMode === "compact" ? "bg-brand text-paper" : "bg-panel text-warm hover:bg-tag"}`}
              onClick={() => setViewMode("compact")}
            >简洁</button>
            <button
              className={`px-2 py-0.5 text-xs transition-colors ${viewMode === "full" ? "bg-brand text-paper" : "bg-panel text-warm hover:bg-tag"}`}
              onClick={() => setViewMode("full")}
            >完整</button>
          </div>
        )}
      </div>
      {searchable && setCategoryQuery && (
        <div className="grid gap-2 sm:grid-cols-[minmax(0,1fr)_220px]">
          <div>
            <input list="txn-category-options" className="w-full rounded-xl border border-line bg-panel px-3 py-2 text-sm" placeholder="手动输入分类，如 Food / Expenses:Transport" value={categoryQuery ?? ""} onChange={(e) => setCategoryQuery(e.target.value)} />
            <datalist id="txn-category-options">{categories.map((category) => <option key={category} value={category} />)}</datalist>
          </div>
          <select className="w-full rounded-xl border border-line bg-panel px-3 py-2 text-sm" value={categories.includes(categoryQuery ?? "") ? categoryQuery : ""} onChange={(e) => setCategoryQuery(e.target.value)}><option value="">全部分类</option>{categories.map((category) => <option key={category} value={category}>{category}</option>)}</select>
        </div>
      )}
      {searchable && setMetadataQuery && (
        <div className="grid gap-2 sm:grid-cols-[minmax(0,1fr)_220px]">
          <div>
            <input list="txn-metadata-options" className="w-full rounded-xl border border-line bg-panel px-3 py-2 text-sm" placeholder="按 metadata/tag 筛选，如 platform:taobao person:妈妈 #trip" value={metadataQuery ?? ""} onChange={(e) => setMetadataQuery(e.target.value)} />
            <datalist id="txn-metadata-options">{metadataOptions.map((item) => <option key={item} value={item} />)}</datalist>
          </div>
          <select className="w-full rounded-xl border border-line bg-panel px-3 py-2 text-sm" value={metadataOptions.includes(metadataQuery ?? "") ? metadataQuery : ""} onChange={(e) => setMetadataQuery(e.target.value)}><option value="">全部 metadata</option>{metadataOptions.map((item) => <option key={item} value={item}>{item}</option>)}</select>
        </div>
      )}
    </div>
    {/* 分类筛选：匹配模式切换 + 提示 */}
    {searchable && setCategoryQuery && setMatchMode && categoryQuery && query && (
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
        <div className="flex rounded-lg border border-line overflow-hidden">
          <button
            className={`px-2 py-0.5 text-xs transition-colors ${matchMode === "prefix" ? "bg-brand text-paper" : "bg-panel text-warm hover:bg-tag"}`}
            onClick={() => setMatchMode("prefix")}
          >前缀匹配</button>
          <button
            className={`px-2 py-0.5 text-xs transition-colors ${matchMode === "exact" ? "bg-brand text-paper" : "bg-panel text-warm hover:bg-tag"}`}
            onClick={() => setMatchMode("exact")}
          >精确匹配</button>
        </div>
        {matchMode === "prefix" && (
          <span className="text-xs text-stone">{categoryQuery} 及其子分类 · {rows.length} 条</span>
        )}
      </div>
    )}
    {(searchable && categoryQuery && setCategoryQuery) || (searchable && searchQuery && setSearchQuery) || (searchable && metadataQuery && setMetadataQuery) ? <div className="flex flex-wrap gap-2">{categoryQuery && setCategoryQuery && <button className="self-start text-xs text-stone underline" onClick={() => setCategoryQuery("")}>清除分类筛选</button>}{metadataQuery && setMetadataQuery && <button className="self-start text-xs text-stone underline" onClick={() => setMetadataQuery("")}>清除 metadata 筛选</button>}{searchQuery && setSearchQuery && <button className="self-start text-xs text-stone underline" onClick={() => setSearchQuery("")}>清除搜索</button>}</div> : null}
  </div>
  {rows.length === 0 && <div className="card p-6 text-center text-sm text-stone">没有匹配的流水，换个分类关键词试试。</div>}
  {pageRows.map((t, i) => {
    const amt = primaryAmount(t);
    return (
      <button key={`${t.source.file}-${t.source.line}-${i}`} className="card mb-1.5 block w-full p-4 text-left" onClick={() => setSelected(t)}>
        <div className="flex items-baseline justify-between gap-3">
          <strong className="min-w-0 truncate">{t.payee}</strong>
          {amt != null && <span className={`shrink-0 font-medium tabular-nums ${amountColor(amt)}`}>{fmtTxnAmount(amt)}</span>}
        </div>
        <div className="mt-0.5 text-sm text-olive">{t.narration}</div>
        {viewMode === "full" ? (
          <>
            {/* 完整视图：显示借贷方流向 */}
            <PostingFlow postings={t.postings} />
            <MetadataBadges txn={t} limit={6} />
            <div className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-stone">{t.date}</div>
          </>
        ) : (
          <><div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-stone">{t.date}{t.postings.filter(p => p.account.startsWith("Expenses:") || p.account.startsWith("Income:")).map((p, j) => <span key={j}>{p.account}</span>)}</div><MetadataBadges txn={t} limit={3} /></>
        )}
      </button>
    );
  })}
  {rows.length > 0 && <div className="mt-4 flex flex-col gap-3 rounded-xl border border-line bg-panel p-3 text-sm sm:flex-row sm:items-center sm:justify-between"><div className="text-stone">第 {safePage} / {totalPages} 页，显示 {(safePage - 1) * pageSize + 1}-{Math.min(safePage * pageSize, rows.length)} 条</div><div className="flex items-center gap-2"><select className="rounded-xl border border-line bg-panel px-2 py-2" value={pageSize} onChange={(e) => setPageSize(Number(e.target.value))}><option value={10}>10 条/页</option><option value={20}>20 条/页</option><option value={50}>50 条/页</option><option value={100}>100 条/页</option></select><button className="rounded-xl border border-line px-3 py-2 disabled:opacity-40" disabled={safePage <= 1} onClick={() => setPage((value) => Math.max(1, value - 1))}>上一页</button><button className="rounded-xl border border-line px-3 py-2 disabled:opacity-40" disabled={safePage >= totalPages} onClick={() => setPage((value) => Math.min(totalPages, value + 1))}>下一页</button></div></div>}
  {selected && <TransactionDrawer txn={selected} accounts={accounts} onClose={() => setSelected(null)} onUpdate={onUpdate} onDelete={(source, reason) => { onDelete?.(source, reason); setSelected(null); }} onReverse={(source, date) => { onReverse?.(source, date); setSelected(null); }} />}
  </section>;
}

function TransactionDrawer({ txn, accounts, onClose, onUpdate, onDelete, onReverse }: { txn: Txn; accounts: AccountView[]; onClose: () => void; onUpdate?: (source: Txn["source"], entry: ParsedTransaction) => void; onDelete?: (source: Txn["source"], reason: string) => void; onReverse?: (source: Txn["source"], date: string) => void }) {
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
    onUpdate?.(txn.source, { kind: "transaction", date, payee, narration, metadata: parsedMetadata, tags: tags.split(/\s+/).map((tag) => tag.replace(/^#/, "")).filter(Boolean), confidence: 1, needsReview: false, questions: [], postings: postings.map((p) => ({ account: p.account, amount: p.amount, currency: "CNY" })) }); setEditing(false); onClose(); }
  return <div className="sheet-backdrop fixed inset-0 z-40 flex items-end justify-end bg-ink/35 sm:items-stretch"><div className="mobile-sheet kami-float h-[92dvh] w-full overflow-y-auto rounded-t-[28px] bg-paper px-5 pb-[calc(env(safe-area-inset-bottom)+1.25rem)] pt-5 sm:h-full sm:max-w-xl sm:rounded-none sm:pb-5 sm:pt-[calc(env(safe-area-inset-top)+1.25rem)]"><div className="flex items-center justify-between"><h2 className="font-serif text-2xl">流水详情</h2><button className="rounded-xl border border-line px-3 py-1 text-sm" onClick={onClose}>关闭</button></div><div className="mt-4 text-xs text-stone">{txn.source.file}:{txn.source.line}</div>{editing ? <div className="mt-4 grid gap-3"><input className="border border-line bg-panel p-3" type="date" value={date} onChange={(e) => setDate(e.target.value)} /><input className="border border-line bg-panel p-3" value={payee} onChange={(e) => setPayee(e.target.value)} /><input className="border border-line bg-panel p-3" value={narration} onChange={(e) => setNarration(e.target.value)} /><textarea className="min-h-28 border border-line bg-panel p-3 font-mono text-xs" value={metadata} onChange={(e) => setMetadata(e.target.value)} placeholder={'{"platform":"taobao","channel":"online"}'} /><input className="border border-line bg-panel p-3" value={tags} onChange={(e) => setTags(e.target.value)} placeholder="tags，用空格分隔，不需要 #" />{postings.map((p, i) => <div key={i} className="grid gap-2 sm:grid-cols-[1fr_140px]"><div><select className="w-full border border-line bg-panel p-3" value={accountOptions.some((account) => account.account === p.account) ? p.account : ""} onChange={(e) => setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, account: e.target.value } : row))}><option value="">选择账户 / 分类</option>{accountOptions.map((account) => <option key={account.account} value={account.account}>{optionLabel(account)}</option>)}</select><input list={`txn-account-options-${i}`} className="mt-2 w-full border border-line bg-panel p-3 text-sm" value={p.account} placeholder="或手动输入账户" onChange={(e) => setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, account: e.target.value } : row))} /><datalist id={`txn-account-options-${i}`}>{accountOptions.map((account) => <option key={account.account} value={account.account}>{optionLabel(account)}</option>)}</datalist></div><input className="border border-line bg-panel p-3" inputMode="decimal" value={p.amount} onChange={(e) => setPostings((rows) => rows.map((row, idx) => idx === i ? { ...row, amount: e.target.value } : row))} /></div>)}<button className="bg-brand px-4 py-3 text-paper" onClick={save}>保存修改</button></div> : <div className="mt-4"><div className="text-lg font-medium">{txn.date} {txn.payee}</div><div className="text-olive">{txn.narration}</div><MetadataBadges txn={txn} /><div className="mt-4 space-y-2">{txn.postings.map((p, i) => <div key={i} className="flex justify-between gap-3 rounded-xl border border-line bg-panel p-3 text-sm"><span className="min-w-0 truncate">{p.account}</span><strong className="shrink-0">{formatCny(p.amount / 100)}</strong></div>)}</div><div className="mt-5 grid gap-2 sm:grid-cols-3"><button className="border border-line bg-panel px-4 py-3" onClick={() => setEditing(true)}>编辑</button><button className="border border-line px-4 py-3 text-[var(--danger)]" onClick={() => { const reason = prompt("删除原因（会注释原交易，不会物理删除）", "记错/重复记账") ?? ""; if (confirm("确认注释删除这笔交易？")) onDelete?.(txn.source, reason); }}>注释删除</button><button className="bg-brand px-4 py-3 text-paper" onClick={() => { const date = prompt("冲销日期", reverseDate) || reverseDate; onReverse?.(txn.source, date); }}>冲销</button></div></div>}</div></div>;
}
