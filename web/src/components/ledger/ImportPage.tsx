"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { AlertTriangle, Check, CheckCircle, ChevronDown, ChevronUp, FileArchive, FileSpreadsheet, FileUp, Loader2, Pencil, ShieldCheck, Trash2, UploadCloud } from "lucide-react";
import { fetchJson, readJson } from "@/lib/clientFetch";
import { convertCmbCheckingPdfToCsv, shouldConvertCmbCheckingPdf } from "@/lib/cmbCheckingPdf";
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

type Provider = "alipay" | "wechat" | "cmb" | "cmb-checking";
type ProviderOverride = "auto" | Provider;
type ProviderChoice = { value: ProviderOverride; label: string; detail: string; accept: string };
type ImportProviderInfo = { id: Provider; label: string; detail: string; extensions: string[]; accept: string };

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

const fallbackProviderChoices: ProviderChoice[] = [
  { value: "auto", label: "自动识别", detail: "按文件头和扩展名检测来源", accept: "CSV / XLSX / PDF" },
  { value: "alipay", label: "支付宝", detail: "CSV 账单，支持基金补差选项", accept: ".csv" },
  { value: "wechat", label: "微信支付", detail: "微信支付导出的明细表", accept: ".xlsx / .xls" },
  { value: "cmb", label: "招商银行信用卡", detail: "信用卡 PDF 或已转换 CSV", accept: ".pdf / .csv" },
  { value: "cmb-checking", label: "招商银行储蓄卡", detail: "储蓄卡交易流水 CSV，PDF 可尝试", accept: ".csv / .pdf" },
];

function providerChoicesFromAPI(providers: ImportProviderInfo[]): ProviderChoice[] {
  if (!providers.length) return fallbackProviderChoices;
  return [
    fallbackProviderChoices[0],
    ...providers.map((provider) => ({
      value: provider.id,
      label: provider.label,
      detail: provider.detail,
      accept: provider.accept || provider.extensions.join(" / "),
    })),
  ];
}

