"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { AlertTriangle, Check, CheckCircle, ChevronDown, ChevronUp, FileArchive, FileSpreadsheet, FileUp, Loader2, Pencil, ShieldCheck, UploadCloud } from "lucide-react";
import { readJson } from "@/lib/clientFetch";
import { formatCny } from "@/lib/money";
import { cn } from "@/lib/utils";
import { Alert } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Separator } from "@/components/ui/separator";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { formatAccountOptionLabel } from "./accountDisplay";
import { MobileSheet } from "./MobileSheet";

type Provider = "alipay" | "wechat" | "cmb";
type ProviderOverride = "auto" | Provider;

type AccountOption = { account: string; alias?: string | null; label: string; group: string; active: boolean };
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
type ImportDraft = {
  savedAt: number;
  providerOverride: ProviderOverride;
  alipayFundRounding: boolean;
  preview: ImportPreview;
  entries: ImportEntry[];
};

const importDraftKey = "ledger_import_review_draft";

const providerChoices: { value: ProviderOverride; label: string; detail: string; accept: string }[] = [
  { value: "auto", label: "自动识别", detail: "按文件头和扩展名检测来源", accept: "CSV / XLSX / PDF" },
  { value: "alipay", label: "支付宝", detail: "CSV 账单，支持基金补差选项", accept: ".csv" },
  { value: "wechat", label: "微信支付", detail: "微信支付导出的明细表", accept: ".xlsx / .xls" },
  { value: "cmb", label: "招商银行", detail: "信用卡 PDF 或已转换 CSV", accept: ".pdf / .csv" },
];

function providerLabel(provider: Provider) {
  if (provider === "alipay") return "支付宝";
  if (provider === "wechat") return "微信支付";
  return "招商银行信用卡";
}

function confidenceLabel(confidence: ImportPreview["providerDetection"]["confidence"]) {
  if (confidence === "high") return "高置信";
  if (confidence === "medium") return "中置信";
  return "低置信";
}

function fileSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function readImportDraft(): ImportDraft | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = localStorage.getItem(importDraftKey);
    if (!raw) return null;
    const draft = JSON.parse(raw) as Partial<ImportDraft>;
    if (!draft.preview?.importId || !Array.isArray(draft.entries)) return null;
    return {
      savedAt: typeof draft.savedAt === "number" ? draft.savedAt : Date.now(),
      providerOverride: draft.providerOverride ?? "auto",
      alipayFundRounding: Boolean(draft.alipayFundRounding),
      preview: draft.preview,
      entries: draft.entries,
    };
  } catch {
    return null;
  }
}

function writeImportDraft(draft: ImportDraft | null) {
  if (typeof window === "undefined") return;
  try {
    if (!draft) localStorage.removeItem(importDraftKey);
    else localStorage.setItem(importDraftKey, JSON.stringify(draft));
  } catch {
    // Storage can be unavailable or full for large imports; the in-memory review still works.
  }
}

