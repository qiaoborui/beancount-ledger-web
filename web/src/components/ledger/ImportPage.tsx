"use client";

import { useMemo, useRef, useState } from "react";
import { AlertTriangle, CheckCircle, ChevronDown, ChevronUp, FileSpreadsheet, FileUp, Loader2, Pencil, PlusCircle, Sparkles, UploadCloud, X } from "lucide-react";
import { readJson } from "@/lib/clientFetch";
import { formatCny } from "@/lib/money";

type Provider = "alipay" | "wechat" | "cmb";
type ProviderOverride = "auto" | Provider;

type AccountOption = { account: string; label: string; group: string; active: boolean };
type ImportPosting = { account: string; amount: string; currency: string };
type ImportEntry = {
  id: string;
  date: string;
  flag: "*" | "!";
  payee: string;
  narration: string;
  source?: string;
  orderId?: string;
  merchantId?: string;
  payTime?: string;
  method?: string;
  txType?: string;
  status?: string;
  type?: string;
  categoryAccount: string;
  fundingAccount: string;
  amount: number;
  currency: string;
  metadata: Record<string, string>;
  postings: ImportPosting[];
};

type ImportPreview = {
  importId: string;
  provider: Provider;
  providerDetection: { provider: Provider; reason: string; confidence: "high" | "medium" | "low" };
  originalFilename: string;
  generatedBean: string;
  dedupReport: string;
  entries: ImportEntry[];
  accountOptions: AccountOption[];
  candidateCount: number;
  rawRowCount: number;
  filteredRowCount: number;
  generatedCount: number;
  excludedRowCount: number;
  skippedDuplicateCount: number;
  dateStart: string | null;
  dateEnd: string | null;
  warnings: string[];
  error?: string;
};

type CommitResult = { ok?: boolean; outputFile?: string; includeFile?: string; documentFile?: string; count?: number; beanText?: string; error?: string };
type NewCategoryAccount = { account: string; alias?: string };
type ImportCategorySuggestion = { entryId: string; categoryAccount: string; alias?: string; reason?: string; confidence?: number; isNew: boolean };
type ImportCategorySuggestionResult = { suggestions?: ImportCategorySuggestion[]; newAccounts?: NewCategoryAccount[]; error?: string };

function providerLabel(provider: Provider) {
  if (provider === "alipay") return "支付宝";
  if (provider === "wechat") return "微信支付";
  return "招商银行信用卡";
}

function fileSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

