import { useRef, useState } from "react";
import { readJson } from "@/lib/clientFetch";
import { apiFetch } from "@/lib/apiEndpoints";
import type { BalanceAssertion, ParsedTransaction } from "@/lib/schemas";
import { haptic } from "../haptics";
import type { ManualForm } from "../types";
import i18n from "@/i18n";
import { createLedgerOperationId, type EnqueuePendingWrites } from "../pendingLedgerOperations";

const emptyManual = (): ManualForm => ({
  kind: "expense",
  date: new Date().toISOString().slice(0, 10),
  payee: "",
  narration: "",
  amount: "",
  fromAccount: "Liabilities:CreditCard",
  toAccount: "Assets:Bank:Checking",
  category: "Expenses:Unknown",
});

function offlineOrNetworkError(error?: unknown) {
  return (typeof navigator !== "undefined" && !navigator.onLine) || error instanceof TypeError;
}

export function useEntryActions({ load, showToast, enqueuePendingWrites }: { load: (forceFresh?: boolean) => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void; enqueuePendingWrites: EnqueuePendingWrites }) {
  const [nl, setNl] = useState("");
  const [previews, setPreviews] = useState<ParsedTransaction[]>([]);
  const [parseStatus, setParseStatus] = useState<"idle" | "parsing" | "success" | "error">("idle");
  const [parseMessage, setParseMessage] = useState("");
  const [appendStatus, setAppendStatus] = useState<"idle" | "writing">("idle");
  const [entryOpen, setEntryOpen] = useState(false);
  const [manual, setManual] = useState<ManualForm>(() => emptyManual());

  const operationIdsRef = useRef(new WeakMap<ParsedTransaction, string>());
  const submittingRef = useRef(false);

  async function appendEntry(entry: ParsedTransaction | BalanceAssertion, operationId = createLedgerOperationId()) {
    const res = await apiFetch("/api/ledger/append", { method: "POST", headers: { "Content-Type": "application/json", "Idempotency-Key": operationId }, body: JSON.stringify(entry) }, { kind: "write" });
    const data = await readJson<{ error?: string }>(res);
    if (!res.ok) {
      showToast("error", data.error || i18n.t("entryActions.writeFailed"));
      return { ok: false };
    }
    return { ok: true };
  }

  async function parseNl() {
    if (!nl.trim()) {
      setParseStatus("error");
      setParseMessage(i18n.t("entryActions.enterRecord"));
      return;
    }
    setParseStatus("parsing");
    setParseMessage(i18n.t("entryActions.parsing"));
    try {
      const res = await apiFetch("/api/ai/parse", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ input: nl }) }, { kind: "write" });
      const data = await readJson<{ error?: string; entries?: ParsedTransaction[]; entry?: ParsedTransaction }>(res);
      if (!res.ok) throw new Error(data.error || i18n.t("entryActions.parseFailed"));
      const entries = Array.isArray(data.entries) ? data.entries as ParsedTransaction[] : data.entry ? [data.entry as ParsedTransaction] : [];
      if (!entries.length) throw new Error(i18n.t("entryActions.noRecords"));
      setPreviews(entries);
      setParseStatus("success");
      setParseMessage(i18n.t("entryActions.parsedCount", { count: entries.length }));
      haptic(8);
      showToast("success", i18n.t("entryActions.parseSuccess", { count: entries.length }));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setParseStatus("error");
      setParseMessage(message);
      showToast("error", message || i18n.t("entryActions.parseFailed"));
    }
  }

  function buildManualEntry(): ParsedTransaction | null {
    const amount = Number(manual.amount);
    if (!manual.date || !manual.payee.trim() || !Number.isFinite(amount) || amount <= 0) {
      showToast("error", i18n.t("entryActions.manualEntryInvalid"));
      return null;
    }
    const value = amount.toFixed(2);
    const negative = (-amount).toFixed(2);
    const narration = manual.narration.trim() || (manual.kind === "expense" ? i18n.t("entryActions.manualExpense") : manual.kind === "income" ? i18n.t("entryActions.manualIncome") : i18n.t("entryActions.manualTransfer"));
    if (manual.kind === "expense") {
      return { kind: "transaction", date: manual.date, payee: manual.payee.trim(), narration, metadata: {}, tags: [], confidence: 1, needsReview: false, questions: [], postings: [
        { account: manual.category, amount: value, currency: "CNY" },
        { account: manual.fromAccount, amount: negative, currency: "CNY" },
      ] };
    }
    if (manual.kind === "income") {
      return { kind: "transaction", date: manual.date, payee: manual.payee.trim(), narration, metadata: {}, tags: [], confidence: 1, needsReview: false, questions: [], postings: [
        { account: manual.toAccount, amount: value, currency: "CNY" },
        { account: manual.category, amount: negative, currency: "CNY" },
      ] };
    }
    return { kind: "transaction", date: manual.date, payee: manual.payee.trim(), narration, metadata: {}, tags: [], confidence: 1, needsReview: false, questions: [], postings: [
      { account: manual.toAccount, amount: value, currency: "CNY" },
      { account: manual.fromAccount, amount: negative, currency: "CNY" },
    ] };
  }

  function previewManualEntry() {
    const entry = buildManualEntry();
    if (!entry) return;
    setPreviews([entry]);
    setParseStatus("success");
    setParseMessage(i18n.t("entryActions.previewReady"));
    haptic(6);
    showToast("success", i18n.t("entryActions.previewGenerated"));
  }

  function removePreview(index: number) {
    setPreviews((current) => {
      const next = current.filter((_, i) => i !== index);
      setParseStatus(next.length ? "success" : "idle");
      setParseMessage(next.length ? i18n.t("entryActions.remainingCount", { count: next.length }) : "");
      return next;
    });
  }

  async function appendPreviews() {
    if (!previews.length || submittingRef.current) return;
    const entries = previews;
    const operationIds = entries.map((entry) => {
      const id = operationIdsRef.current.get(entry) ?? createLedgerOperationId();
      operationIdsRef.current.set(entry, id);
      return id;
    });
    const resetDraft = () => {
      setPreviews([]);
      setNl("");
      setEntryOpen(false);
      setManual((current) => ({ ...current, payee: "", narration: "", amount: "" }));
      setParseStatus("idle");
      setParseMessage("");
    };
    const savePending = async () => {
      if (!await enqueuePendingWrites(entries, operationIds)) throw new Error(i18n.t("pendingWrites.storageFailed"));
      resetDraft();
      showToast("info", i18n.t("entryActions.savedPending", { count: entries.length }));
    };
    submittingRef.current = true;
    setAppendStatus("writing");
    try {
      if (offlineOrNetworkError()) {
        await savePending();
        return;
      }
      setParseMessage(i18n.t("entryActions.writingCount", { count: entries.length }));
      showToast("info", i18n.t("entryActions.writingToast", { count: entries.length }));
      let res: Response;
      try {
        res = await apiFetch("/api/ledger/append-batch", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ entries, operationIds }) }, { kind: "write" });
      } catch (error) {
        if (offlineOrNetworkError(error)) { await savePending(); return; }
        throw error;
      }
      const data = await readJson<{ error?: string; count?: number }>(res);
      if (!res.ok) throw new Error(data.error || i18n.t("entryActions.writeFailed"));
      const count = typeof data.count === "number" ? data.count : entries.length;
      resetDraft();
      haptic([6, 24, 10]);
      showToast("success", i18n.t("entryActions.writtenCount", { count }));
      void load(true);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setPreviews(entries);
      setEntryOpen(true);
      setParseStatus("error");
      setParseMessage(message);
      showToast("error", message || i18n.t("entryActions.writeFailed"));
    } finally {
      submittingRef.current = false;
      setAppendStatus("idle");
    }
  }

  return { nl, setNl, previews, parseStatus, parseMessage, appendStatus, entryOpen, setEntryOpen, manual, setManual, parseNl, previewManualEntry, removePreview, appendPreviews, appendEntry };
}
