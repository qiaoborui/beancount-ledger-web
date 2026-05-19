import { useState } from "react";
import { readJson } from "@/lib/clientFetch";
import type { BalanceAssertion, ParsedTransaction } from "@/lib/schemas";
import { haptic } from "../haptics";
import type { ManualForm } from "../types";

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

export function useEntryActions({ load, refreshGitStatus, showToast, enqueuePendingWrites }: { load: (forceFresh?: boolean) => void | Promise<void>; refreshGitStatus: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void; enqueuePendingWrites: (entries: (ParsedTransaction | BalanceAssertion)[]) => void }) {
  const [nl, setNl] = useState("");
  const [previews, setPreviews] = useState<ParsedTransaction[]>([]);
  const [parseStatus, setParseStatus] = useState<"idle" | "parsing" | "success" | "error">("idle");
  const [parseMessage, setParseMessage] = useState("");
  const [appendStatus, setAppendStatus] = useState<"idle" | "writing">("idle");
  const [entryOpen, setEntryOpen] = useState(false);
  const [manual, setManual] = useState<ManualForm>(() => emptyManual());

  async function appendEntry(entry: ParsedTransaction | BalanceAssertion) {
    const res = await fetch("/api/ledger/append", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(entry) });
    const data = await readJson<{ error?: string }>(res);
    if (!res.ok) {
      showToast("error", data.error || "写入失败");
      return { ok: false };
    }
    return { ok: true };
  }

  async function parseNl() {
    if (!nl.trim()) {
      setParseStatus("error");
      setParseMessage("请输入要解析的消费记录");
      return;
    }
    setParseStatus("parsing");
    setParseMessage("正在解析，请保持弹窗打开…");
    try {
      const res = await fetch("/api/ai/parse", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ input: nl }) });
      const data = await readJson<{ error?: string; entries?: ParsedTransaction[]; entry?: ParsedTransaction }>(res);
      if (!res.ok) throw new Error(data.error || "解析失败");
      const entries = Array.isArray(data.entries) ? data.entries as ParsedTransaction[] : data.entry ? [data.entry as ParsedTransaction] : [];
      if (!entries.length) throw new Error("AI 没有返回可写入的记录");
      setPreviews(entries);
      setParseStatus("success");
      setParseMessage(`已解析 ${entries.length} 条，请确认后写入`);
      haptic(8);
      showToast("success", `解析成功：${entries.length} 条`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setParseStatus("error");
      setParseMessage(message);
      showToast("error", message || "解析失败");
    }
  }

  function buildManualEntry(): ParsedTransaction | null {
    const amount = Number(manual.amount);
    if (!manual.date || !manual.payee.trim() || !Number.isFinite(amount) || amount <= 0) {
      showToast("error", "请填写日期、商户/对方和大于 0 的金额");
      return null;
    }
    const value = amount.toFixed(2);
    const negative = (-amount).toFixed(2);
    const narration = manual.narration.trim() || (manual.kind === "expense" ? "手动支出" : manual.kind === "income" ? "手动收入" : "手动转账");
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
    setParseMessage("已生成 1 条预览，请确认写入");
    haptic(6);
    showToast("success", "已生成预览，请确认写入");
  }

  function removePreview(index: number) {
    setPreviews((current) => {
      const next = current.filter((_, i) => i !== index);
      setParseStatus(next.length ? "success" : "idle");
      setParseMessage(next.length ? `剩余 ${next.length} 条待写入` : "");
      return next;
    });
  }

  async function appendPreviews() {
    if (!previews.length) return;
    const entries = previews;
    const resetDraft = () => {
      setPreviews([]);
      setNl("");
      setEntryOpen(false);
      setManual((current) => ({ ...current, payee: "", narration: "", amount: "" }));
      setParseStatus("idle");
      setParseMessage("");
    };

    if (offlineOrNetworkError()) {
      enqueuePendingWrites(entries);
      resetDraft();
      showToast("info", `已保存 ${entries.length} 条待同步记录`);
      return;
    }

    setAppendStatus("writing");
    setParseMessage(`正在写入 ${entries.length} 条…`);
    resetDraft();
    showToast("info", `正在写入 ${entries.length} 条记录`);
    try {
      const res = await fetch("/api/ledger/append-batch", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ entries }) });
      const data = await readJson<{ error?: string; count?: number }>(res);
      if (!res.ok) throw new Error(data.error || "写入失败");
      const count = typeof data.count === "number" ? data.count : entries.length;
      haptic([6, 24, 10]);
      showToast("success", `已写入 ${count} 条账本记录`);
      load(true);
      refreshGitStatus();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (offlineOrNetworkError(error)) {
        enqueuePendingWrites(entries);
        showToast("info", `网络不稳定，已保存 ${entries.length} 条待同步记录`);
        return;
      }
      setPreviews(entries);
      setEntryOpen(true);
      setParseStatus("error");
      setParseMessage(message);
      showToast("error", message || "写入失败");
    } finally {
      setAppendStatus("idle");
    }
  }

  return { nl, setNl, previews, parseStatus, parseMessage, appendStatus, entryOpen, setEntryOpen, manual, setManual, parseNl, previewManualEntry, removePreview, appendPreviews, appendEntry };
}