export function ImportPage({ onImported }: { onImported?: () => void }) {
  const inputRef = useRef<HTMLInputElement | null>(null);
  const [providerOverride, setProviderOverride] = useState<ProviderOverride>("auto");
  const [file, setFile] = useState<File | null>(null);
  const [alipayFundRounding, setAlipayFundRounding] = useState(false);
  const [preview, setPreview] = useState<ImportPreview | null>(null);
  const [entries, setEntries] = useState<ImportEntry[]>([]);
  const [commitResult, setCommitResult] = useState<CommitResult | null>(null);
  const [resultOpen, setResultOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [committing, setCommitting] = useState(false);
  const [error, setError] = useState("");
  const [suggesting, setSuggesting] = useState(false);
  const [suggestionMessage, setSuggestionMessage] = useState("");
  const [suggestedAccounts, setSuggestedAccounts] = useState<NewCategoryAccount[]>([]);
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [rawOpen, setRawOpen] = useState(false);

  const accountOptions = useMemo(() => {
    const accounts = preview?.accountOptions ?? [];
    const merged = accounts.filter((account) => account.active);
    for (const account of suggestedAccounts) {
      if (merged.some((item) => item.account === account.account)) continue;
      merged.push({ account: account.account, label: account.alias || account.account, group: account.account.startsWith("Income:") ? "income" : "expense", active: true });
    }
    return merged;
  }, [preview, suggestedAccounts]);

  const usedNewAccounts = useMemo(() => {
    const used = new Set(entries.map((entry) => entry.categoryAccount));
    return suggestedAccounts.filter((account) => used.has(account.account));
  }, [entries, suggestedAccounts]);

  function editableAccountLabel(entry: ImportEntry) {
    if (entry.categoryAccount.startsWith("Expenses:") || entry.categoryAccount.startsWith("Income:")) return "分类账户";
    return "对方账户";
  }

  function resetForFile(next: File | null) {
    setFile(next);
    setPreview(null);
    setEntries([]);
    setCommitResult(null);
    setResultOpen(false);
    setSuggestionMessage("");
    setSuggestedAccounts([]);
    setError("");
  }

  async function generatePreview() {
    if (!file) {
      setError("请先选择账单文件");
      return;
    }
    setLoading(true);
    setError("");
    setPreview(null);
    setEntries([]);
    setCommitResult(null);
    setResultOpen(false);
    try {
      const form = new FormData();
      if (providerOverride !== "auto") form.set("provider", providerOverride);
      form.set("file", file);
      form.set("alipayFundRounding", String(alipayFundRounding));
      const res = await fetch("/api/ledger/imports/preview", { method: "POST", body: form });
      const data = await readJson<ImportPreview>(res);
      if (!res.ok || data.error) throw new Error(data.error || "生成预览失败");
      setPreview(data);
      setEntries(data.entries);
      setSuggestedAccounts([]);
      setSuggestionMessage("");
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }

  async function commitImport() {
    if (!preview) return;
    setCommitting(true);
    setError("");
    setCommitResult(null);
    setResultOpen(false);
    try {
      const res = await fetch("/api/ledger/imports/commit", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ importId: preview.importId, provider: preview.provider, entries, newAccounts: usedNewAccounts, alipayFundRounding }),
      });
      const data = await readJson<CommitResult>(res);
      if (!res.ok || data.error) throw new Error(data.error || "写入失败");
      setCommitResult(data);
      setResultOpen(true);
      onImported?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setCommitting(false);
    }
  }

  async function suggestCategories() {
    if (!entries.length) return;
    setSuggesting(true);
    setError("");
    setSuggestionMessage("");
    try {
      const res = await fetch("/api/ai/import-categories", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ entries }),
      });
      const data = await readJson<ImportCategorySuggestionResult>(res);
      if (!res.ok || data.error) throw new Error(data.error || "AI 分类失败");
      const suggestions = data.suggestions ?? [];
      const suggestionMap = new Map(suggestions.map((item) => [item.entryId, item]));
      setEntries((current) => current.map((entry) => {
        const suggestion = suggestionMap.get(entry.id);
        return suggestion ? { ...entry, categoryAccount: suggestion.categoryAccount } : entry;
      }));
      setSuggestedAccounts((current) => mergeNewAccounts(current, data.newAccounts ?? []));
      const newCount = data.newAccounts?.length ?? 0;
      setSuggestionMessage(`AI 已更新 ${suggestions.length} 条分类${newCount ? `，建议新建 ${newCount} 个分类` : ""}`);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSuggesting(false);
    }
  }

  function updateEntry(id: string, patch: Partial<ImportEntry>) {
    setEntries((current) => current.map((entry) => (entry.id === id ? { ...entry, ...patch } : entry)));
  }

  function updateMetadata(id: string, key: string, value: string) {
    setEntries((current) => current.map((entry) => entry.id === id ? { ...entry, metadata: { ...entry.metadata, [key]: value } } : entry));
  }

  return (
    <div className="space-y-6">
      <section className="card p-5">
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h2 className="font-serif text-2xl">账单导入</h2>
            <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">上传支付宝 CSV、微信支付 XLSX 或招商银行信用卡 PDF，系统会自动识别来源、生成分录、去重，并在确认后把原始账单作为 Beancount document 保存到账本仓库。</p>
          </div>
          {preview && <div className="rounded-2xl border border-line bg-paper px-4 py-3 text-xs leading-5 text-stone">识别为：<span className="font-medium text-warm">{providerLabel(preview.provider)}</span><br />{preview.providerDetection.reason}</div>}
        </div>

        <div
          className="mt-5 cursor-pointer rounded-3xl border-2 border-dashed border-line bg-paper p-8 text-center transition hover:border-brand/60 hover:bg-panel"
          onClick={() => inputRef.current?.click()}
          onDragOver={(event) => event.preventDefault()}
          onDrop={(event) => { event.preventDefault(); resetForFile(event.dataTransfer.files?.[0] ?? null); }}
        >
          <input ref={inputRef} type="file" className="hidden" accept=".csv,.xlsx,.xls,.pdf" onChange={(event) => resetForFile(event.target.files?.[0] ?? null)} />
          <UploadCloud className="mx-auto h-10 w-10 text-brand" />
          <div className="mt-3 font-medium">拖拽账单到这里，或点击选择文件</div>
          <div className="mt-1 text-sm text-stone">支持支付宝 CSV、微信支付 XLSX/XLS、招商银行信用卡 PDF</div>
          {file && <div className="mx-auto mt-4 flex max-w-full items-center gap-2 rounded-2xl border border-line bg-panel px-4 py-2 text-left text-sm sm:inline-flex"><FileSpreadsheet className="h-4 w-4 shrink-0" /><span className="min-w-0 flex-1 break-all font-medium sm:max-w-md">{file.name}</span><span className="shrink-0 text-stone">{fileSize(file.size)}</span></div>}
        </div>

        <button className="mt-4 flex items-center gap-2 text-sm text-stone underline" onClick={() => setAdvancedOpen((value) => !value)}>{advancedOpen ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}高级选项</button>
        {advancedOpen && <div className="mt-3 grid gap-4 rounded-2xl border border-line bg-paper p-4 md:grid-cols-2">
          <label className="block text-sm"><span className="mb-1 block text-xs text-stone">账单来源覆盖</span><select className="w-full rounded-xl border border-line bg-panel px-3 py-2" value={providerOverride} onChange={(e) => setProviderOverride(e.target.value as ProviderOverride)}><option value="auto">自动识别</option><option value="alipay">支付宝 CSV</option><option value="wechat">微信支付 XLSX</option><option value="cmb">招商银行信用卡 PDF</option></select></label>
          <label className="flex items-start gap-3 text-sm"><input className="mt-1 h-4 w-4 accent-brand" type="checkbox" checked={alipayFundRounding} onChange={(event) => setAlipayFundRounding(event.target.checked)} /><span><span className="font-medium">支付宝基金 9.99 → 10.00 补差</span><span className="mt-1 block text-xs leading-5 text-stone">仅在确认该基金定投需要补 0.01 时开启。</span></span></label>
        </div>}

        <div className="mt-5 flex flex-wrap items-center gap-3">
          <button className="rounded-xl bg-brand px-5 py-3 text-paper disabled:opacity-60" onClick={generatePreview} disabled={loading || !file}>{loading ? <Loader2 className="mr-2 inline h-4 w-4 animate-spin" /> : <FileUp className="mr-2 inline h-4 w-4" />}生成预览</button>
        </div>
      </section>

      {error && <div className="rounded-2xl border border-line bg-panel p-4 text-sm text-[var(--danger)]"><AlertTriangle className="mr-2 inline h-4 w-4" />{error}</div>}

      {commitResult?.ok && resultOpen && <div className="fixed inset-0 z-[120] grid place-items-center bg-ink/35 p-4 backdrop-blur-sm" role="dialog" aria-modal="true" aria-labelledby="import-result-title">
        <section className="w-full max-w-lg rounded-3xl border border-line bg-paper p-5 shadow-2xl">
          <div className="flex items-start justify-between gap-4">
            <div>
              <h3 id="import-result-title" className="font-serif text-2xl text-brand"><CheckCircle className="mr-2 inline h-5 w-5" />导入完成</h3>
              <p className="mt-1 text-sm text-stone">账单已经写入 ledger，可以继续保存到 Git。</p>
            </div>
            <button className="rounded-xl border border-line bg-panel p-2 text-olive hover:bg-tag" onClick={() => setResultOpen(false)} aria-label="关闭导入结果"><X className="h-4 w-4" /></button>
          </div>
          <CommitResultDetails result={commitResult} />
          <button className="mt-5 w-full rounded-xl bg-brand px-4 py-3 text-paper" onClick={() => setResultOpen(false)}>知道了</button>
        </section>
      </div>}

      {preview && <section className="card p-5">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div><h3 className="font-serif text-xl">{providerLabel(preview.provider)}导入预览</h3><p className="mt-1 text-sm text-stone">{preview.originalFilename} · 去重后 {entries.length} 条新交易 · {preview.dateStart ?? "?"} ~ {preview.dateEnd ?? "?"}</p></div>
          <div className="flex flex-wrap items-center gap-2">
            <button className="rounded-xl border border-line bg-panel px-4 py-3 text-olive hover:bg-tag disabled:opacity-60" onClick={suggestCategories} disabled={suggesting || entries.length === 0 || commitResult?.ok === true}>{suggesting ? <Loader2 className="mr-2 inline h-4 w-4 animate-spin" /> : <Sparkles className="mr-2 inline h-4 w-4" />}AI 分类</button>
            <button className="rounded-xl bg-brand px-5 py-3 text-paper disabled:opacity-60" onClick={commitImport} disabled={committing || commitResult?.ok === true || entries.length === 0}>{committing ? <Loader2 className="mr-2 inline h-4 w-4 animate-spin" /> : null}确认写入账本</button>
          </div>
        </div>
        {(suggestionMessage || usedNewAccounts.length > 0) && <div className="mt-4 rounded-2xl border border-line bg-panel p-4 text-sm text-olive">
          {suggestionMessage && <div><Sparkles className="mr-2 inline h-4 w-4 text-brand" />{suggestionMessage}</div>}
          {usedNewAccounts.length > 0 && <div className="mt-3 flex flex-wrap gap-2">{usedNewAccounts.map((account) => <span key={account.account} className="inline-flex items-center gap-1 rounded-xl border border-line bg-paper px-3 py-1 text-xs"><PlusCircle className="h-3 w-3 text-brand" />{account.alias || account.account} · {account.account}</span>)}</div>}
        </div>}
        {commitResult?.ok && <div className="mt-4 rounded-2xl border border-brand/30 bg-[var(--selected-bg)] p-4 text-sm text-olive">
          <div className="font-medium text-brand"><CheckCircle className="mr-2 inline h-4 w-4" />已写入 {commitResult.count} 条交易</div>
          <div className="mt-1 text-stone">结果已弹出；关闭后仍可点击此处查看输出文件。</div>
          <button className="mt-3 rounded-xl border border-line bg-panel px-3 py-2 text-sm text-olive hover:bg-tag" onClick={() => setResultOpen(true)}>查看写入结果</button>
        </div>}
        {preview.warnings.length > 0 && <div className="mt-4 rounded-2xl border border-line bg-paper p-4 text-sm text-warm">{preview.warnings.map((warning) => <div key={warning}>⚠️ {warning}</div>)}</div>}
        {preview.provider === "cmb" && <div className="mt-4 grid gap-3 rounded-2xl border border-line bg-paper p-4 text-sm md:grid-cols-5"><div><div className="text-xs text-stone">PDF/CSV 明细</div><div className="font-medium">{preview.rawRowCount}</div></div><div><div className="text-xs text-stone">Web 前置过滤后</div><div className="font-medium">{preview.filteredRowCount}</div></div><div><div className="text-xs text-stone">DEG 生成</div><div className="font-medium">{preview.generatedCount}</div></div><div><div className="text-xs text-stone">已去重跳过</div><div className="font-medium">{preview.skippedDuplicateCount}</div></div><div><div className="text-xs text-stone">待确认写入</div><div className="font-medium">{entries.length}</div></div></div>}

        <div className="mt-5 space-y-3">
          {entries.map((entry) => <article key={entry.id} className="rounded-2xl border border-line bg-paper p-4">
            <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
              <div className="min-w-0 flex-1 space-y-3">
                <div className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2"><span className="rounded-full bg-panel px-2 py-1 text-xs text-stone">{entry.date}</span><span className="truncate font-medium" title={entry.payee || "未命名商户"}>{entry.payee || "未命名商户"}</span><span className="whitespace-nowrap text-sm font-medium text-warm">{formatCny(entry.amount)}</span></div>
                <div className="grid items-end gap-3 lg:grid-cols-[minmax(0,1fr)_360px]">
                  <label className="block text-xs text-stone">标题<input className="mt-1 w-full rounded-xl border border-line bg-panel px-3 py-2 text-sm text-ink" value={entry.narration} onChange={(e) => updateEntry(entry.id, { narration: e.target.value })} /></label>
                  <label className="block min-w-0 text-xs text-stone">{editableAccountLabel(entry)}<select className="mt-1 w-full rounded-xl border border-line bg-panel px-3 py-2 text-sm text-ink" value={entry.categoryAccount} onChange={(e) => updateEntry(entry.id, { categoryAccount: e.target.value })}>{accountOptions.map((account) => <option key={account.account} value={account.account}>{account.label} · {account.account}</option>)}</select></label>
                </div>
              </div>
            </div>
            <div className="mt-3 grid gap-3 text-xs text-stone md:grid-cols-3"><div>支付方式：{entry.method || "-"}</div><div>资金账户：{entry.fundingAccount || "-"}</div><div>订单号：{entry.orderId || "-"}</div></div>
            <details className="mt-3"><summary className="cursor-pointer text-xs text-stone"><Pencil className="mr-1 inline h-3 w-3" />备注 / metadata</summary><div className="mt-3 grid gap-2 md:grid-cols-2"><label className="text-xs text-stone">note<input className="mt-1 w-full rounded-xl border border-line bg-panel px-3 py-2 text-sm text-ink" value={entry.metadata.note ?? ""} onChange={(e) => updateMetadata(entry.id, "note", e.target.value)} placeholder="添加备注" /></label><label className="text-xs text-stone">purpose<input className="mt-1 w-full rounded-xl border border-line bg-panel px-3 py-2 text-sm text-ink" value={entry.metadata.purpose ?? ""} onChange={(e) => updateMetadata(entry.id, "purpose", e.target.value)} placeholder="例如: travel / work" /></label></div></details>
          </article>)}
        </div>

        <button className="mt-5 flex items-center gap-2 text-sm text-stone underline" onClick={() => setRawOpen((value) => !value)}>{rawOpen ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}查看原始输出 / dedup 报告</button>
        {rawOpen && <div className="mt-4 grid gap-4 lg:grid-cols-2"><pre className="max-h-96 overflow-auto rounded-2xl border border-line bg-ink p-4 text-xs leading-5 text-paper">{preview.dedupReport}</pre><pre className="max-h-96 overflow-auto rounded-2xl border border-line bg-ink p-4 text-xs leading-5 text-paper">{preview.generatedBean}</pre></div>}
      </section>}

    </div>
  );
}

function mergeNewAccounts(current: NewCategoryAccount[], incoming: NewCategoryAccount[]) {
  const byAccount = new Map(current.map((account) => [account.account, account]));
  for (const account of incoming) {
    if (!account.account) continue;
    byAccount.set(account.account, { ...byAccount.get(account.account), ...account });
  }
  return Array.from(byAccount.values()).sort((a, b) => a.account.localeCompare(b.account));
}

function CommitResultDetails({ result }: { result: CommitResult }) {
  return <div className="mt-4 space-y-2 rounded-2xl border border-line bg-panel p-4 text-sm text-olive">
    <div>写入交易：{result.count} 条</div>
    {result.outputFile && <div className="break-all">导入文件：{result.outputFile}</div>}
    {result.includeFile && <div className="break-all">月份 include：{result.includeFile}</div>}
    {result.documentFile && <div className="break-all">原始账单 document：{result.documentFile}</div>}
    <div className="text-stone">如需保存到远端，请点击右上角「保存到 Git」。</div>
  </div>;
}
