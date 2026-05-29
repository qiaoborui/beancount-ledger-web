"use client";

import { useMemo, useRef, useState } from "react";
import { AlertTriangle, CheckCircle, ChevronDown, ChevronUp, FileSpreadsheet, FileUp, Loader2, Pencil, UploadCloud } from "lucide-react";
import { readJson } from "@/lib/clientFetch";
import { formatCny } from "@/lib/money";
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
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [rawOpen, setRawOpen] = useState(false);

  const accountOptions = useMemo(() => {
    const accounts = preview?.accountOptions ?? [];
    return accounts.filter((account) => account.active);
  }, [preview]);

  function editableAccountLabel(entry: ImportEntry) {
    if (entry.categoryAccount.startsWith("Expenses:") || entry.categoryAccount.startsWith("Income:")) return "分类账户";
    return "对方账户";
  }

  function categoryAccountOptions(entry: ImportEntry) {
    if (!entry.categoryAccount || accountOptions.some((account) => account.account === entry.categoryAccount)) return accountOptions;
    return [{ account: entry.categoryAccount, label: entry.categoryAccount, group: "current", active: true }, ...accountOptions];
  }

  function resetForFile(next: File | null) {
    setFile(next);
    setPreview(null);
    setEntries([]);
    setCommitResult(null);
    setResultOpen(false);
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
        body: JSON.stringify({ importId: preview.importId, provider: preview.provider, entries, alipayFundRounding }),
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

        <Button variant="ghost" className="mt-4 h-auto gap-2 px-0 py-0 text-sm text-stone underline hover:bg-transparent" onClick={() => setAdvancedOpen((value) => !value)}>{advancedOpen ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}高级选项</Button>
        {advancedOpen && <div className="mt-3 grid gap-4 rounded-2xl border border-line bg-paper p-4 md:grid-cols-2">
          <label className="block text-sm">
            <span className="mb-1 block text-xs text-stone">账单来源覆盖</span>
            <Select value={providerOverride} onValueChange={(value) => setProviderOverride(value as ProviderOverride)}>
              <SelectTrigger className="h-10 w-full rounded-xl bg-panel">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="auto">自动识别</SelectItem>
                <SelectItem value="alipay">支付宝 CSV</SelectItem>
                <SelectItem value="wechat">微信支付 XLSX</SelectItem>
                <SelectItem value="cmb">招商银行信用卡 PDF</SelectItem>
              </SelectContent>
            </Select>
          </label>
          <div className="flex items-start gap-3 text-sm">
            <Checkbox id="alipay-fund-rounding" className="mt-1" checked={alipayFundRounding} onCheckedChange={(value) => setAlipayFundRounding(value === true)} />
            <label htmlFor="alipay-fund-rounding" className="cursor-pointer"><span className="font-medium">支付宝基金 9.99 → 10.00 补差</span><span className="mt-1 block text-xs leading-5 text-stone">仅在确认该基金定投需要补 0.01 时开启。</span></label>
          </div>
        </div>}

        <div className="mt-5 flex flex-wrap items-center gap-3">
          <Button className="h-12 rounded-xl px-5" onClick={generatePreview} disabled={loading || !file}>{loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <FileUp className="h-4 w-4" />}生成预览</Button>
        </div>
      </section>

      {error && <Alert variant="destructive" className="rounded-2xl bg-panel"><AlertTriangle /><AlertDescription>{error}</AlertDescription></Alert>}

      {preview && <section className="card p-5">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div><h3 className="font-serif text-xl">{providerLabel(preview.provider)}导入预览</h3><p className="mt-1 text-sm text-stone">{preview.originalFilename} · 去重后 {entries.length} 条新交易 · {preview.dateStart ?? "?"} ~ {preview.dateEnd ?? "?"}</p></div>
          <Button className="h-12 rounded-xl px-5" onClick={commitImport} disabled={committing || commitResult?.ok === true || entries.length === 0}>{committing ? <Loader2 className="h-4 w-4 animate-spin" /> : null}确认写入账本</Button>
        </div>
        {commitResult?.ok && <div className="mt-4 rounded-2xl border border-brand/30 bg-[var(--selected-bg)] p-4 text-sm text-olive">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <div className="font-medium text-brand"><CheckCircle className="mr-2 inline h-4 w-4" />已写入 {commitResult.count} 条交易</div>
              <div className="mt-1 text-stone">账单已经写入 ledger，可以继续保存到 Git。</div>
            </div>
            <Button variant="outline" className="shrink-0 rounded-xl bg-panel text-olive" onClick={() => setResultOpen((open) => !open)}>
              {resultOpen ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
              {resultOpen ? "收起结果" : "查看写入结果"}
            </Button>
          </div>
          {resultOpen && <CommitResultDetails result={commitResult} />}
        </div>}
        {preview.warnings.length > 0 && <div className="mt-4 rounded-2xl border border-line bg-paper p-4 text-sm text-warm">{preview.warnings.map((warning) => <div key={warning}>⚠️ {warning}</div>)}</div>}
        {preview.provider === "cmb" && <div className="mt-4 grid gap-3 rounded-2xl border border-line bg-paper p-4 text-sm md:grid-cols-5"><div><div className="text-xs text-stone">PDF/CSV 明细</div><div className="font-medium">{preview.rawRowCount}</div></div><div><div className="text-xs text-stone">Web 前置过滤后</div><div className="font-medium">{preview.filteredRowCount}</div></div><div><div className="text-xs text-stone">DEG 生成</div><div className="font-medium">{preview.generatedCount}</div></div><div><div className="text-xs text-stone">已去重跳过</div><div className="font-medium">{preview.skippedDuplicateCount}</div></div><div><div className="text-xs text-stone">待确认写入</div><div className="font-medium">{entries.length}</div></div></div>}

        <div className="mt-5 space-y-3">
          {entries.map((entry) => <article key={entry.id} className="rounded-2xl border border-line bg-paper p-4">
            <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
              <div className="min-w-0 flex-1 space-y-3">
                <div className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2"><span className="rounded-full bg-panel px-2 py-1 text-xs text-stone">{entry.date}</span><span className="truncate font-medium" title={entry.payee || "未命名商户"}>{entry.payee || "未命名商户"}</span><span className="whitespace-nowrap text-sm font-medium text-warm">{formatCny(entry.amount)}</span></div>
                <div className="grid items-end gap-3 lg:grid-cols-[minmax(0,1fr)_360px]">
                  <label className="block text-xs text-stone">标题<Input className="mt-1 h-10 rounded-xl bg-panel text-sm text-ink" value={entry.narration} onChange={(e) => updateEntry(entry.id, { narration: e.target.value })} /></label>
                  <label className="block min-w-0 text-xs text-stone">
                    {editableAccountLabel(entry)}
                    <Select value={entry.categoryAccount} onValueChange={(value) => updateEntry(entry.id, { categoryAccount: value })}>
                      <SelectTrigger className="mt-1 h-10 w-full rounded-xl bg-panel text-sm text-ink">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent className="max-h-80">
                        {categoryAccountOptions(entry).map((account) => <SelectItem key={account.account} value={account.account}>{account.label} · {account.account}</SelectItem>)}
                      </SelectContent>
                    </Select>
                  </label>
                </div>
              </div>
            </div>
            <div className="mt-3 grid gap-3 text-xs text-stone md:grid-cols-3"><div>支付方式：{entry.method || "-"}</div><div>资金账户：{entry.fundingAccount || "-"}</div><div>订单号：{entry.orderId || "-"}</div></div>
            <details className="mt-3"><summary className="cursor-pointer text-xs text-stone"><Pencil className="mr-1 inline h-3 w-3" />备注 / metadata</summary><div className="mt-3 grid gap-2 md:grid-cols-2"><label className="text-xs text-stone">note<Input className="mt-1 h-10 rounded-xl bg-panel text-sm text-ink" value={entry.metadata.note ?? ""} onChange={(e) => updateMetadata(entry.id, "note", e.target.value)} placeholder="添加备注" /></label><label className="text-xs text-stone">purpose<Input className="mt-1 h-10 rounded-xl bg-panel text-sm text-ink" value={entry.metadata.purpose ?? ""} onChange={(e) => updateMetadata(entry.id, "purpose", e.target.value)} placeholder="例如: travel / work" /></label></div></details>
          </article>)}
        </div>

        <Button variant="ghost" className="mt-5 h-auto gap-2 px-0 py-0 text-sm text-stone underline hover:bg-transparent" onClick={() => setRawOpen((value) => !value)}>{rawOpen ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}查看原始输出 / dedup 报告</Button>
        {rawOpen && <div className="mt-4 grid gap-4 lg:grid-cols-2"><pre className="max-h-96 overflow-auto rounded-2xl border border-line bg-ink p-4 text-xs leading-5 text-paper">{preview.dedupReport}</pre><pre className="max-h-96 overflow-auto rounded-2xl border border-line bg-ink p-4 text-xs leading-5 text-paper">{preview.generatedBean}</pre></div>}
      </section>}

    </div>
  );
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
