"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { AlertTriangle, ArrowRight, CalendarClock, Check, CheckCircle, ChevronDown, ChevronUp, Download, ExternalLink, FileArchive, FileSpreadsheet, FileText, FileUp, Inbox, Loader2, Mail, Pencil, Plus, RefreshCw, ShieldCheck, Trash2, UploadCloud } from "lucide-react";
import { ApiResponseError, fetchJson } from "@/lib/clientFetch";
import { activeApiEndpointRequestUrl, apiEndpointScopedStorageKey } from "@/lib/apiEndpoints";
import { formatMoney } from "@/lib/money";
import { cn } from "@/lib/utils";
import { Alert } from "@/components/ui/alert";
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
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { formatAccountOptionLabel } from "./accountDisplay";
import { MobileSheet } from "./MobileSheet";

type Provider = "alipay" | "alipay-small-purse" | "wechat" | "cmb" | "ccb-credit" | "cmb-checking";
type ProviderOverride = "auto" | Provider;
type ProviderChoice = { value: ProviderOverride; label: string; detail: string; accept: string };
type ImportProviderInfo = { id: Provider; label: string; detail: string; extensions: string[]; accept: string; engine?: string };

type AccountOption = { account: string; alias?: string | null; label: string; group: string; active: boolean };
type ImportPosting = { account: string; amount: string; currency: string; priceKind?: "unit" | "total"; priceAmount?: string; priceCurrency?: string };
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
type ImportDocument = { path: string; name: string; year: string; ext: string; provider?: string; dateStart?: string; dateEnd?: string; size: number; modTime: string };
type ImportDraft = {
  savedAt: number;
  providerOverride: ProviderOverride;
  alipayFundRounding: boolean;
  preview: ImportPreview;
  entries: ImportEntry[];
};
type GmailImportStatus = { configured: boolean; connected: boolean; email?: string; label?: string; watchExpiration?: number; lastSyncAt?: string | null; lastError?: string | null; allowedSenders?: string[]; oauthRedirectUrl?: string };
type GmailPendingImport = { id: string; importId?: string; messageId: string; sender: string; subject: string; receivedAt: string; filename: string; provider?: Provider; candidateCount: number; status: "processing" | "ready" | "failed" | "committing" | "committed" | "dismissed"; error?: string; createdAt: string; updatedAt: string };

const importDraftKey = "ledger_import_review_draft";