function providerLabel(provider: Provider, choices: ProviderChoice[]) {
  return choices.find((choice) => choice.value === provider)?.label ?? fallbackProviderChoices.find((choice) => choice.value === provider)?.label ?? provider;
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
  const [providerChoices, setProviderChoices] = useState<ProviderChoice[]>(fallbackProviderChoices);
  const [selectedEntryId, setSelectedEntryId] = useState("");

  const accountOptions = useMemo(() => {
    const accounts = preview?.accountOptions ?? [];
    return accounts.filter((account) => account.active);
  }, [preview]);
  const selectedEntry = useMemo(() => entries.find((entry) => entry.id === selectedEntryId) ?? entries[0] ?? null, [entries, selectedEntryId]);

  const selectedProvider = providerChoices.find((choice) => choice.value === providerOverride) ?? providerChoices[0];
  const hasCommitted = commitResult?.ok === true;
  const canCommit = Boolean(preview) && entries.length > 0 && !committing && !hasCommitted;
  const originalEntryCount = preview?.entries.length ?? 0;
  const removedEntryCount = Math.max(0, originalEntryCount - entries.length);
  const selectedEntryIndex = selectedEntry ? entries.findIndex((entry) => entry.id === selectedEntry.id) : -1;
  const reviewTotalAmount = useMemo(() => entries.reduce((total, entry) => total + entry.amount, 0), [entries]);

  useEffect(() => {
    const draft = readImportDraft();
    if (!draft) return;
    setProviderOverride(draft.providerOverride);
    setAlipayFundRounding(draft.alipayFundRounding);
    setPreview(draft.preview);
    setEntries(draft.entries);
    setSelectedEntryId(draft.entries[0]?.id ?? "");
    setReviewOpen(true);
  }, []);

  useEffect(() => {
    let cancelled = false;
    fetchJson<{ providers: ImportProviderInfo[] }>("/api/ledger/imports/providers", undefined, { providers: [] })
      .then((data) => {
        if (!cancelled) setProviderChoices(providerChoicesFromAPI(data.providers ?? []));
      })
      .catch(() => {
        if (!cancelled) setProviderChoices(fallbackProviderChoices);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!preview || hasCommitted) return;
    writeImportDraft({ savedAt: Date.now(), providerOverride, alipayFundRounding, preview, entries });
  }, [alipayFundRounding, entries, hasCommitted, preview, providerOverride]);

  useEffect(() => {
    if (entries.length === 0) {
      if (selectedEntryId) setSelectedEntryId("");
      return;
    }
    if (!selectedEntryId || !entries.some((entry) => entry.id === selectedEntryId)) {
      setSelectedEntryId(entries[0].id);
    }
  }, [entries, selectedEntryId]);

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
    setSelectedEntryId("");
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
    setSelectedEntryId("");
    setCommitResult(null);
    setResultOpen(false);
    try {
      const uploadFile = shouldConvertCmbCheckingPdf(file, providerOverride)
        ? await convertCmbCheckingPdfToCsv(file)
        : file;
      const form = new FormData();
      if (providerOverride !== "auto") form.set("provider", providerOverride);
      form.set("file", uploadFile);
      if (uploadFile !== file) form.set("originalFile", file);
      form.set("alipayFundRounding", String(alipayFundRounding));
      const res = await fetch("/api/ledger/imports/preview", { method: "POST", body: form });
      const data = await readJson<ImportPreview>(res);
      if (!res.ok || data.error) throw new Error(data.error || "生成预览失败");
      setPreview(data);
      setEntries(data.entries);
      setSelectedEntryId(data.entries[0]?.id ?? "");
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

  function removeEntry(id: string) {
    setEntries((current) => {
      const next = current.filter((entry) => entry.id !== id);
      if (selectedEntryId === id) setSelectedEntryId(next[0]?.id ?? "");
      return next;
    });
  }

  function selectEntryOffset(offset: number) {
    if (!entries.length) return;
    const index = selectedEntryIndex < 0 ? 0 : selectedEntryIndex;
    const next = entries[(index + offset + entries.length) % entries.length];
    if (next) setSelectedEntryId(next.id);
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
                <Badge variant="secondary">{providerLabel(preview.provider, providerChoices)}</Badge>
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
          title={`${providerLabel(preview.provider, providerChoices)}导入审核`}
          onClose={() => setReviewOpen(false)}
          shouldClose={() => !committing}
          size="xl"
          align="center"
          closeLabel={committing ? "写入中" : "关闭"}
          footer={
            <div className="flex min-w-0 flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div className="flex min-w-0 flex-wrap items-center gap-2 text-xs leading-5 text-stone">
                <Badge variant={hasCommitted ? "secondary" : "outline"} className={hasCommitted ? "border-brand/30 bg-[var(--selected-bg)] text-brand" : undefined}>
                  {hasCommitted ? `已写入 ${commitResult?.count ?? 0}` : `待写入 ${entries.length}`}
                </Badge>
                <span>{removedEntryCount > 0 ? `已移除 ${removedEntryCount}` : "未移除候选"}</span>
                <span className="tabular-nums">{formatCny(reviewTotalAmount)} 合计</span>
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
          <div className="-mx-4 -my-4 min-w-0 bg-paper sm:-mx-5">
            <div className="border-b border-line bg-panel px-4 py-4 sm:px-5">
              <div className="grid min-w-0 gap-3 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-center">
                <div className="min-w-0">
                  <div className="flex min-w-0 flex-wrap items-center gap-2">
                    <Badge variant="outline">{confidenceLabel(preview.providerDetection.confidence)}</Badge>
                    <Badge variant="secondary">{providerLabel(preview.provider, providerChoices)}</Badge>
                    <span className="min-w-0 break-all text-sm font-medium leading-5 text-ink">{preview.originalFilename}</span>
                  </div>
                  <div className="mt-1 text-xs leading-5 text-stone">{preview.providerDetection.reason}</div>
                </div>
                <div className="grid grid-cols-[auto_auto] items-center gap-3 rounded-xl border border-line bg-panel px-3 py-2 text-sm text-stone">
                  <span>{preview.dateStart ?? "?"} ~ {preview.dateEnd ?? "?"}</span>
                  <span className="rounded-lg bg-[var(--selected-bg)] px-2 py-1 font-medium text-brand">{entries.length} 待写入</span>
                </div>
              </div>
              <div className="mt-4 grid min-w-0 gap-px overflow-hidden rounded-xl border border-line bg-line sm:grid-cols-4">
                <ReviewMetric label="原始记录" value={preview.rawRowCount || preview.candidateCount} detail={`${preview.filteredRowCount || preview.generatedCount} 条进入预览`} />
                <ReviewMetric label="去重跳过" value={preview.skippedDuplicateCount} detail="与账本现有记录匹配" />
                <ReviewMetric label="已移除" value={removedEntryCount} detail="提交时会跳过" tone={removedEntryCount > 0 ? "warn" : "muted"} />
                <ReviewMetric label="待写入合计" value={formatCny(reviewTotalAmount)} detail={`${entries.length} 条候选交易`} tone="brand" />
              </div>
            </div>

            <div className="min-w-0 space-y-3 px-3 py-3 sm:px-5">
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

              <div className="grid min-w-0 gap-3 xl:grid-cols-[minmax(0,1fr)_minmax(380px,440px)] xl:items-start">
                <section className="min-w-0 overflow-hidden rounded-xl border border-line bg-panel shadow-sm">
                  <div className="flex min-w-0 flex-col gap-2 border-b border-line bg-paper px-3 py-3 sm:flex-row sm:items-center sm:justify-between">
                    <div className="min-w-0">
                      <div className="text-sm font-medium text-ink">候选交易</div>
                      <div className="mt-0.5 text-xs text-stone">逐条核对，删除后只提交剩余交易。</div>
                    </div>
                    <div className="flex min-w-0 flex-wrap items-center gap-2 text-xs text-stone">
                      <span className="rounded-full bg-tag px-2 py-1">{entries.length} 待写入</span>
                      <span className="rounded-full bg-tag px-2 py-1">{removedEntryCount} 已移除</span>
                    </div>
                  </div>
                  {entries.length === 0 ? (
                    <div className="px-4 py-10 text-center text-sm text-stone">已删除所有候选交易。</div>
                  ) : (
                    <div className="divide-y divide-line">
                      {entries.map((entry, index) => {
                        const selected = selectedEntry?.id === entry.id;
                        return (
                          <article
                            key={entry.id}
                            className={cn(
                              "relative grid min-w-0 grid-cols-[minmax(0,1fr)_2.75rem] items-center transition",
                              selected ? "bg-[var(--selected-bg)]" : "bg-panel hover:bg-paper",
                            )}
                          >
                            {selected ? <span className="absolute inset-y-2 left-0 w-1 rounded-r-full bg-brand" aria-hidden="true" /> : null}
                            <button type="button" className="min-w-0 px-3 py-2.5 pl-4 text-left" onClick={() => setSelectedEntryId(entry.id)}>
                              <div className="grid min-w-0 gap-2 md:grid-cols-[5rem_minmax(0,1fr)_8rem] md:items-center">
                                <div className="flex min-w-0 items-center gap-2 md:block">
                                  <span className="font-mono text-[11px] text-stone">{String(index + 1).padStart(2, "0")}</span>
                                  <span className={cn("inline-flex rounded-full px-2 py-0.5 text-xs font-medium", selected ? "bg-brand text-paper" : "bg-tag text-warm")}>{entry.date}</span>
                                </div>
                                <div className="min-w-0">
                                  <div className="flex min-w-0 items-center gap-2">
                                    <span className="min-w-0 truncate text-sm font-medium text-ink">{entry.payee || "未命名商户"}</span>
                                    {entry.source ? <span className="shrink-0 rounded-full border border-brand/35 px-1.5 py-0.5 text-[10px] text-brand">{entry.source}</span> : null}
                                  </div>
                                  <div className="mt-0.5 truncate text-xs text-stone">{entry.narration || "未填写标题"}</div>
                                </div>
                                <div className="text-left md:text-right">
                                  <div className="font-serif text-lg font-medium leading-none text-warm tabular-nums">{formatCny(entry.amount)}</div>
                                  <div className="mt-1 truncate text-[11px] text-stone">{entry.categoryAccount}</div>
                                </div>
                              </div>
                            </button>
                            <Button
                              type="button"
                              variant="ghost"
                              size="icon"
                              className="mr-1 h-9 w-9 shrink-0 text-stone hover:text-destructive"
                              onClick={() => removeEntry(entry.id)}
                              disabled={committing || hasCommitted}
                              title="删除这条候选交易"
                            >
                              <Trash2 className="h-4 w-4" />
                            </Button>
                          </article>
                        );
                      })}
                    </div>
                  )}
                </section>

                {selectedEntry ? (
                  <aside className="min-w-0 overflow-hidden rounded-xl border border-line bg-panel shadow-sm xl:sticky xl:top-3 xl:max-h-[calc(90dvh-9rem)] xl:overflow-y-auto">
                    <div className="border-b border-line bg-paper px-4 py-3">
                      <div className="flex min-w-0 items-center justify-between gap-3">
                        <div className="min-w-0">
                          <div className="text-[11px] uppercase tracking-[0.12em] text-stone">正在编辑 {selectedEntryIndex + 1}/{entries.length}</div>
                          <div className="mt-1 truncate text-lg font-medium leading-7 text-ink" title={selectedEntry.payee || "未命名商户"}>{selectedEntry.payee || "未命名商户"}</div>
                        </div>
                        <div className="flex shrink-0 items-center gap-1">
                          <Button type="button" variant="outline" size="icon-sm" onClick={() => selectEntryOffset(-1)} disabled={entries.length <= 1} title="上一条">
                            <ChevronUp className="h-4 w-4" />
                          </Button>
                          <Button type="button" variant="outline" size="icon-sm" onClick={() => selectEntryOffset(1)} disabled={entries.length <= 1} title="下一条">
                            <ChevronDown className="h-4 w-4" />
                          </Button>
                        </div>
                      </div>
                      <div className="mt-3 flex min-w-0 items-end justify-between gap-3">
                        <div className="flex min-w-0 flex-wrap items-center gap-2">
                          <Badge variant="secondary" className="bg-tag text-warm">{selectedEntry.date}</Badge>
                          {selectedEntry.source ? <Badge variant="outline" className="border-brand/50 text-brand">{selectedEntry.source}</Badge> : null}
                        </div>
                        <div className="shrink-0 text-right">
                          <div className="font-serif text-2xl font-medium leading-none text-warm tabular-nums">{formatCny(selectedEntry.amount)}</div>
                          <div className="mt-1 text-xs text-stone">{selectedEntry.currency}</div>
                        </div>
                      </div>
                    </div>

                    <div className="space-y-4 p-4">
                      <div className="grid min-w-0 gap-2 rounded-xl border border-line bg-paper px-3 py-2.5 text-xs leading-5 text-stone">
                        <div className="grid min-w-0 grid-cols-[4.5rem_minmax(0,1fr)] gap-2"><span className="text-olive">标题</span><span className="min-w-0 break-words">{selectedEntry.narration || "-"}</span></div>
                        <div className="grid min-w-0 grid-cols-[4.5rem_minmax(0,1fr)] gap-2"><span className="text-olive">方式</span><span className="min-w-0 break-words">{selectedEntry.method || "-"}</span></div>
                        <div className="grid min-w-0 grid-cols-[4.5rem_minmax(0,1fr)] gap-2"><span className="text-olive">资金账户</span><span className="min-w-0 break-words">{selectedEntry.fundingAccount || "-"}</span></div>
                        <div className="grid min-w-0 grid-cols-[4.5rem_minmax(0,1fr)] gap-2"><span className="text-olive">订单号</span><span className="min-w-0 break-all">{selectedEntry.orderId || "-"}</span></div>
                      </div>

                      <div className="space-y-3">
                        <Label className="block min-w-0">
                          <span className="mb-1.5 block text-xs font-medium text-stone">账本标题</span>
                          <Input className="h-10 min-w-0 border-line bg-paper shadow-sm" value={selectedEntry.narration} onChange={(event) => updateEntry(selectedEntry.id, { narration: event.target.value })} />
                        </Label>
                        <Label className="block min-w-0">
                          <span className="mb-1.5 block text-xs font-medium text-stone">{editableAccountLabel(selectedEntry)}</span>
                          <Select value={selectedEntry.categoryAccount} onValueChange={(value) => updateEntry(selectedEntry.id, { categoryAccount: value })}>
                            <SelectTrigger className="h-10 w-full min-w-0 rounded-xl bg-paper text-sm text-ink shadow-sm">
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent className="max-h-80">
                              {categoryAccountOptions(selectedEntry).map((account) => <SelectItem key={account.account} value={account.account}>{formatAccountOptionLabel(account.account, account.label, account.alias)}</SelectItem>)}
                            </SelectContent>
                          </Select>
                        </Label>
                      </div>

                      <details open className="rounded-xl border border-line bg-paper px-3 py-2.5">
                        <summary className="cursor-pointer text-xs font-medium text-olive"><Pencil className="mr-1 inline h-3 w-3" />备注 / metadata</summary>
                        <div className="mt-3 grid gap-2">
                          <Label className="block">
                            <span className="mb-1.5 block text-xs text-stone">note</span>
                            <Input className="h-10 border-line bg-panel shadow-sm" value={selectedEntry.metadata.note ?? ""} onChange={(event) => updateMetadata(selectedEntry.id, "note", event.target.value)} placeholder="添加备注" />
                          </Label>
                          <Label className="block">
                            <span className="mb-1.5 block text-xs text-stone">purpose</span>
                            <Input className="h-10 border-line bg-panel shadow-sm" value={selectedEntry.metadata.purpose ?? ""} onChange={(event) => updateMetadata(selectedEntry.id, "purpose", event.target.value)} placeholder="例如: travel / work" />
                          </Label>
                        </div>
                      </details>

                      <Button
                        type="button"
                        variant="outline"
                        className="w-full border-line bg-panel text-stone hover:text-destructive"
                        onClick={() => removeEntry(selectedEntry.id)}
                        disabled={committing || hasCommitted}
                      >
                        <Trash2 className="h-4 w-4" />
                        删除当前交易
                      </Button>
                    </div>
                  </aside>
                ) : null}
              </div>

              <div className="overflow-hidden rounded-xl border border-line bg-panel">
                <Button variant="ghost" className="flex h-11 w-full justify-start rounded-none px-3 text-stone" onClick={() => setRawOpen((value) => !value)}>
                  {rawOpen ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
                  查看原始输出 / dedup 报告
                </Button>
                {rawOpen ? (
                  <div className="grid gap-3 border-t border-line p-3 lg:grid-cols-2">
                    <pre className="max-h-96 overflow-auto rounded-xl border border-line bg-ink p-4 text-xs leading-5 text-paper">{preview.dedupReport}</pre>
                    <pre className="max-h-96 overflow-auto rounded-xl border border-line bg-ink p-4 text-xs leading-5 text-paper">{preview.generatedBean}</pre>
                  </div>
                ) : null}
              </div>
            </div>
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

function ReviewMetric({ label, value, detail, tone = "default" }: { label: string; value: string | number; detail: string; tone?: "default" | "brand" | "warn" | "muted" }) {
  return (
    <div className="min-w-0 bg-panel px-4 py-3">
      <div className="truncate text-xs text-stone">{label}</div>
      <div className={cn("mt-1 truncate font-serif text-xl font-medium leading-none tabular-nums", tone === "brand" ? "text-brand" : tone === "warn" ? "text-[var(--warning)]" : tone === "muted" ? "text-stone" : "text-ink")}>{value}</div>
      <div className="mt-1 truncate text-[11px] text-stone">{detail}</div>
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