export function ImportPage({ onImported }: { onImported?: () => void }) {
  const inputRef = useRef<HTMLInputElement | null>(null);
  const [providerOverride, setProviderOverride] = useState<ProviderOverride>("auto");
  const [file, setFile] = useState<File | null>(null);
  const [dragActive, setDragActive] = useState(false);
  const [alipayFundRounding, setAlipayFundRounding] = useState(false);
  const [preview, setPreview] = useState<ImportPreview | null>(null);
  const [entries, setEntries] = useState<ImportEntry[]>([]);
  const [commitResult, setCommitResult] = useState<CommitResult | null>(null);
  const [resultOpen, setResultOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [committing, setCommitting] = useState(false);
  const [error, setError] = useState("");
  const [providerOpen, setProviderOpen] = useState(false);
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [rawOpen, setRawOpen] = useState(false);
  const [reviewOpen, setReviewOpen] = useState(false);

  const accountOptions = useMemo(() => {
    const accounts = preview?.accountOptions ?? [];
    return accounts.filter((account) => account.active);
  }, [preview]);

  const selectedProvider = providerChoices.find((choice) => choice.value === providerOverride) ?? providerChoices[0];
  const hasCommitted = commitResult?.ok === true;
  const canCommit = Boolean(preview) && entries.length > 0 && !committing && !hasCommitted;

  useEffect(() => {
    const draft = readImportDraft();
    if (!draft) return;
    setProviderOverride(draft.providerOverride);
    setAlipayFundRounding(draft.alipayFundRounding);
    setPreview(draft.preview);
    setEntries(draft.entries);
    setReviewOpen(true);
  }, []);

  useEffect(() => {
    if (!preview || hasCommitted) return;
    writeImportDraft({ savedAt: Date.now(), providerOverride, alipayFundRounding, preview, entries });
  }, [alipayFundRounding, entries, hasCommitted, preview, providerOverride]);

  function editableAccountLabel(entry: ImportEntry) {
    if (entry.categoryAccount.startsWith("Expenses:") || entry.categoryAccount.startsWith("Income:")) return "分类账户";
    return "对方账户";
  }

  function categoryAccountOptions(entry: ImportEntry) {
    if (!entry.categoryAccount || accountOptions.some((account) => account.account === entry.categoryAccount)) return accountOptions;
    const previewAccount = preview?.accountOptions.find((account) => account.account === entry.categoryAccount);
    return [previewAccount ?? { account: entry.categoryAccount, label: entry.categoryAccount, group: "current", active: true }, ...accountOptions];
  }

  function resetForFile(next: File | null) {
    setFile(next);
    setPreview(null);
    setEntries([]);
    setCommitResult(null);
    setResultOpen(false);
    setReviewOpen(false);
    setError("");
    writeImportDraft(null);
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
      setReviewOpen(true);
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
      setReviewOpen(true);
      writeImportDraft(null);
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
    setEntries((current) => current.map((entry) => (entry.id === id ? { ...entry, metadata: { ...entry.metadata, [key]: value } } : entry)));
  }

  return (
    <div className="mx-auto min-w-0 max-w-[1220px] space-y-5 overflow-hidden">
      <Card className="min-w-0 overflow-hidden border-line bg-panel shadow-sm">
        <CardContent className="grid min-w-0 items-stretch gap-5 bg-paper/45 px-4 py-4 sm:px-6 lg:min-h-[calc(100dvh-18.25rem)] lg:grid-cols-[minmax(0,1fr)_minmax(0,340px)] xl:grid-cols-[minmax(0,1fr)_minmax(0,360px)]">
          <div className="min-w-0 lg:flex">
            <div
              role="button"
              tabIndex={0}
              className={cn(
                "group flex min-h-56 min-w-0 cursor-pointer flex-col items-center justify-center rounded-2xl border border-dashed border-line bg-panel p-4 text-center outline-none transition focus-visible:ring-2 focus-visible:ring-[var(--focus-ring)] sm:min-h-[18rem] sm:p-6 lg:min-h-full lg:w-full",
                dragActive ? "border-brand bg-[var(--selected-bg)]" : "hover:border-brand/60 hover:bg-panel",
              )}
              onClick={() => inputRef.current?.click()}
              onKeyDown={(event) => {
                if (event.key === "Enter" || event.key === " ") inputRef.current?.click();
              }}
              onDragEnter={(event) => {
                event.preventDefault();
                setDragActive(true);
              }}
              onDragOver={(event) => event.preventDefault()}
              onDragLeave={() => setDragActive(false)}
              onDrop={(event) => {
                event.preventDefault();
                setDragActive(false);
                resetForFile(event.dataTransfer.files?.[0] ?? null);
              }}
            >
              <input ref={inputRef} type="file" className="hidden" accept=".csv,.xlsx,.xls,.pdf" onChange={(event) => resetForFile(event.target.files?.[0] ?? null)} />
              <div className="grid h-14 w-14 place-items-center rounded-2xl border border-line bg-panel text-brand shadow-sm transition group-hover:scale-105">
                <UploadCloud className="h-7 w-7" />
              </div>
              <div className="mt-4 text-base font-medium leading-6 text-ink">拖拽账单到这里，或点击选择文件</div>
              <div className="mt-1 max-w-full break-words text-sm text-stone">当前模式：{selectedProvider.label} · {selectedProvider.accept}</div>
              {file ? (
                <div className="mt-5 flex w-full max-w-full items-center gap-3 rounded-2xl border border-line bg-panel px-3 py-3 text-left text-sm sm:w-auto sm:px-4">
                  <FileSpreadsheet className="h-5 w-5 shrink-0 text-brand" />
                  <div className="min-w-0 flex-1">
                    <div className="line-clamp-2 break-all font-medium leading-5 text-warm">{file.name}</div>
                    <div className="mt-0.5 text-xs text-stone">{fileSize(file.size)}</div>
                  </div>
                </div>
              ) : null}
            </div>
          </div>

          <div className="grid min-w-0 max-w-full grid-rows-[auto_auto_auto_auto] gap-4 overflow-hidden">
            <div className="min-w-0 max-w-full overflow-hidden rounded-2xl border border-line bg-paper">
              <button type="button" className="flex w-full min-w-0 items-center justify-between gap-3 px-4 py-3 text-left" onClick={() => setProviderOpen((value) => !value)}>
                <span className="min-w-0 flex-1 overflow-hidden">
                  <span className="block truncate font-medium text-ink">来源设置：{selectedProvider.label}</span>
                  <span className="mt-1 block truncate text-xs text-stone">{selectedProvider.detail}</span>
                </span>
                {providerOpen ? <ChevronUp className="h-4 w-4 shrink-0 text-stone" /> : <ChevronDown className="h-4 w-4 shrink-0 text-stone" />}
              </button>
              {providerOpen ? (
                <div className="grid min-w-0 gap-2 border-t border-line p-3">
                  {providerChoices.map((choice) => (
                    <button
                      key={choice.value}
                      type="button"
                      className={cn(
                        "min-w-0 rounded-2xl border p-3 text-left transition",
                        providerOverride === choice.value ? "border-brand bg-[var(--selected-bg)] text-ink" : "border-line bg-panel text-olive hover:bg-paper",
                      )}
                      onClick={() => {
                        setProviderOverride(choice.value);
                        setProviderOpen(false);
                      }}
                    >
                      <div className="flex items-center justify-between gap-2">
                        <span className="font-medium">{choice.label}</span>
                        {providerOverride === choice.value ? <Check className="h-4 w-4 text-brand" /> : null}
                      </div>
                      <div className="mt-1 break-words text-xs leading-5 text-stone">{choice.detail}</div>
                    </button>
                  ))}
                </div>
              ) : null}
            </div>

            <div className="min-w-0 max-w-full overflow-hidden rounded-2xl border border-line bg-paper p-4">
              <div className="flex items-center justify-between gap-3">
                <div className="min-w-0">
                  <div className="text-sm font-medium text-ink">导入流程</div>
                  <div className="mt-1 text-xs text-stone">预览、校对、写入，三步分开确认。</div>
                </div>
                <FileArchive className="h-5 w-5 text-brand" />
              </div>
              <Separator className="my-4" />
              <ImportStep index={1} title="选择来源" active done={Boolean(file)} detail={file ? file.name : "等待上传账单文件"} />
              <ImportStep index={2} title="生成预览" active={loading || Boolean(preview)} done={Boolean(preview)} detail={preview ? `${entries.length} 条待写入交易` : "运行格式转换和去重检查"} />
              <ImportStep index={3} title="写入账本" active={committing || hasCommitted} done={hasCommitted} detail={hasCommitted ? `已写入 ${commitResult?.count ?? 0} 条` : "确认后追加到私有账本"} />
            </div>

            <div className="min-w-0 max-w-full overflow-hidden rounded-2xl border border-line bg-paper p-4">
              <button type="button" className="flex w-full min-w-0 items-center justify-between gap-3 text-left" onClick={() => setAdvancedOpen((value) => !value)}>
                <span className="min-w-0 flex-1 overflow-hidden">
                  <span className="block text-sm font-medium text-ink">高级选项</span>
                  <span className="mt-1 block truncate text-xs text-stone">仅在导入规则需要人工覆盖时使用。</span>
                </span>
                {advancedOpen ? <ChevronUp className="h-4 w-4 text-stone" /> : <ChevronDown className="h-4 w-4 text-stone" />}
              </button>
              {advancedOpen ? (
                <div className="mt-4 space-y-4">
                  <Label className="block">
                    <span className="mb-2 block">账单来源覆盖</span>
                    <Select value={providerOverride} onValueChange={(value) => setProviderOverride(value as ProviderOverride)}>
                      <SelectTrigger className="h-10 w-full min-w-0 rounded-xl bg-panel text-sm text-ink">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        {providerChoices.map((choice) => <SelectItem key={choice.value} value={choice.value}>{choice.label}</SelectItem>)}
                      </SelectContent>
                    </Select>
                  </Label>
                  <div className="flex items-start gap-3 rounded-2xl border border-line bg-panel p-3 text-sm">
                    <Checkbox id="alipay-fund-rounding" className="mt-1" checked={alipayFundRounding} onCheckedChange={(value) => setAlipayFundRounding(value === true)} />
                    <label htmlFor="alipay-fund-rounding" className="cursor-pointer">
                      <span className="font-medium text-warm">支付宝基金 9.99 → 10.00 补差</span>
                      <span className="mt-1 block text-xs leading-5 text-stone">仅在确认该基金定投需要补 0.01 时开启。</span>
                    </label>
                  </div>
                </div>
              ) : null}
            </div>

            <div className="min-w-0 max-w-full overflow-hidden rounded-2xl border border-line bg-panel p-3">
              <Button className="w-full" size="lg" onClick={generatePreview} disabled={loading || !file}>
                {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <FileUp className="h-4 w-4" />}
                生成预览
              </Button>
            </div>
          </div>
        </CardContent>
      </Card>

      {error ? (
        <Alert variant="destructive" className="flex items-start gap-2">
          <AlertTriangle className="mt-1 h-4 w-4 shrink-0" />
          <span>{error}</span>
        </Alert>
      ) : null}

      {preview ? (
        <Card className="min-w-0 overflow-hidden border-line bg-panel shadow-sm">
          <CardContent className="flex min-w-0 flex-col gap-4 p-4 sm:p-5 lg:flex-row lg:items-center lg:justify-between">
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-2">
                <Badge variant="outline" className={hasCommitted ? "border-brand/30 bg-[var(--selected-bg)] text-brand" : undefined}>{hasCommitted ? "已写入" : "待审核"}</Badge>
                <Badge variant="secondary">{providerLabel(preview.provider)}</Badge>
                <span className="text-sm text-stone">{entries.length} 条交易</span>
              </div>
              <div className="mt-2 line-clamp-2 break-all font-medium text-ink">{preview.originalFilename}</div>
              <div className="mt-1 text-sm text-stone">{preview.dateStart ?? "?"} 到 {preview.dateEnd ?? "?"}</div>
            </div>
            <Button onClick={() => setReviewOpen(true)} variant={hasCommitted ? "secondary" : "default"}>
              {hasCommitted ? <CheckCircle className="h-4 w-4" /> : <ShieldCheck className="h-4 w-4" />}
              {hasCommitted ? "查看写入结果" : "打开审核"}
            </Button>
          </CardContent>
        </Card>
      ) : null}

      {preview ? (
        <MobileSheet
          open={reviewOpen}
          title={`${providerLabel(preview.provider)}导入审核`}
          onClose={() => setReviewOpen(false)}
          shouldClose={() => !committing}
          size="xl"
          align="center"
          closeLabel={committing ? "写入中" : "关闭"}
          footer={
            <div className="flex min-w-0 flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div className="min-w-0 text-xs leading-5 text-stone">
                {hasCommitted ? `已写入 ${commitResult?.count ?? 0} 条交易` : `确认后将写入 ${entries.length} 条交易，写入前仍可修改标题、分类和 metadata。`}
              </div>
              <div className="grid w-full min-w-0 grid-cols-2 gap-2 sm:w-auto sm:grid-cols-[auto_auto]">
                <Button className="min-w-0 sm:min-w-32" variant="outline" onClick={() => setReviewOpen(false)} disabled={committing}>稍后处理</Button>
                <Button className="min-w-0 sm:min-w-36" onClick={commitImport} disabled={!canCommit}>
                  {committing ? <Loader2 className="h-4 w-4 animate-spin" /> : hasCommitted ? <CheckCircle className="h-4 w-4" /> : <ShieldCheck className="h-4 w-4" />}
                  {committing ? "正在写入..." : hasCommitted ? "已写入" : "确认写入账本"}
                </Button>
              </div>
            </div>
          }
        >
          <div className="-mx-4 -my-4 min-w-0 space-y-4 bg-sand/45 px-3 py-4 sm:-mx-5 sm:px-5">
            <div className="rounded-2xl border border-line bg-panel p-4 shadow-sm">
              <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge variant="outline">{confidenceLabel(preview.providerDetection.confidence)}</Badge>
                    <Badge variant="secondary" className="max-w-full break-all leading-5 sm:max-w-xl">{preview.originalFilename}</Badge>
                  </div>
                  <div className="mt-2 text-sm leading-6 text-olive">{preview.providerDetection.reason}</div>
                </div>
                <div className="shrink-0 rounded-2xl border border-line bg-paper px-4 py-3 text-sm text-stone">
                  {preview.dateStart ?? "?"} ~ {preview.dateEnd ?? "?"}
                </div>
              </div>
            </div>

            <ImportStats preview={preview} entryCount={entries.length} />

            {commitResult?.ok ? (
              <Alert className="border-brand/30 bg-[var(--selected-bg)] text-olive">
                <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                  <div>
                    <div className="font-medium text-brand"><CheckCircle className="mr-2 inline h-4 w-4" />已写入 {commitResult.count} 条交易</div>
                    <div className="mt-1 text-stone">账单已经写入 ledger，可以继续保存到 Git。</div>
                  </div>
                  <Button variant="outline" size="sm" onClick={() => setResultOpen((open) => !open)}>
                    {resultOpen ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
                    {resultOpen ? "收起结果" : "查看写入结果"}
                  </Button>
                </div>
                {resultOpen ? <CommitResultDetails result={commitResult} /> : null}
              </Alert>
            ) : null}

            {preview.warnings.length > 0 ? (
              <Alert className="grid-cols-1 space-y-2">
                {preview.warnings.map((warning) => (
                  <div key={warning} className="flex min-w-0 items-start gap-2">
                    <AlertTriangle className="mt-1 h-4 w-4 shrink-0 text-[var(--warning)]" />
                    <span className="min-w-0 break-words leading-6">{warning}</span>
                  </div>
                ))}
              </Alert>
            ) : null}

            <div className="space-y-4">
              {entries.map((entry) => (
                <article key={entry.id} className="overflow-hidden rounded-2xl border border-line bg-panel shadow-sm ring-1 ring-ink/[0.03]">
                  <div className="border-l-4 border-brand bg-paper px-4 py-4">
                    <div className="grid min-w-0 gap-3 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start">
                      <div className="min-w-0">
                        <div className="flex min-w-0 flex-wrap items-center gap-2">
                          <Badge variant="secondary" className="bg-tag text-warm">{entry.date}</Badge>
                          {entry.source ? <Badge variant="outline" className="border-brand/50 text-brand">{entry.source}</Badge> : null}
                          <span className="min-w-0 break-words text-lg font-medium leading-7 text-ink" title={entry.payee || "未命名商户"}>{entry.payee || "未命名商户"}</span>
                        </div>
                      </div>
                      <div className="rounded-2xl bg-panel px-3 py-2 text-left lg:text-right">
                        <div className="whitespace-nowrap font-serif text-2xl font-medium leading-none text-warm">{formatCny(entry.amount)}</div>
                        <div className="mt-1 text-xs text-stone">{entry.currency}</div>
                      </div>
                    </div>
                  </div>

                  <div className="space-y-4 p-4">
                    <div className="grid min-w-0 items-end gap-3 xl:grid-cols-[minmax(0,1fr)_minmax(0,380px)]">
                      <Label className="block min-w-0">
                        <span className="mb-1.5 block text-stone">标题</span>
                        <Input className="min-w-0 border-line bg-paper shadow-sm" value={entry.narration} onChange={(event) => updateEntry(entry.id, { narration: event.target.value })} />
                      </Label>
                      <Label className="block min-w-0">
                        <span className="mb-1.5 block text-stone">{editableAccountLabel(entry)}</span>
                        <Select value={entry.categoryAccount} onValueChange={(value) => updateEntry(entry.id, { categoryAccount: value })}>
                          <SelectTrigger className="h-10 w-full min-w-0 rounded-xl bg-paper text-sm text-ink shadow-sm">
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent className="max-h-80">
                            {categoryAccountOptions(entry).map((account) => <SelectItem key={account.account} value={account.account}>{formatAccountOptionLabel(account.account, account.label, account.alias)}</SelectItem>)}
                          </SelectContent>
                        </Select>
                      </Label>
                    </div>

                    <div className="grid min-w-0 gap-2 rounded-2xl border border-line bg-paper px-3 py-3 text-xs leading-5 text-stone md:grid-cols-3">
                      <div className="min-w-0 break-words"><span className="text-olive">支付方式：</span>{entry.method || "-"}</div>
                      <div className="min-w-0 break-words"><span className="text-olive">资金账户：</span>{entry.fundingAccount || "-"}</div>
                      <div className="min-w-0 break-all"><span className="text-olive">订单号：</span>{entry.orderId || "-"}</div>
                    </div>

                    <details>
                      <summary className="cursor-pointer text-xs text-olive"><Pencil className="mr-1 inline h-3 w-3" />备注 / metadata</summary>
                      <div className="mt-3 grid gap-2 md:grid-cols-2">
                        <Label className="block">
                          <span className="mb-1.5 block">note</span>
                          <Input className="border-line bg-paper shadow-sm" value={entry.metadata.note ?? ""} onChange={(event) => updateMetadata(entry.id, "note", event.target.value)} placeholder="添加备注" />
                        </Label>
                        <Label className="block">
                          <span className="mb-1.5 block">purpose</span>
                          <Input className="border-line bg-paper shadow-sm" value={entry.metadata.purpose ?? ""} onChange={(event) => updateMetadata(entry.id, "purpose", event.target.value)} placeholder="例如: travel / work" />
                        </Label>
                      </div>
                    </details>
                  </div>
                </article>
              ))}
            </div>

            <Button variant="ghost" className="px-0 text-stone underline" onClick={() => setRawOpen((value) => !value)}>
              {rawOpen ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
              查看原始输出 / dedup 报告
            </Button>
            {rawOpen ? (
              <div className="grid gap-4 lg:grid-cols-2">
                <pre className="max-h-96 overflow-auto rounded-2xl border border-line bg-ink p-4 text-xs leading-5 text-paper">{preview.dedupReport}</pre>
                <pre className="max-h-96 overflow-auto rounded-2xl border border-line bg-ink p-4 text-xs leading-5 text-paper">{preview.generatedBean}</pre>
              </div>
            ) : null}
          </div>
        </MobileSheet>
      ) : null}
    </div>
  );
}

function ImportStep({ index, title, detail, active, done }: { index: number; title: string; detail: string; active: boolean; done: boolean }) {
  return (
    <div className="flex min-w-0 max-w-full gap-3 overflow-hidden pb-4 last:pb-0">
      <div className={cn("grid h-7 w-7 shrink-0 place-items-center rounded-full border text-xs font-medium", done ? "border-brand bg-brand text-paper" : active ? "border-brand bg-[var(--selected-bg)] text-brand" : "border-line bg-panel text-stone")}>
        {done ? <Check className="h-3.5 w-3.5" /> : index}
      </div>
      <div className="min-w-0 flex-1 overflow-hidden">
        <div className="truncate text-sm font-medium text-ink">{title}</div>
        <div className="mt-0.5 truncate text-xs text-stone">{detail}</div>
      </div>
    </div>
  );
}

function ImportStats({ preview, entryCount }: { preview: ImportPreview; entryCount: number }) {
  const stats = preview.provider === "cmb"
    ? [
        ["PDF/CSV 明细", preview.rawRowCount],
        ["Web 前置过滤后", preview.filteredRowCount],
        ["DEG 生成", preview.generatedCount],
        ["已去重跳过", preview.skippedDuplicateCount],
        ["待确认写入", entryCount],
      ]
    : [
        ["候选交易", preview.candidateCount],
        ["生成分录", preview.generatedCount],
        ["已去重跳过", preview.skippedDuplicateCount],
        ["排除记录", preview.excludedRowCount],
        ["待确认写入", entryCount],
      ];

  return (
    <div className="grid min-w-0 gap-3 sm:grid-cols-2 xl:grid-cols-5">
      {stats.map(([label, value]) => (
        <div key={label} className="rounded-2xl border border-line bg-panel p-4 shadow-sm">
          <div className="text-xs text-stone">{label}</div>
          <div className="mt-2 font-serif text-xl font-medium text-ink">{value}</div>
        </div>
      ))}
    </div>
  );
}

function CommitResultDetails({ result }: { result: CommitResult }) {
  return (
    <div className="mt-4 space-y-2 rounded-2xl border border-line bg-paper p-4 text-sm text-olive">
      <div>写入交易：{result.count} 条</div>
      {result.outputFile ? <div className="break-all">导入文件：{result.outputFile}</div> : null}
      {result.includeFile ? <div className="break-all">月份 include：{result.includeFile}</div> : null}
      {result.documentFile ? <div className="break-all">原始账单 document：{result.documentFile}</div> : null}
      <div className="text-stone">如需保存到远端，请点击右上角「保存到 Git」。</div>
    </div>
  );
}