const fallbackProviderChoices: ProviderChoice[] = [
  { value: "auto", label: "自动识别", detail: "按文件头和扩展名检测来源", accept: "CSV / XLSX / PDF / EML / ZIP" },
  { value: "alipay", label: "支付宝", detail: "CSV 账单，支持基金补差选项", accept: ".csv" },
  { value: "alipay-small-purse", label: "支付宝小荷包", detail: "小荷包余额收支明细 XLSX，共同资金池消费", accept: ".xlsx" },
  { value: "wechat", label: "微信支付", detail: "微信支付导出的明细表", accept: ".xlsx / .xls" },
  { value: "cmb", label: "招商银行信用卡", detail: "信用卡 PDF 或已转换 CSV", accept: ".pdf / .csv" },
  { value: "ccb-credit", label: "建设银行信用卡", detail: "信用卡邮件 EML、HTML 或标准 CSV", accept: ".eml / .html / .htm / .csv" },
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

function isProvider(value: string | undefined): value is Provider {
  return value === "alipay" || value === "alipay-small-purse" || value === "wechat" || value === "cmb" || value === "ccb-credit" || value === "cmb-checking";
}

function importDocumentCoverageValue(document: ImportDocument) {
  if (document.dateEnd) return document.dateEnd;
  if (document.dateStart) return document.dateStart;
  return "";
}

function compareImportDocumentCoverage(left: ImportDocument, right: ImportDocument) {
  const leftCoverage = importDocumentCoverageValue(left);
  const rightCoverage = importDocumentCoverageValue(right);
  if (leftCoverage !== rightCoverage) return leftCoverage.localeCompare(rightCoverage);
  return new Date(left.modTime).getTime() - new Date(right.modTime).getTime();
}

export function latestImportDocumentsByProvider(documents: ImportDocument[]) {
  const latest: Partial<Record<Provider, ImportDocument>> = {};
  for (const document of documents) {
    if (!isProvider(document.provider)) continue;
    const current = latest[document.provider];
    if (!current || compareImportDocumentCoverage(document, current) > 0) {
      latest[document.provider] = document;
    }
  }
  return latest;
}

export function importActionFeedback(error: unknown) {
  if (error instanceof ApiResponseError && error.status === 423) return "敏感数据已锁定，请先解锁后重试";
  return error instanceof Error ? error.message : String(error);
}

export function reviewableGmailPendingImports(items: GmailPendingImport[]) {
  return items.filter((item) => item.status === "ready" || item.status === "failed");
}

export function gmailPendingImportActions(status: GmailPendingImport["status"]) {
  return {
    retry: status === "failed",
    review: status === "ready",
    dismiss: status === "ready" || status === "failed",
  };
}

export function gmailPendingRetryURL(id: string) {
  return `/api/integrations/gmail/sync?pendingId=${encodeURIComponent(id)}`;
}

function formatImportTotals(entries: ImportEntry[]) {
  const totals = new Map<string, number>();
  for (const entry of entries) {
    totals.set(entry.currency, (totals.get(entry.currency) ?? 0) + entry.amount);
  }
  const parts = Array.from(totals.entries())
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([currency, amount]) => formatMoney(amount, currency));
  return parts.length ? parts.join(" / ") : formatMoney(0, "CNY");
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

function formatDraftSavedAt(savedAt: number | null) {
  if (!savedAt) return "";
  return new Date(savedAt).toLocaleString("zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
}

function readImportDraft(): ImportDraft | null {
  if (typeof window === "undefined") return null;
  try {
    const scopedKey = apiEndpointScopedStorageKey(importDraftKey);
    const scoped = localStorage.getItem(scopedKey);
    const raw = scoped ?? localStorage.getItem(importDraftKey);
    if (!raw) return null;
    const draft = JSON.parse(raw) as Partial<ImportDraft>;
    if (!draft.preview?.importId || !Array.isArray(draft.entries)) return null;
    const normalized = {
      savedAt: typeof draft.savedAt === "number" ? draft.savedAt : Date.now(),
      providerOverride: draft.providerOverride ?? "auto",
      alipayFundRounding: Boolean(draft.alipayFundRounding),
      preview: draft.preview,
      entries: draft.entries,
    } satisfies ImportDraft;
    if (!scoped) {
      try {
        localStorage.setItem(scopedKey, JSON.stringify(normalized));
        if (localStorage.getItem(scopedKey)) localStorage.removeItem(importDraftKey);
      } catch {
        // Keep using the legacy draft until scoped storage is writable.
      }
    }
    return normalized;
  } catch {
    return null;
  }
}

function writeImportDraft(draft: ImportDraft | null) {
  if (typeof window === "undefined") return;
  try {
    const scopedKey = apiEndpointScopedStorageKey(importDraftKey);
    if (!draft) {
      localStorage.removeItem(scopedKey);
      localStorage.removeItem(importDraftKey);
    } else {
      localStorage.setItem(scopedKey, JSON.stringify(draft));
    }
  } catch {
    // Storage can be unavailable or full for large imports; the in-memory review still works.
  }
}

export function createImportPreviewForm(providerOverride: ProviderOverride, file: File, alipayFundRounding: boolean, archivePassword: string) {
  const form = new FormData();
  if (providerOverride !== "auto") form.set("provider", providerOverride);
  form.set("file", file);
  form.set("alipayFundRounding", String(alipayFundRounding));
  if (file.name.toLowerCase().endsWith(".zip") && archivePassword !== "") form.set("archivePassword", archivePassword);
  return form;
}

export function ImportPage({ onImported, showToast }: { onImported?: () => void; showToast: (kind: "info" | "success" | "error", text: string) => void }) {
  const inputRef = useRef<HTMLInputElement | null>(null);
  const reviewDetailRef = useRef<HTMLElement | null>(null);
  const draftHydratedRef = useRef(false);
  const [providerOverride, setProviderOverride] = useState<ProviderOverride>("auto");
  const [file, setFile] = useState<File | null>(null);
  const [archivePassword, setArchivePassword] = useState("");
  const [dragActive, setDragActive] = useState(false);
  const [alipayFundRounding, setAlipayFundRounding] = useState(false);
  const [preview, setPreview] = useState<ImportPreview | null>(null);
  const [entries, setEntries] = useState<ImportEntry[]>([]);
  const [commitResult, setCommitResult] = useState<CommitResult | null>(null);
  const [resultOpen, setResultOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [committing, setCommitting] = useState(false);
  const [providerOpen, setProviderOpen] = useState(false);
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [rawOpen, setRawOpen] = useState(false);
  const [reviewOpen, setReviewOpen] = useState(false);
  const [discardDialogOpen, setDiscardDialogOpen] = useState(false);
  const [providerChoices, setProviderChoices] = useState<ProviderChoice[]>(fallbackProviderChoices);
  const [selectedEntryId, setSelectedEntryId] = useState("");
  const [draftSavedAt, setDraftSavedAt] = useState<number | null>(null);
  const [importDocuments, setImportDocuments] = useState<ImportDocument[]>([]);
  const [documentsLoading, setDocumentsLoading] = useState(false);
  const [documentsError, setDocumentsError] = useState("");
  const [gmailStatus, setGmailStatus] = useState<GmailImportStatus | null>(null);
  const [pendingImports, setPendingImports] = useState<GmailPendingImport[]>([]);
  const [gmailLoading, setGmailLoading] = useState(false);
  const [activePendingId, setActivePendingId] = useState("");

  const accountOptions = useMemo(() => {
    const accounts = preview?.accountOptions ?? [];
    return accounts.filter((account) => account.active);
  }, [preview]);
  const selectedEntry = useMemo(() => entries.find((entry) => entry.id === selectedEntryId) ?? entries[0] ?? null, [entries, selectedEntryId]);

  const selectedProvider = providerChoices.find((choice) => choice.value === providerOverride) ?? providerChoices[0];
  const hasCommitted = commitResult?.ok === true;
  const invalidEntryCount = useMemo(() => entries.filter(importEntryHasReviewError).length, [entries]);
  const canCommit = Boolean(preview) && invalidEntryCount === 0 && !committing && !hasCommitted;
  const originalEntryCount = preview?.entries.length ?? 0;
  const removedEntryCount = Math.max(0, originalEntryCount - entries.length);
  const selectedEntryIndex = selectedEntry ? entries.findIndex((entry) => entry.id === selectedEntry.id) : -1;
  const reviewTotalAmount = useMemo(() => formatImportTotals(entries), [entries]);
  const isRestoredDraft = Boolean(preview) && !file && !hasCommitted;
  const importStage = hasCommitted ? "done" : preview ? "review" : file ? "ready" : "empty";
  const latestImportsByProvider = useMemo(() => latestImportDocumentsByProvider(importDocuments), [importDocuments]);
  const reviewablePendingImports = useMemo(() => reviewableGmailPendingImports(pendingImports), [pendingImports]);
  const isZipUpload = file?.name.toLowerCase().endsWith(".zip") === true;

  function reportActionError(error: unknown) {
    showToast("error", importActionFeedback(error));
  }

  useEffect(() => {
    const draft = readImportDraft();
    if (!draft) return;
    setProviderOverride(draft.providerOverride);
    setAlipayFundRounding(draft.alipayFundRounding);
    setPreview(draft.preview);
    setEntries(draft.entries);
    setSelectedEntryId(draft.entries[0]?.id ?? "");
    setDraftSavedAt(draft.savedAt);
    draftHydratedRef.current = true;
  }, []);

  useEffect(() => {
    let cancelled = false;
    fetchJson<{ providers: ImportProviderInfo[] }>("/api/ledger/imports/providers", undefined, { providers: [] }, { kind: "auth" })
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
    void loadImportDocuments();
    void loadGmailAutomation();
  }, []);

  useEffect(() => {
    if (!preview || hasCommitted) return;
    if (draftHydratedRef.current) {
      draftHydratedRef.current = false;
      return;
    }
    const savedAt = Date.now();
    setDraftSavedAt(savedAt);
    writeImportDraft({ savedAt, providerOverride, alipayFundRounding, preview, entries });
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

  function postingAccountOptions(entry: ImportEntry) {
    const currentAccounts = new Set([...entry.postings.map((posting) => posting.account), entry.categoryAccount, entry.fundingAccount].filter(Boolean));
    const options = [...accountOptions];
    for (const account of currentAccounts) {
      if (options.some((option) => option.account === account)) continue;
      options.push(preview?.accountOptions.find((option) => option.account === account) ?? { account, label: account, group: "current", active: true });
    }
    return options;
  }

  function accountDisplayName(account: string) {
    if (!account) return "-";
    const option = preview?.accountOptions.find((item) => item.account === account);
    return option ? formatAccountOptionLabel(option.account, option.label, option.alias) : account;
  }

  function resetForFile(next: File | null) {
    setFile(next);
    setArchivePassword("");
    setPreview(null);
    setEntries([]);
    setSelectedEntryId("");
    setCommitResult(null);
    setResultOpen(false);
    setReviewOpen(false);
    setDraftSavedAt(null);
    setActivePendingId("");
    writeImportDraft(null);
  }

  function clearImportState() {
    setFile(null);
    setArchivePassword("");
    if (inputRef.current) inputRef.current.value = "";
    setPreview(null);
    setEntries([]);
    setSelectedEntryId("");
    setCommitResult(null);
    setResultOpen(false);
    setReviewOpen(false);
    setRawOpen(false);
    setDraftSavedAt(null);
    setDiscardDialogOpen(false);
    setActivePendingId("");
    writeImportDraft(null);
  }

  async function generatePreview() {
    if (!file) {
      showToast("error", "请先选择账单文件");
      return;
    }
    setLoading(true);
    setPreview(null);
    setEntries([]);
    setSelectedEntryId("");
    setCommitResult(null);
    setResultOpen(false);
    try {
      const form = createImportPreviewForm(providerOverride, file, alipayFundRounding, archivePassword);
      setArchivePassword("");
      const data = await fetchJson<ImportPreview>("/api/ledger/imports/preview", { method: "POST", body: form }, undefined, { kind: "write" });
      setPreview(data);
      setEntries(data.entries);
      setSelectedEntryId(data.entries[0]?.id ?? "");
      setDraftSavedAt(Date.now());
      setReviewOpen(true);
    } catch (err) {
      reportActionError(err);
    } finally {
      setLoading(false);
    }
  }

  async function commitImport() {
    if (!preview) return;
    setCommitting(true);
    setCommitResult(null);
    setResultOpen(false);
    try {
      const data = await fetchJson<CommitResult>("/api/ledger/imports/commit", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ importId: preview.importId, provider: preview.provider, entries, alipayFundRounding }),
      }, undefined, { kind: "write" });
      setCommitResult(data);
      setResultOpen(true);
      setReviewOpen(true);
      writeImportDraft(null);
      setDraftSavedAt(null);
      void loadImportDocuments();
      void loadGmailAutomation();
      onImported?.();
    } catch (err) {
      reportActionError(err);
    } finally {
      setCommitting(false);
    }
  }

  function updateEntry(id: string, patch: Partial<ImportEntry>) {
    setEntries((current) => current.map((entry) => (entry.id === id ? { ...entry, ...patch } : entry)));
  }

  function updatePosting(id: string, index: number, patch: Partial<ImportPosting>) {
    setEntries((current) => current.map((entry) => (entry.id === id ? updateImportPosting(entry, index, patch) : entry)));
  }

  function addPosting(id: string) {
    setEntries((current) => current.map((entry) => (entry.id === id ? appendImportPosting(entry) : entry)));
  }

  function removePosting(id: string, index: number) {
    setEntries((current) => current.map((entry) => (entry.id === id ? removeImportPosting(entry, index) : entry)));
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

  function selectReviewEntry(id: string) {
    setSelectedEntryId(id);
    if (typeof window !== "undefined" && window.innerWidth < 1280) {
      window.requestAnimationFrame(() => reviewDetailRef.current?.scrollIntoView({ block: "start", behavior: "smooth" }));
    }
  }

  async function loadImportDocuments(notifyOnError = false) {
    setDocumentsLoading(true);
    setDocumentsError("");
    try {
      const data = await fetchJson<{ documents: ImportDocument[] }>("/api/ledger/imports/documents", undefined, { documents: [] }, { kind: "auth" });
      setImportDocuments(data.documents ?? []);
    } catch (err) {
      if (notifyOnError) reportActionError(err);
      else setDocumentsError(importActionFeedback(err));
    } finally {
      setDocumentsLoading(false);
    }
  }

  async function loadGmailAutomation(notifyOnError = false): Promise<boolean> {
    try {
      const status = await fetchJson<GmailImportStatus>("/api/integrations/gmail/status", undefined, { configured: false, connected: false }, { kind: "auth" });
      setGmailStatus(status);
      try {
        const pending = await fetchJson<{ items: GmailPendingImport[] }>("/api/ledger/imports/pending", undefined, { items: [] }, { kind: "auth" });
        setPendingImports(pending.items ?? []);
      } catch (err) {
        if (err instanceof ApiResponseError && err.status === 423) {
          setPendingImports([]);
          return true;
        }
        throw err;
      }
      return true;
    } catch (err) {
      if (notifyOnError) reportActionError(err);
      return false;
    }
  }

  async function connectGmail() {
    setGmailLoading(true);
    try {
      const data = await fetchJson<{ url?: string }>("/api/integrations/gmail/connect", { method: "POST" }, undefined, { kind: "write" });
      if (!data.url) throw new Error("无法开始 Gmail 授权");
      window.location.assign(data.url);
    } catch (err) {
      reportActionError(err);
      setGmailLoading(false);
    }
  }

  async function syncGmail() {
    setGmailLoading(true);
    try {
      await fetchJson<{ ok?: boolean }>("/api/integrations/gmail/sync", { method: "POST" }, undefined, { kind: "write" });
      if (await loadGmailAutomation(true)) showToast("success", "Gmail 账单同步完成");
    } catch (err) {
      reportActionError(err);
    } finally {
      setGmailLoading(false);
    }
  }

  async function disconnectGmail() {
    if (typeof window !== "undefined" && !window.confirm("断开 Gmail 自动账单连接？")) return;
    setGmailLoading(true);
    try {
      await fetchJson<{ ok?: boolean }>("/api/integrations/gmail", { method: "DELETE" }, undefined, { kind: "write" });
      setPendingImports([]);
      if (await loadGmailAutomation(true)) showToast("success", "Gmail 自动账单连接已断开");
    } catch (err) {
      reportActionError(err);
    } finally {
      setGmailLoading(false);
    }
  }

  async function openPendingImport(item: GmailPendingImport) {
    if (item.status !== "ready") return;
    setGmailLoading(true);
    try {
      const data = await fetchJson<{ item?: GmailPendingImport; preview?: ImportPreview }>(`/api/ledger/imports/pending/${encodeURIComponent(item.id)}`, undefined, undefined, { kind: "auth" });
      if (!data.preview?.importId) throw new Error("自动账单预览不存在");
      setFile(null);
      setPreview(data.preview);
      setEntries(data.preview.entries);
      setSelectedEntryId(data.preview.entries[0]?.id ?? "");
      setCommitResult(null);
      setResultOpen(false);
      setDraftSavedAt(Date.now());
      setActivePendingId(item.id);
      setReviewOpen(true);
    } catch (err) {
      reportActionError(err);
    } finally {
      setGmailLoading(false);
    }
  }

  async function dismissPendingImport(item: GmailPendingImport) {
    setGmailLoading(true);
    try {
      await fetchJson<{ ok?: boolean }>(`/api/ledger/imports/pending/${encodeURIComponent(item.id)}`, { method: "DELETE" }, undefined, { kind: "write" });
      if (await loadGmailAutomation(true)) showToast("success", "已忽略这份自动账单");
    } catch (err) {
      reportActionError(err);
    } finally {
      setGmailLoading(false);
    }
  }

  async function retryPendingImport(item: GmailPendingImport) {
    setGmailLoading(true);
    try {
      await fetchJson<{ ok?: boolean; item?: GmailPendingImport }>(gmailPendingRetryURL(item.id), { method: "POST" }, undefined, { kind: "write" });
      if (await loadGmailAutomation(true)) showToast("success", "账单重新解析完成");
    } catch (err) {
      await loadGmailAutomation();
      reportActionError(err);
    } finally {
      setGmailLoading(false);
    }
  }

  function updateMetadata(id: string, key: string, value: string) {
    setEntries((current) => current.map((entry) => (entry.id === id ? { ...entry, metadata: { ...entry.metadata, [key]: value } } : entry)));
  }

  function renderPrimaryActions() {
    if (hasCommitted) {
      return (
        <div className="grid gap-2">
          <Button className="w-full" size="lg" onClick={() => setReviewOpen(true)}>
            <CheckCircle className="h-4 w-4" />
            查看写入结果
          </Button>
          <Button className="w-full" variant="outline" onClick={clearImportState}>
            <FileUp className="h-4 w-4" />
            导入新账单
          </Button>
        </div>
      );
    }
    if (preview) {
      return (
        <div className="grid gap-2">
          <Button className="w-full" size="lg" onClick={() => setReviewOpen(true)}>
            <ShieldCheck className="h-4 w-4" />
            继续审核
          </Button>
          <div className="grid grid-cols-2 gap-2">
            <Button className="min-w-0" variant="outline" onClick={generatePreview} disabled={loading || !file}>
              {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <FileUp className="h-4 w-4" />}
              重新预览
            </Button>
            <Button className="min-w-0 border-line text-stone hover:text-destructive" variant="outline" onClick={() => setDiscardDialogOpen(true)} disabled={loading || committing}>
              <Trash2 className="h-4 w-4" />
              丢弃草稿
            </Button>
          </div>
          {!file ? <div className="text-center text-xs leading-5 text-stone">如需重新预览，请先选择原始账单文件。</div> : null}
        </div>
      );
    }
    return (
      <Button className="w-full" size="lg" onClick={generatePreview} disabled={loading || !file}>
        {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <FileUp className="h-4 w-4" />}
        生成预览
      </Button>
    );
  }

  return (
    <div className="mx-auto min-w-0 max-w-[1220px] space-y-5 overflow-hidden">
      <Card className="min-w-0 overflow-hidden border-line bg-panel shadow-sm">
        <CardContent className="space-y-4 p-4 sm:p-5">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div className="min-w-0">
              <div className="flex items-center gap-2 font-medium text-ink"><Mail className="h-4 w-4 text-brand" />Gmail 自动账单</div>
              <div className="mt-1 text-sm text-stone">
                {gmailStatus?.connected ? `${gmailStatus.email} · 监听 ${gmailStatus.label}` : gmailStatus?.configured ? `等待连接 · 监听 ${gmailStatus.label}` : "配置 Gmail API 与 Pub/Sub 后即可连接"}
              </div>
            </div>
            <div className="flex flex-wrap gap-2">
              {gmailStatus?.connected ? (
                <>
                  <Button variant="outline" onClick={() => void syncGmail()} disabled={gmailLoading}>
                    {gmailLoading ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}立即同步
                  </Button>
                  <Button variant="outline" onClick={() => void disconnectGmail()} disabled={gmailLoading}>
                    <Trash2 className="h-4 w-4" />断开
                  </Button>
                </>
              ) : (
                <Button onClick={() => void connectGmail()} disabled={gmailLoading || !gmailStatus?.configured}>
                  {gmailLoading ? <Loader2 className="h-4 w-4 animate-spin" /> : <Mail className="h-4 w-4" />}连接 Gmail
                </Button>
              )}
            </div>
          </div>
          {gmailStatus?.lastError ? <Alert variant="destructive"><AlertTriangle className="h-4 w-4" /><span>{gmailStatus.lastError}</span></Alert> : null}
          {reviewablePendingImports.length > 0 ? (
            <div className="grid gap-2">
              {reviewablePendingImports.map((item) => {
                const actions = gmailPendingImportActions(item.status);
                return (
                  <div key={item.id} className="flex min-w-0 flex-col gap-3 rounded-2xl border border-line bg-paper p-3 sm:flex-row sm:items-center">
                    <div className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-[var(--selected-bg)] text-brand"><Inbox className="h-5 w-5" /></div>
                    <div className="min-w-0 flex-1">
                      <div className="flex min-w-0 flex-wrap items-center gap-2">
                        <Badge variant={item.status === "ready" ? "outline" : "destructive"}>{item.status === "ready" ? "待 Review" : "解析失败"}</Badge>
                        <span className="truncate text-sm font-medium text-ink">{item.subject || item.filename}</span>
                      </div>
                      <div className="mt-1 truncate text-xs text-stone">{item.sender} · {item.filename}{item.status === "ready" ? ` · ${item.candidateCount} 条` : ""}</div>
                      {item.error ? <div className="mt-1 line-clamp-2 text-xs text-destructive">{item.error}</div> : null}
                    </div>
                    <div className="flex shrink-0 gap-2">
                      {actions.retry ? <Button variant="outline" size="sm" onClick={() => void retryPendingImport(item)} disabled={gmailLoading}><RefreshCw className="h-4 w-4" />重试</Button> : null}
                      {actions.dismiss ? <Button variant="outline" size="sm" onClick={() => void dismissPendingImport(item)} disabled={gmailLoading}><Trash2 className="h-4 w-4" />忽略</Button> : null}
                      {actions.review ? <Button size="sm" onClick={() => void openPendingImport(item)} disabled={gmailLoading}>Review<ArrowRight className="h-4 w-4" /></Button> : null}
                    </div>
                  </div>
                );
              })}
            </div>
          ) : gmailStatus?.connected ? <div className="rounded-2xl border border-dashed border-line px-4 py-5 text-center text-sm text-stone">当前没有待 Review 的 Gmail 账单</div> : null}
        </CardContent>
      </Card>

      <Card className="min-w-0 overflow-hidden border-line bg-panel shadow-sm">
        <CardContent className="grid min-w-0 items-start gap-4 bg-paper/45 px-4 py-4 sm:px-6 lg:grid-cols-[minmax(260px,380px)_minmax(0,1fr)] xl:grid-cols-[minmax(280px,400px)_minmax(0,1fr)]">
          <div className="min-w-0">
            <div
              role="button"
              tabIndex={0}
              className={cn(
                "group flex min-h-44 min-w-0 cursor-pointer flex-col items-center justify-center rounded-2xl border border-dashed border-line bg-panel p-4 text-center outline-none transition focus-visible:ring-2 focus-visible:ring-[var(--focus-ring)] sm:min-h-52 sm:p-5 lg:min-h-[22rem] lg:w-full",
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
              <input ref={inputRef} type="file" className="hidden" accept=".csv,.xlsx,.xls,.pdf,.eml,.html,.htm,.zip" onChange={(event) => resetForFile(event.target.files?.[0] ?? null)} />
              <div className="grid h-14 w-14 place-items-center rounded-2xl border border-line bg-panel text-brand shadow-sm transition group-hover:scale-105">
                <UploadCloud className="h-7 w-7" />
              </div>
              <div className="mt-4 text-base font-medium leading-6 text-ink">拖拽账单到这里，或点击选择文件</div>
              <div className="mt-1 max-w-full break-words text-sm text-stone">当前模式：{selectedProvider.label} · {selectedProvider.accept}</div>
              <div className="mt-1 text-xs leading-5 text-stone">支持普通 ZIP 和经典 ZipCrypto 加密压缩包</div>
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
            {isZipUpload ? (
              <Label className="mt-4 block w-full text-left">
                <span className="mb-2 block text-sm font-medium text-ink">压缩包密码（可选）</span>
                <Input
                  type="password"
                  value={archivePassword}
                  maxLength={256}
                  autoComplete="off"
                  placeholder="输入账单压缩包密码"
                  className="h-10 rounded-xl bg-panel"
                  onChange={(event) => setArchivePassword(event.target.value)}
                />
                <span className="mt-1 block text-xs leading-5 text-stone">留空时会尝试服务端已配置密码和六位数字密码。</span>
              </Label>
            ) : null}
          </div>

          <div className="grid min-w-0 max-w-full gap-3 overflow-hidden">
            <div className="grid min-w-0 gap-3 xl:grid-cols-[minmax(0,1fr)_minmax(260px,320px)]">
              <div className="min-w-0 max-w-full overflow-hidden rounded-2xl border border-line bg-paper">
                <button type="button" className="flex w-full min-w-0 items-center justify-between gap-3 px-4 py-3 text-left" onClick={() => setProviderOpen((value) => !value)}>
                  <span className="min-w-0 flex-1 overflow-hidden">
                    <span className="block truncate font-medium text-ink">{preview ? "预览来源" : "来源设置"}：{preview ? providerLabel(preview.provider, providerChoices) : selectedProvider.label}</span>
                    <span className="mt-1 block truncate text-xs text-stone">{isRestoredDraft ? "草稿已恢复，重新预览需要重新选择文件。" : selectedProvider.detail}</span>
                  </span>
                  {providerOpen ? <ChevronUp className="h-4 w-4 shrink-0 text-stone" /> : <ChevronDown className="h-4 w-4 shrink-0 text-stone" />}
                </button>
                {providerOpen && isRestoredDraft ? (
                  <div className="border-t border-line p-3 text-xs leading-5 text-stone">
                    当前草稿来自 {preview ? providerLabel(preview.provider, providerChoices) : selectedProvider.label}。选择文件后可以重新生成预览并覆盖这份草稿。
                  </div>
                ) : providerOpen ? (
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

              <div className="min-w-0 max-w-full overflow-hidden rounded-2xl border border-line bg-panel p-3">
                <div className="mb-3 flex min-w-0 items-center justify-between gap-3 px-1 text-xs text-stone">
                  <div className="min-w-0">
                    <div className="truncate text-sm font-medium text-ink">
                      {importStage === "done" ? "导入已完成" : importStage === "review" ? "预览已生成" : importStage === "ready" ? "文件已就绪" : "等待账单文件"}
                    </div>
                    <div className="mt-1 flex min-w-0 flex-wrap items-center gap-1.5">
                      <span className={cn("rounded-full px-2 py-0.5", Boolean(file) || Boolean(preview) ? "bg-[var(--selected-bg)] text-brand" : "bg-tag text-stone")}>选择</span>
                      <span className={cn("rounded-full px-2 py-0.5", preview ? "bg-[var(--selected-bg)] text-brand" : "bg-tag text-stone")}>预览</span>
                      <span className={cn("rounded-full px-2 py-0.5", hasCommitted ? "bg-[var(--selected-bg)] text-brand" : "bg-tag text-stone")}>写入</span>
                    </div>
                  </div>
                  {draftSavedAt && !hasCommitted ? <span className="shrink-0">草稿 {formatDraftSavedAt(draftSavedAt)}</span> : null}
                </div>
                {renderPrimaryActions()}
              </div>
            </div>

            <LastImportByProviderPanel
              latestByProvider={latestImportsByProvider}
              loading={documentsLoading}
              providerChoices={providerChoices}
              onRefresh={() => void loadImportDocuments(true)}
            />

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

          </div>
        </CardContent>
      </Card>

      {preview ? (
        <Card className="min-w-0 overflow-hidden border-line bg-panel shadow-sm">
          <CardContent className="flex min-w-0 flex-col gap-4 p-4 sm:p-5 lg:flex-row lg:items-center lg:justify-between">
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-2">
                <Badge variant="outline" className={hasCommitted ? "border-brand/30 bg-[var(--selected-bg)] text-brand" : undefined}>{hasCommitted ? "已写入" : "待审核"}</Badge>
                {activePendingId ? <Badge variant="secondary">Gmail 自动导入</Badge> : isRestoredDraft ? <Badge variant="secondary">已恢复草稿</Badge> : null}
                <Badge variant="secondary">{providerLabel(preview.provider, providerChoices)}</Badge>
                <span className="text-sm text-stone">{entries.length} 条交易</span>
              </div>
              <div className="mt-2 line-clamp-2 break-all font-medium text-ink">{preview.originalFilename}</div>
              <div className="mt-1 text-sm text-stone">
                {preview.dateStart ?? "?"} 到 {preview.dateEnd ?? "?"}
                {draftSavedAt && !hasCommitted ? <span> · 草稿保存于 {formatDraftSavedAt(draftSavedAt)}</span> : null}
              </div>
            </div>
            <div className="grid min-w-0 grid-cols-2 gap-2 sm:flex sm:justify-end">
              {hasCommitted ? (
                <Button variant="outline" onClick={clearImportState}>
                  <FileUp className="h-4 w-4" />
                  导入新账单
                </Button>
              ) : (
                <Button variant="outline" className="border-line text-stone hover:text-destructive" onClick={() => setDiscardDialogOpen(true)} disabled={committing}>
                  <Trash2 className="h-4 w-4" />
                  丢弃草稿
                </Button>
              )}
              <Button onClick={() => setReviewOpen(true)} variant={hasCommitted ? "secondary" : "default"}>
                {hasCommitted ? <CheckCircle className="h-4 w-4" /> : <ShieldCheck className="h-4 w-4" />}
                {hasCommitted ? "查看结果" : "继续审核"}
              </Button>
            </div>
          </CardContent>
        </Card>
      ) : null}

      {preview ? (
        <MobileSheet
          open={reviewOpen}
          title={(
            <>
              <span className="sm:hidden">导入审核</span>
              <span className="hidden sm:inline">{providerLabel(preview.provider, providerChoices)}导入审核</span>
            </>
          )}
          onClose={() => setReviewOpen(false)}
          shouldClose={() => !committing}
          size="xl"
          align="center"
          bodyClassName="!p-0 xl:!overflow-hidden"
          panelClassName="!h-[100dvh] !max-h-[100dvh] !rounded-none sm:!h-[92dvh] sm:!max-h-[calc(100dvh-env(safe-area-inset-top)-0.75rem)] sm:!rounded-3xl xl:!h-[96dvh] xl:!max-h-[96dvh] xl:!max-w-[98vw] 2xl:!max-w-[1720px]"
          closeLabel={committing ? "写入中" : "关闭"}
          footer={
            <div>
              <div className="grid min-w-0 gap-2 sm:hidden">
                <div className="flex min-w-0 flex-wrap items-center gap-2 text-xs leading-5 text-stone">
                  <Badge variant={hasCommitted ? "secondary" : "outline"} className={hasCommitted ? "border-brand/30 bg-[var(--selected-bg)] text-brand" : undefined}>
                    {hasCommitted ? `已写入 ${commitResult?.count ?? 0}` : `${entries.length} 待写入`}
                  </Badge>
                  {!hasCommitted && invalidEntryCount > 0 ? <span className="text-[var(--warning)]">{invalidEntryCount} 条需修正</span> : null}
                  <span className="tabular-nums">{reviewTotalAmount}</span>
                </div>
                <div className="grid min-w-0 grid-cols-[minmax(0,1fr)_minmax(0,1.25fr)] gap-2">
                  <Button className="min-w-0" variant="outline" onClick={() => setReviewOpen(false)} disabled={committing}>{hasCommitted ? "关闭" : "稍后"}</Button>
                  <Button className="min-w-0" onClick={commitImport} disabled={!canCommit}>
                    {committing ? <Loader2 className="h-4 w-4 animate-spin" /> : hasCommitted ? <CheckCircle className="h-4 w-4" /> : <ShieldCheck className="h-4 w-4" />}
                    {committing ? "写入中" : hasCommitted ? "已写入" : "确认写入"}
                  </Button>
                </div>
                {!hasCommitted ? (
                  <Button className="h-8 min-w-0 justify-start px-0 text-xs text-stone hover:text-destructive" variant="ghost" onClick={() => setDiscardDialogOpen(true)} disabled={committing}>
                    <Trash2 className="h-3.5 w-3.5" /> 丢弃草稿
                  </Button>
                ) : null}
              </div>
              <div className="hidden min-w-0 flex-col gap-3 sm:flex sm:flex-row sm:items-center sm:justify-between">
                <div className="flex min-w-0 flex-wrap items-center gap-2 text-xs leading-5 text-stone">
                <Badge variant={hasCommitted ? "secondary" : "outline"} className={hasCommitted ? "border-brand/30 bg-[var(--selected-bg)] text-brand" : undefined}>
                  {hasCommitted ? `已写入 ${commitResult?.count ?? 0}` : `待写入 ${entries.length}`}
                </Badge>
                {!hasCommitted && invalidEntryCount > 0 ? <span className="text-[var(--warning)]">{invalidEntryCount} 条分录需修正</span> : null}
                <span>{removedEntryCount > 0 ? `已移除 ${removedEntryCount}` : "未移除候选"}</span>
                <span className="tabular-nums">{reviewTotalAmount} 合计</span>
                </div>
                <div className="grid w-full min-w-0 grid-cols-1 gap-2 sm:w-auto sm:grid-cols-[auto_auto_auto]">
                  <Button className="min-w-0 sm:min-w-28" variant="outline" onClick={() => setReviewOpen(false)} disabled={committing}>{hasCommitted ? "关闭" : "稍后处理"}</Button>
                  {hasCommitted ? (
                    <Button className="min-w-0 sm:min-w-32" variant="secondary" onClick={clearImportState}>
                      <FileUp className="h-4 w-4" />
                      导入新账单
                    </Button>
                  ) : (
                    <Button className="min-w-0 border-line text-stone hover:text-destructive sm:min-w-28" variant="outline" onClick={() => setDiscardDialogOpen(true)} disabled={committing}>
                      <Trash2 className="h-4 w-4" />
                      丢弃草稿
                    </Button>
                  )}
                  <Button className="min-w-0 sm:min-w-36" onClick={commitImport} disabled={!canCommit}>
                    {committing ? <Loader2 className="h-4 w-4 animate-spin" /> : hasCommitted ? <CheckCircle className="h-4 w-4" /> : <ShieldCheck className="h-4 w-4" />}
                    {committing ? "正在写入..." : hasCommitted ? "已写入" : "确认写入账本"}
                  </Button>
                </div>
              </div>
            </div>
          }
        >
          <div className="flex h-full min-h-0 min-w-0 flex-col bg-paper">
            <div className="shrink-0 border-b border-line bg-panel px-3 py-2 sm:px-5 sm:py-4 xl:py-3">
              <div className="grid min-w-0 gap-3 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-center">
                <div className="min-w-0">
                  <div className="flex min-w-0 flex-wrap items-center gap-2">
                    <Badge variant="outline">{confidenceLabel(preview.providerDetection.confidence)}</Badge>
                    <Badge variant="secondary">{providerLabel(preview.provider, providerChoices)}</Badge>
                    <span className="min-w-0 break-all text-sm font-medium leading-5 text-ink">{preview.originalFilename}</span>
                  </div>
                  <div className="mt-1 hidden text-xs leading-5 text-stone sm:block">{preview.providerDetection.reason}</div>
                </div>
                <div className="hidden grid-cols-[auto_auto] items-center gap-3 rounded-xl border border-line bg-panel px-3 py-2 text-sm text-stone sm:grid">
                  <span>{preview.dateStart ?? "?"} ~ {preview.dateEnd ?? "?"}</span>
                  <span className="rounded-lg bg-[var(--selected-bg)] px-2 py-1 font-medium text-brand">{entries.length} 待写入</span>
                </div>
              </div>
              <div className="mt-4 hidden min-w-0 grid-cols-2 gap-px overflow-hidden rounded-xl border border-line bg-line sm:grid sm:grid-cols-4 xl:mt-3">
                <ReviewMetric label="原始记录" value={preview.rawRowCount || preview.candidateCount} detail={`${preview.filteredRowCount || preview.generatedCount} 条进入预览`} />
                <ReviewMetric label="去重跳过" value={preview.skippedDuplicateCount} detail="与账本现有记录匹配" />
                <ReviewMetric label="已移除" value={removedEntryCount} detail="提交时会跳过" tone={removedEntryCount > 0 ? "warn" : "muted"} />
                <ReviewMetric label="待写入合计" value={reviewTotalAmount} detail={`${entries.length} 条候选交易`} tone="brand" />
              </div>
            </div>

            <div className="flex min-w-0 flex-1 flex-col gap-2 overflow-y-auto px-2 py-2 sm:gap-3 sm:px-5 sm:py-3 xl:min-h-0 xl:overflow-hidden xl:py-3">
              {commitResult?.ok ? (
                <Alert className="border-brand/30 bg-[var(--selected-bg)] text-olive">
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                    <div>
                      <div className="font-medium text-brand"><CheckCircle className="mr-2 inline h-4 w-4" />{(commitResult.count ?? 0) > 0 ? `已写入 ${commitResult.count} 条交易` : "已归档账单"}</div>
                      <div className="mt-1 text-stone">账单已经写入 ledger，并会随本次写入自动提交。</div>
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
                <Alert className="grid-cols-1 space-y-2 xl:max-h-24 xl:overflow-y-auto xl:pr-3">
                  {preview.warnings.map((warning) => (
                    <div key={warning} className="flex min-w-0 items-start gap-2">
                      <AlertTriangle className="mt-1 h-4 w-4 shrink-0 text-[var(--warning)]" />
                      <span className="min-w-0 break-words leading-6">{warning}</span>
                    </div>
                  ))}
                </Alert>
              ) : null}

              <div className="grid min-w-0 gap-3 xl:min-h-0 xl:flex-1 xl:grid-cols-[minmax(320px,0.72fr)_minmax(560px,1.28fr)] xl:items-stretch xl:overflow-hidden 2xl:grid-cols-[minmax(360px,0.7fr)_minmax(680px,1.3fr)]">
                <section className="hidden min-w-0 overflow-hidden rounded-xl border border-line bg-panel shadow-sm xl:order-1 xl:flex xl:min-h-0 xl:flex-col">
                  <div className="flex min-w-0 flex-col gap-2 border-b border-line bg-paper px-3 py-3 sm:flex-row sm:items-center sm:justify-between">
                    <div className="min-w-0">
                      <div className="text-sm font-medium text-ink">候选交易</div>
                      <div className="mt-0.5 text-xs text-stone">{entries.length === 0 ? "确认后会归档原始账单。" : "逐条核对，移除后只提交剩余交易。"}</div>
                    </div>
                    <div className="flex min-w-0 flex-wrap items-center gap-2 text-xs text-stone">
                      <span className="rounded-full bg-tag px-2 py-1">{entries.length} 待写入</span>
                      <span className="rounded-full bg-tag px-2 py-1">{removedEntryCount} 已移除</span>
                    </div>
                  </div>
                  {entries.length === 0 ? (
                    <div className="px-4 py-10 text-center text-sm text-stone">没有待写入交易，确认后归档账单文件。</div>
                  ) : (
                    <div className="divide-y divide-line xl:min-h-0 xl:flex-1 xl:overflow-y-auto">
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
                            <button type="button" className="min-w-0 px-3 py-2.5 pl-4 text-left" onClick={() => selectReviewEntry(entry.id)}>
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
                                  <div className="font-serif text-lg font-medium leading-none text-warm tabular-nums">{formatMoney(entry.amount, entry.currency)}</div>
                                  <div className="mt-1 truncate text-[11px] text-stone">{accountDisplayName(importFlowForEntry(entry).to)}</div>
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
                              title="移除这条候选交易"
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
                  <aside ref={reviewDetailRef} className="order-1 min-w-0 scroll-mt-3 overflow-hidden rounded-xl border border-line bg-panel shadow-sm xl:order-2 xl:min-h-0 xl:overflow-y-auto">
                    <div className="border-b border-line bg-paper px-4 py-3">
                      <div className="flex min-w-0 items-center justify-between gap-3">
                        <div className="min-w-0">
                          <div className="text-[11px] uppercase tracking-[0.12em] text-stone">正在编辑</div>
                          <div className="mt-1 text-lg font-medium leading-7 text-ink">{selectedEntryIndex + 1}/{entries.length}</div>
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
                    </div>

                    <div className="space-y-4 p-4">
                      <ImportEntryEditor
                        entry={selectedEntry}
                        fromLabel={accountDisplayName(importFlowForEntry(selectedEntry).from)}
                        toLabel={accountDisplayName(importFlowForEntry(selectedEntry).to)}
                        accountOptions={postingAccountOptions(selectedEntry)}
                        disabled={committing || hasCommitted}
                        onEntryChange={(patch) => updateEntry(selectedEntry.id, patch)}
                        onPostingChange={(index, patch) => updatePosting(selectedEntry.id, index, patch)}
                        onPostingAdd={() => addPosting(selectedEntry.id)}
                        onPostingRemove={(index) => removePosting(selectedEntry.id, index)}
                      />

                      <details open className="rounded-xl border border-line bg-paper px-3 py-2.5">
                        <summary className="cursor-pointer text-xs font-medium text-olive"><Pencil className="mr-1 inline h-3 w-3" />备注 / metadata</summary>
                        <div className="mt-3 grid gap-2">
                          <Label className="block">
                            <span className="mb-1.5 block text-xs text-stone">note</span>
                            <Input className="h-10 border-line bg-panel shadow-sm" value={selectedEntry.metadata.note ?? ""} onChange={(event) => updateMetadata(selectedEntry.id, "note", event.target.value)} placeholder="添加备注" disabled={committing || hasCommitted} />
                          </Label>
                          <Label className="block">
                            <span className="mb-1.5 block text-xs text-stone">purpose</span>
                            <Input className="h-10 border-line bg-panel shadow-sm" value={selectedEntry.metadata.purpose ?? ""} onChange={(event) => updateMetadata(selectedEntry.id, "purpose", event.target.value)} placeholder="例如: travel / work" disabled={committing || hasCommitted} />
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
                        移除当前候选
                      </Button>
                    </div>
                  </aside>
                ) : null}

                {entries.length > 0 ? (
                  <details className="order-2 min-w-0 overflow-hidden rounded-xl border border-line bg-panel shadow-sm xl:hidden">
                    <summary className="flex cursor-pointer list-none items-center justify-between gap-3 bg-paper px-3 py-3 text-sm font-medium text-ink [&::-webkit-details-marker]:hidden">
                      <span>候选交易</span>
                      <span className="rounded-full bg-tag px-2 py-1 text-xs font-normal text-stone">{entries.length} 待写入</span>
                    </summary>
                    <div className="max-h-80 divide-y divide-line overflow-y-auto border-t border-line">
                      {entries.map((entry, index) => {
                        const selected = selectedEntry?.id === entry.id;
                        return (
                          <article key={entry.id} className={cn("grid min-w-0 grid-cols-[minmax(0,1fr)_2.5rem] items-center", selected ? "bg-[var(--selected-bg)]" : "bg-panel")}>
                            <button type="button" className="min-w-0 px-3 py-2 text-left" onClick={() => selectReviewEntry(entry.id)}>
                              <div className="flex min-w-0 items-center justify-between gap-3">
                                <div className="min-w-0">
                                  <div className="flex min-w-0 items-center gap-2">
                                    <span className="font-mono text-[11px] text-stone">{String(index + 1).padStart(2, "0")}</span>
                                    <span className="min-w-0 truncate text-sm font-medium text-ink">{entry.payee || "未命名商户"}</span>
                                  </div>
                                  <div className="mt-0.5 truncate text-xs text-stone">{entry.date} · {entry.narration || "未填写标题"}</div>
                                </div>
                                <div className="shrink-0 text-right font-serif text-sm font-medium text-warm tabular-nums">{formatMoney(entry.amount, entry.currency)}</div>
                              </div>
                            </button>
                            <Button type="button" variant="ghost" size="icon-sm" className="mr-1 text-stone hover:text-destructive" onClick={() => removeEntry(entry.id)} disabled={committing || hasCommitted} title="移除这条候选交易">
                              <Trash2 className="h-4 w-4" />
                            </Button>
                          </article>
                        );
                      })}
                    </div>
                  </details>
                ) : null}
              </div>

              <div className="shrink-0 overflow-hidden rounded-xl border border-line bg-panel">
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

      <ImportHistoryPanel documents={importDocuments} loading={documentsLoading} error={documentsError} providerChoices={providerChoices} onRefresh={() => void loadImportDocuments(true)} />

      <AlertDialog open={discardDialogOpen} onOpenChange={setDiscardDialogOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>丢弃这份导入草稿？</AlertDialogTitle>
            <AlertDialogDescription>
              这只会删除浏览器里保存的导入审核状态，不会改动账本，也不会删除原始账单文件。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>继续审核</AlertDialogCancel>
            <AlertDialogAction className="bg-destructive text-white hover:bg-destructive/90" onClick={clearImportState}>确认丢弃</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

function LastImportByProviderPanel({
  latestByProvider,
  loading,
  providerChoices,
  onRefresh,
}: {
  latestByProvider: Partial<Record<Provider, ImportDocument>>;
  loading: boolean;
  providerChoices: ProviderChoice[];
  onRefresh: () => void;
}) {
  const providers = providerChoices.filter((choice): choice is ProviderChoice & { value: Provider } => isProvider(choice.value));
  return (
    <div className="min-w-0 max-w-full overflow-hidden rounded-2xl border border-line bg-paper p-3">
      <div className="flex min-w-0 items-center justify-between gap-3">
        <div className="min-w-0">
          <div className="flex min-w-0 items-center gap-2">
            <CalendarClock className="h-4 w-4 shrink-0 text-brand" />
            <div className="truncate text-sm font-medium text-ink">账单截止日</div>
          </div>
        </div>
        <Button type="button" variant="outline" size="icon-sm" onClick={onRefresh} disabled={loading} title="刷新导入记录">
          <RefreshCw className={cn("h-4 w-4", loading ? "animate-spin" : "")} />
        </Button>
      </div>

      <div className="mt-3 grid min-w-0 grid-cols-2 gap-2 sm:grid-cols-3 xl:grid-cols-5">
        {providers.map((provider) => {
          const document = latestByProvider[provider.value];
          return (
            <div key={provider.value} className="min-w-0 rounded-xl border border-line bg-panel px-3 py-2" title={document ? `${provider.label}: ${formatImportDocumentRange(document)} · ${document.name}` : `${provider.label}: 暂无记录`}>
              <div className="truncate text-xs leading-5 text-stone">{provider.label}</div>
              <div className={cn("mt-0.5 truncate text-sm font-medium tabular-nums", document ? "text-brand" : "text-stone")}>
                {document ? document.dateEnd || document.dateStart || "未知日期" : "暂无记录"}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function ImportHistoryPanel({
  documents,
  loading,
  error,
  providerChoices,
  onRefresh,
}: {
  documents: ImportDocument[];
  loading: boolean;
  error: string;
  providerChoices: ProviderChoice[];
  onRefresh: () => void;
}) {
  const totalSize = documents.reduce((sum, document) => sum + document.size, 0);
  return (
    <Card className="min-w-0 overflow-hidden border-line bg-panel shadow-sm">
      <CardContent className="p-0">
        <div className="flex min-w-0 flex-col gap-3 border-b border-line bg-paper px-4 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-5">
          <div className="min-w-0">
            <div className="flex min-w-0 items-center gap-2">
              <FileArchive className="h-4 w-4 shrink-0 text-brand" />
              <h2 className="truncate text-sm font-medium text-ink">历史导入文件</h2>
            </div>
            <div className="mt-1 text-xs leading-5 text-stone">{documents.length ? `${documents.length} 个归档文件 · ${fileSize(totalSize)}` : "提交导入后，原始账单会显示在这里。"}</div>
          </div>
          <Button type="button" variant="outline" size="sm" onClick={onRefresh} disabled={loading}>
            <RefreshCw className={cn("h-4 w-4", loading ? "animate-spin" : "")} />
            刷新
          </Button>
        </div>

        {error ? (
          <Alert variant="destructive" className="m-4 flex items-start gap-2 sm:m-5">
            <AlertTriangle className="mt-1 h-4 w-4 shrink-0" />
            <span>{error}</span>
          </Alert>
        ) : documents.length === 0 ? (
          <div className="grid min-h-36 place-items-center px-4 py-8 text-center text-sm text-stone">
            {loading ? "正在读取历史导入文件…" : "还没有归档的原始账单文件。"}
          </div>
        ) : (
          <div className="divide-y divide-line">
            {documents.map((document) => {
              const href = importDocumentHref(document);
              return (
                <article key={document.path} className="grid min-w-0 gap-3 px-4 py-3 transition hover:bg-paper sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center sm:px-5">
                  <div className="flex min-w-0 items-start gap-3">
                    <div className="mt-0.5 grid h-10 w-10 shrink-0 place-items-center rounded-xl border border-line bg-paper text-brand">
                      <FileText className="h-5 w-5" />
                    </div>
                    <div className="min-w-0 flex-1">
                      <div className="flex min-w-0 flex-wrap items-center gap-2">
                        <span className="min-w-0 break-all text-sm font-medium leading-5 text-ink">{document.name}</span>
                        <Badge variant="secondary">{importDocumentTypeLabel(document)}</Badge>
                        {document.provider ? <Badge variant="outline">{providerLabel(document.provider as Provider, providerChoices)}</Badge> : null}
                      </div>
                      <div className="mt-1 flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 text-xs leading-5 text-stone">
                        <span>{formatImportDocumentRange(document)}</span>
                        <span>{document.year}</span>
                        <span>{fileSize(document.size)}</span>
                        <span>{formatImportDocumentTime(document.modTime)}</span>
                      </div>
                      <div className="mt-1 break-all font-mono text-[11px] leading-5 text-stone">{document.path}</div>
                    </div>
                  </div>
                  <div className="grid min-w-0 grid-cols-2 gap-2 sm:flex sm:justify-end">
                    <Button asChild variant="outline" size="sm" className="min-w-0">
                      <a href={href} target="_blank" rel="noreferrer">
                        <ExternalLink className="h-4 w-4" />
                        打开
                      </a>
                    </Button>
                    <Button asChild variant="secondary" size="sm" className="min-w-0">
                      <a href={href} download={document.name}>
                        <Download className="h-4 w-4" />
                        下载
                      </a>
                    </Button>
                  </div>
                </article>
              );
            })}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

function importDocumentHref(document: ImportDocument) {
  return activeApiEndpointRequestUrl(`/api/ledger/imports/documents/file?path=${encodeURIComponent(document.path)}`);
}

function importDocumentTypeLabel(document: ImportDocument) {
  const ext = document.ext.replace(".", "").trim();
  return ext ? ext.toUpperCase() : "FILE";
}

function formatImportDocumentRange(document: ImportDocument) {
  if (document.dateStart && document.dateEnd) return `${document.dateStart} ~ ${document.dateEnd}`;
  return "未知账期";
}

function formatImportDocumentTime(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "未知时间";
  return date.toLocaleString("zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
}

export function importFlowForEntry(entry: ImportEntry) {
  const category = entry.categoryAccount;
  const funding = entry.fundingAccount;
  const postings = entry.postings.map((posting) => ({
    account: posting.account.startsWith("Expenses:") || posting.account.startsWith("Income:") ? category : posting.account,
    amount: Number(posting.amount),
  }));
  const outflow = postings.find((posting) => posting.amount < 0);
  const inflow = postings.find((posting) => posting.amount > 0);
  if (outflow && inflow) {
    if (category.startsWith("Income:")) return { from: outflow.account, to: inflow.account, kind: "收入流入" };
    if (category.startsWith("Expenses:")) return { from: outflow.account, to: inflow.account, kind: outflow.account === category ? "退款流入" : "支出流向" };
    return { from: outflow.account, to: inflow.account, kind: "账户转移" };
  }
  if (category.startsWith("Income:")) return { from: category, to: funding || category, kind: "收入流入" };
  if (category.startsWith("Expenses:")) return { from: funding || category, to: category, kind: "支出流向" };
  return { from: funding || postings[0]?.account || category, to: category || postings[1]?.account || funding, kind: "资金流向" };
}

function isCategoryPosting(account: string) {
  return account.startsWith("Expenses:") || account.startsWith("Income:");
}

function normalizeImportPostingAccounts(entry: ImportEntry, postings: ImportPosting[]) {
  const accounts = new Set(postings.map((posting) => posting.account).filter(Boolean));
  const categoryAccount = accounts.has(entry.categoryAccount)
    ? entry.categoryAccount
    : postings.find((posting) => isCategoryPosting(posting.account))?.account || postings[0]?.account || entry.categoryAccount;
  const fundingAccount = accounts.has(entry.fundingAccount) && entry.fundingAccount !== categoryAccount
    ? entry.fundingAccount
    : postings.find((posting) => posting.account && posting.account !== categoryAccount && !isCategoryPosting(posting.account))?.account
      || postings.find((posting) => posting.account && posting.account !== categoryAccount)?.account
      || entry.fundingAccount;
  const amountPosting = postings.find((posting) => posting.account === fundingAccount)
    ?? postings.find((posting) => posting.account === categoryAccount)
    ?? postings.find((posting) => Number.isFinite(Number(posting.amount)));
  const amount = amountPosting && Number.isFinite(Number(amountPosting.amount)) ? Math.abs(Number(amountPosting.amount)) : entry.amount;
  return {
    ...entry,
    categoryAccount,
    fundingAccount,
    amount,
    currency: amountPosting?.currency || entry.currency,
    postings,
  };
}

export function updateImportPosting(entry: ImportEntry, index: number, patch: Partial<ImportPosting>) {
  const currentPosting = entry.postings[index];
  if (!currentPosting) return entry;
  const postings = entry.postings.map((posting, postingIndex) => (postingIndex === index ? { ...posting, ...patch } : posting));
  const nextEntry = { ...entry };
  if (patch.account !== undefined) {
    if (currentPosting.account === entry.categoryAccount) nextEntry.categoryAccount = patch.account;
    if (currentPosting.account === entry.fundingAccount) nextEntry.fundingAccount = patch.account;
  }
  return normalizeImportPostingAccounts(nextEntry, postings);
}

export function appendImportPosting(entry: ImportEntry) {
  const currency = entry.postings.at(-1)?.currency || entry.currency || "CNY";
  return normalizeImportPostingAccounts(entry, [...entry.postings, { account: "", amount: "", currency }]);
}

export function removeImportPosting(entry: ImportEntry, index: number) {
  if (entry.postings.length <= 2 || !entry.postings[index]) return entry;
  return normalizeImportPostingAccounts(entry, entry.postings.filter((_, postingIndex) => postingIndex !== index));
}

export function summarizeImportPostings(postings: ImportPosting[]) {
  const totals = new Map<string, number>();
  let hasInvalidAmount = false;
  for (const posting of postings) {
    const amount = Number(posting.amount);
    const currency = posting.currency.trim().toUpperCase() || "未指定";
    if (!Number.isFinite(amount)) {
      hasInvalidAmount = true;
      continue;
    }
    totals.set(currency, (totals.get(currency) ?? 0) + amount);
  }
  return {
    hasInvalidAmount,
    totals: [...totals.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([currency, amount]) => ({ currency, amount })),
  };
}

export function importEntryHasReviewError(entry: ImportEntry) {
  return entry.postings.length < 2 || entry.postings.some((posting) => (
    !posting.account.trim()
    || !posting.amount.trim()
    || !Number.isFinite(Number(posting.amount))
    || !posting.currency.trim()
  ));
}

function ImportEntryEditor({
  entry,
  fromLabel,
  toLabel,
  accountOptions,
  disabled,
  onEntryChange,
  onPostingChange,
  onPostingAdd,
  onPostingRemove,
}: {
  entry: ImportEntry;
  fromLabel: string;
  toLabel: string;
  accountOptions: AccountOption[];
  disabled: boolean;
  onEntryChange: (patch: Partial<ImportEntry>) => void;
  onPostingChange: (index: number, patch: Partial<ImportPosting>) => void;
  onPostingAdd: () => void;
  onPostingRemove: (index: number) => void;
}) {
  const flow = importFlowForEntry(entry);
  const postingSummary = summarizeImportPostings(entry.postings);
  const metaItems = [
    { label: "方式", value: entry.method || "-" },
    { label: "订单号", value: entry.orderId || "-" },
  ];
  return (
    <div className="grid min-w-0 gap-3 sm:gap-4">
      <section className="rounded-xl border border-brand/25 bg-[var(--selected-bg)] p-3 sm:p-4">
        <div className="flex min-w-0 flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
          <div className="min-w-0">
            <div className="text-xs font-medium text-brand">{flow.kind}</div>
            <div className="mt-1 truncate text-lg font-medium leading-7 text-ink" title={entry.payee || "未命名商户"}>{entry.payee || "未命名商户"}</div>
            <div className="mt-2 flex min-w-0 flex-wrap items-center gap-2">
              <Badge variant="secondary" className="bg-panel text-warm">{entry.date}</Badge>
              <Badge variant="outline" className="border-brand/35 bg-panel text-warm">{entry.postings.length} 个账户</Badge>
              {entry.source ? <Badge variant="outline" className="border-brand/50 bg-panel text-brand">{entry.source}</Badge> : null}
            </div>
          </div>
          <div className="shrink-0 text-left sm:text-right">
            <div className="font-serif text-2xl font-medium leading-none text-warm tabular-nums">{formatMoney(entry.amount, entry.currency)}</div>
            <div className="mt-1 text-xs text-stone">主金额</div>
          </div>
        </div>
        <div className="mt-3 grid min-w-0 grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-2 border-t border-brand/15 pt-3">
          <FlowEndpoint label="从" account={fromLabel} raw={flow.from} />
          <span className="grid h-8 w-8 place-items-center rounded-full border border-brand/25 bg-panel text-brand" aria-hidden="true">
            <ArrowRight className="h-4 w-4" />
          </span>
          <FlowEndpoint label="到" account={toLabel} raw={flow.to} align="right" />
        </div>
      </section>

      <section className="rounded-xl border border-line bg-paper p-3 sm:p-4">
        <div className="mb-3">
          <div className="text-sm font-medium text-ink">交易信息</div>
          <div className="mt-0.5 hidden text-xs text-stone sm:block">日期、状态、收付款方和账本标题都可以在审核时修正。</div>
        </div>
        <div className="grid min-w-0 gap-3 sm:grid-cols-[minmax(9rem,0.7fr)_7rem_minmax(0,1.3fr)]">
          <Label className="block min-w-0">
            <span className="mb-1.5 block text-xs text-stone">日期</span>
            <Input type="date" className="h-10 min-w-0 bg-panel" value={entry.date} onChange={(event) => onEntryChange({ date: event.target.value })} disabled={disabled} />
          </Label>
          <Label className="block min-w-0">
            <span className="mb-1.5 block text-xs text-stone">状态</span>
            <Select value={entry.flag} onValueChange={(value) => onEntryChange({ flag: value as ImportEntry["flag"] })} disabled={disabled}>
              <SelectTrigger className="h-10 w-full min-w-0 rounded-xl bg-panel"><SelectValue /></SelectTrigger>
              <SelectContent><SelectItem value="*">* 已确认</SelectItem><SelectItem value="!">! 待确认</SelectItem></SelectContent>
            </Select>
          </Label>
          <Label className="block min-w-0">
            <span className="mb-1.5 block text-xs text-stone">收付款方</span>
            <Input className="h-10 min-w-0 bg-panel" value={entry.payee} onChange={(event) => onEntryChange({ payee: event.target.value })} disabled={disabled} />
          </Label>
        </div>
        <Label className="mt-3 block min-w-0">
          <span className="mb-1.5 block text-xs text-stone">账本标题</span>
          <Input className="h-10 min-w-0 bg-panel" value={entry.narration} onChange={(event) => onEntryChange({ narration: event.target.value })} disabled={disabled} />
        </Label>
      </section>

      <section className="rounded-xl border border-line bg-panel/60 p-3 sm:p-4">
        <div className="flex min-w-0 items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="text-sm font-medium text-ink">分录明细</div>
            <div className="mt-0.5 hidden text-xs leading-5 text-stone sm:block">每一行都是一条 Beancount posting，可编辑来源账户、目标账户并添加拆分账户。</div>
          </div>
          <Button type="button" variant="outline" className="h-9 shrink-0 rounded-xl bg-paper px-3" onClick={onPostingAdd} disabled={disabled}>
            <Plus className="h-4 w-4" />
            添加账户
          </Button>
        </div>

        <div className="mt-3 flex min-w-0 flex-wrap items-center gap-2 text-xs">
          {postingSummary.totals.map((total) => {
            const balanced = Math.abs(total.amount) < 0.000001;
            return <span key={total.currency} className={cn("rounded-full border px-2 py-1 tabular-nums", balanced ? "border-brand/30 bg-[var(--selected-bg)] text-brand" : "border-[var(--warning)]/40 bg-[var(--warning)]/10 text-[var(--warning)]")}>{total.currency} 小计 {balanced ? "0.00" : total.amount.toFixed(2)}</span>;
          })}
          {postingSummary.hasInvalidAmount ? <span className="rounded-full bg-destructive/10 px-2 py-1 text-destructive">存在无效金额</span> : null}
          {entry.postings.some((posting) => posting.priceKind || posting.priceAmount || posting.priceCurrency) ? <span className="text-stone">带价格的多币种分录以写入前校验为准</span> : null}
        </div>

        <div className="mt-3 grid min-w-0 gap-3">
          {entry.postings.map((posting, index) => {
            const role = posting.account === entry.categoryAccount ? "主分类" : posting.account === entry.fundingAccount ? "来源账户" : isCategoryPosting(posting.account) ? "拆分分类" : `账户 ${index + 1}`;
            const hasPrice = Boolean(posting.priceKind || posting.priceAmount || posting.priceCurrency);
            return (
              <div key={`${index}-${posting.account}`} className="min-w-0 rounded-xl border border-line bg-paper p-3">
                <div className="mb-2 flex min-w-0 items-center justify-between gap-3">
                  <div className="flex min-w-0 items-center gap-2">
                    <span className="grid h-6 w-6 shrink-0 place-items-center rounded-full bg-tag font-mono text-[11px] text-stone">{index + 1}</span>
                    <span className="truncate text-xs font-medium text-olive">{role}</span>
                  </div>
                  <Button type="button" variant="ghost" size="icon-sm" className="shrink-0 text-stone hover:text-destructive" onClick={() => onPostingRemove(index)} disabled={disabled || entry.postings.length <= 2} title={entry.postings.length <= 2 ? "至少保留 2 条分录" : "删除这条分录"}>
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>
                <div className="grid min-w-0 grid-cols-[minmax(0,1fr)_5.5rem] gap-2 lg:grid-cols-[minmax(0,1fr)_9rem_6.5rem]">
                  <Label className="col-span-2 block min-w-0 lg:col-span-1">
                    <span className="mb-1.5 block text-xs text-stone">账户</span>
                    <Select value={posting.account || undefined} onValueChange={(value) => onPostingChange(index, { account: value })} disabled={disabled}>
                      <SelectTrigger className={cn("h-10 w-full min-w-0 rounded-xl bg-panel", !posting.account.trim() && "border-destructive")} aria-invalid={!posting.account.trim()}><SelectValue placeholder="选择账户" /></SelectTrigger>
                      <SelectContent className="max-h-80">
                        {accountOptions.map((account) => <SelectItem key={account.account} value={account.account}>{formatAccountOptionLabel(account.account, account.label, account.alias)}</SelectItem>)}
                      </SelectContent>
                    </Select>
                  </Label>
                  <Label className="block min-w-0">
                    <span className="mb-1.5 block text-xs text-stone">金额</span>
                    <Input className="h-10 bg-panel text-right tabular-nums" inputMode="decimal" value={posting.amount} onChange={(event) => onPostingChange(index, { amount: event.target.value })} disabled={disabled} placeholder="0.00" aria-invalid={!posting.amount.trim() || !Number.isFinite(Number(posting.amount))} />
                  </Label>
                  <Label className="block min-w-0">
                    <span className="mb-1.5 block text-xs text-stone">币种</span>
                    <Input className="h-10 bg-panel uppercase" value={posting.currency} onChange={(event) => onPostingChange(index, { currency: event.target.value.toUpperCase() })} disabled={disabled} placeholder="CNY" aria-invalid={!posting.currency.trim()} />
                  </Label>
                </div>
                <details className="mt-2 border-t border-line pt-2">
                  <summary className="cursor-pointer text-xs text-stone">价格 / 成本{hasPrice ? "（已设置）" : "（可选）"}</summary>
                  <div className="mt-2 grid min-w-0 grid-cols-2 gap-2 sm:grid-cols-3">
                    <Label className="block min-w-0">
                      <span className="mb-1.5 block text-xs text-stone">类型</span>
                      <Select value={posting.priceKind ?? "none"} onValueChange={(value) => onPostingChange(index, value === "none" ? { priceKind: undefined, priceAmount: undefined, priceCurrency: undefined } : { priceKind: value as ImportPosting["priceKind"] })} disabled={disabled}>
                        <SelectTrigger className="h-9 w-full min-w-0 rounded-xl bg-panel"><SelectValue /></SelectTrigger>
                        <SelectContent><SelectItem value="none">无</SelectItem><SelectItem value="unit">单价 @</SelectItem><SelectItem value="total">总价 @@</SelectItem></SelectContent>
                      </Select>
                    </Label>
                    <Label className="block min-w-0">
                      <span className="mb-1.5 block text-xs text-stone">价格</span>
                      <Input className="h-9 bg-panel text-right tabular-nums" inputMode="decimal" value={posting.priceAmount ?? ""} onChange={(event) => onPostingChange(index, { priceAmount: event.target.value })} disabled={disabled || !posting.priceKind} />
                    </Label>
                    <Label className="block min-w-0">
                      <span className="mb-1.5 block text-xs text-stone">计价币种</span>
                      <Input className="h-9 bg-panel uppercase" value={posting.priceCurrency ?? ""} onChange={(event) => onPostingChange(index, { priceCurrency: event.target.value.toUpperCase() })} disabled={disabled || !posting.priceKind} />
                    </Label>
                  </div>
                </details>
              </div>
            );
          })}
        </div>
      </section>

      <section className="rounded-xl border border-line bg-paper p-3">
        <div className="grid min-w-0 gap-2 text-xs leading-5 text-stone sm:grid-cols-2">
          {metaItems.map((item) => (
            <div key={item.label} className="grid min-w-0 grid-cols-[3.5rem_minmax(0,1fr)] gap-2">
              <span className="text-olive">{item.label}</span>
              <span className={cn("min-w-0", item.label === "订单号" ? "break-all" : "break-words")}>{item.value}</span>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
}

function FlowEndpoint({ label, account, raw, align = "left" }: { label: string; account: string; raw: string; align?: "left" | "right" }) {
  return (
    <div className={cn("min-w-0", align === "right" ? "text-right" : "text-left")}>
      <div className="text-[11px] text-stone">{label}</div>
      <div className="mt-1 truncate text-sm font-medium text-ink" title={account}>{account}</div>
      <div className="mt-0.5 truncate text-[11px] text-stone" title={raw}>{raw}</div>
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
      <div className="text-stone">写入会自动提交到账本仓库；读模型会在索引更新后同步最新结果。</div>
    </div>
  );
}
