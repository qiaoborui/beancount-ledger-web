"use client";

import { useEffect, useState } from "react";
import { Trash2 } from "lucide-react";
import { readAiEventStream, type AiToolEvent } from "@/lib/aiStream";
import { readJson } from "@/lib/clientFetch";
import type { ParsedTransaction } from "@/lib/schemas";
import { LedgerAiChatShell, type LedgerAiChatMessage } from "./LedgerAiChatShell";
import { LedgerAiConfirmationCard } from "./LedgerAiConfirmationCard";
import { LedgerAiPlanCard, type LedgerAiPlan } from "./LedgerAiPlanCard";
import { LedgerAiSourcesCard, type LedgerAiSource } from "./LedgerAiSourcesCard";
import { LedgerAiToolCard, type LedgerAiTool, upsertLedgerAiTool } from "./LedgerAiToolCard";

type ChatMessage = LedgerAiChatMessage;

type ChatStatus = "idle" | "thinking" | "writing" | "error";

const bookkeepingSuggestions = [
  "今天午餐 35 支付宝",
  "昨天打车 25 微信",
  "把上一条改成招行信用卡",
  "这几笔都用 Expenses:Food",
];

const bookkeepingDraftTools: LedgerAiTool[] = [
  { id: "parse-ledger", name: "parseLedger", title: "解析流水", status: "pending" },
  { id: "validate-beancount", name: "validateBeancount", title: "校验 Beancount", status: "pending" },
];

const writeLedgerTool: LedgerAiTool = { id: "write-ledger", name: "writeLedger", title: "写入 ledger", status: "pending" };

function nextId() {
  return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

function PreviewCard({ entry, index, busy, onRemove }: { entry: ParsedTransaction; index: number; busy: boolean; onRemove: () => void }) {
  return (
    <div className="rounded-2xl border border-line bg-paper p-3 shadow-sm">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="truncate font-medium text-warm">{index + 1}. {entry.date} {entry.payee}</div>
          <div className="mt-0.5 text-xs text-stone">{entry.narration || "无说明"} · 置信度 {Math.round(entry.confidence * 100)}%</div>
        </div>
        <button type="button" className="shrink-0 rounded-lg border border-line p-1.5 text-stone hover:text-[var(--danger)] disabled:opacity-50" onClick={onRemove} disabled={busy} aria-label="移除这条预览">
          <Trash2 className="h-3.5 w-3.5" />
        </button>
      </div>
      {entry.needsReview && <div className="mt-2 rounded-xl border border-line bg-tag px-2 py-1.5 text-xs text-warm">需要确认{entry.questions.length ? `：${entry.questions.join("；")}` : ""}</div>}
      {(Object.keys(entry.metadata ?? {}).length > 0 || (entry.tags ?? []).length > 0) && <div className="mt-2 flex flex-wrap gap-1">{Object.entries(entry.metadata ?? {}).map(([key, value]) => <span key={key} className="rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone">{key}: {String(value)}</span>)}{(entry.tags ?? []).map((tag) => <span key={tag} className="rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone">#{tag}</span>)}</div>}
      <div className="mt-2 space-y-1">
        {entry.postings.map((posting, postingIndex) => (
          <div key={postingIndex} className="flex justify-between gap-3 text-xs">
            <span className="min-w-0 truncate text-stone">{posting.account}</span>
            <span className="shrink-0 font-medium text-warm">{posting.amount} {posting.currency}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

export function AiBookkeepingChat({ load, showToast, openSignal = 0 }: { load: (forceFresh?: boolean) => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void; openSignal?: number }) {
  const [open, setOpen] = useState(false);
  const [input, setInput] = useState("");
  const [status, setStatus] = useState<ChatStatus>("idle");
  const [messages, setMessages] = useState<ChatMessage[]>(() => [
    { id: nextId(), role: "assistant", text: "我是你的 AI 记账助理。可以直接发多笔流水，我会先生成预览，不会自动写入。" },
  ]);
  const [previews, setPreviews] = useState<ParsedTransaction[]>([]);
  const [plan, setPlan] = useState<LedgerAiPlan>(null);
  const [sources, setSources] = useState<LedgerAiSource[]>([]);
  const [tools, setTools] = useState<LedgerAiTool[]>([]);
  const [streamingStatus, setStreamingStatus] = useState("");

  useEffect(() => {
    if (openSignal > 0) setOpen(true);
  }, [openSignal]);

  const busy = status === "thinking" || status === "writing";
  const statusText = status === "thinking" ? "AI 正在理解这笔账…" : status === "writing" ? "正在写入账本…" : status === "error" ? "刚才处理失败，可以改一下再发" : previews.length ? `${previews.length} 条待确认` : "预览确认后才会写入";
  const historyForApi = messages.filter((message) => message.role === "user" || message.role === "assistant").map(({ role, text }) => ({ role: role as "user" | "assistant", text }));

  function resetChat() {
    if (busy) return;
    setInput("");
    setPreviews([]);
    setPlan(null);
    setSources([]);
    setTools([]);
    setStreamingStatus("");
    setStatus("idle");
    setMessages([{ id: nextId(), role: "assistant", text: "我是你的 AI 记账助理。可以直接发多笔流水，我会先生成预览，不会自动写入。" }]);
  }

  function pushMessage(role: ChatMessage["role"], text: string) {
    setMessages((current) => [...current, { id: nextId(), role, text }]);
  }

  function updateMessage(id: string, text: string) {
    setMessages((current) => current.map((message) => message.id === id ? { ...message, text } : message));
  }

  async function handleSubmit(text: string) {
    if (!text || busy) return;

    const assistantId = nextId();
    setMessages((current) => [...current, { id: nextId(), role: "user", text }, { id: assistantId, role: "assistant", text: "" }]);
    setStatus("thinking");
    setPlan(null);
    setTools(bookkeepingDraftTools);
    setStreamingStatus("读取当前记账草稿");
    try {
      const res = await fetch("/api/ai/chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message: text, messages: historyForApi, draftEntries: previews, stream: true }) });
      const data = await readAiEventStream<{ entries?: ParsedTransaction[]; message?: string; plan?: LedgerAiPlan; sources?: LedgerAiSource[] }>(res, {
        onMessage: (message) => updateMessage(assistantId, message),
        onStatus: setStreamingStatus,
        onTool: (tool: AiToolEvent) => setTools((current) => upsertLedgerAiTool(current, tool)),
      });
      const entries = Array.isArray(data.entries) ? data.entries as ParsedTransaction[] : [];
      const hadPreviews = previews.length > 0;
      setPreviews(entries);
      setPlan(data.plan ?? null);
      setSources(Array.isArray(data.sources) ? data.sources : []);
      setTools((current) => entries.length ? upsertLedgerAiTool(current, writeLedgerTool) : current);
      setStreamingStatus("");
      updateMessage(assistantId, typeof data.message === "string" && data.message.trim() ? data.message : entries.length ? `已更新 ${entries.length} 条预览。` : hadPreviews ? "已清空预览。" : "已回答。");
      setStatus("idle");
      showToast("success", entries.length ? `AI 已生成 ${entries.length} 条预览` : hadPreviews ? "AI 已清空预览" : "AI 已回答");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setStreamingStatus("");
      updateMessage(assistantId, `解析失败：${message}`);
      setStatus("error");
      showToast("error", message || "解析失败");
      throw error;
    }
  }

  function removePreview(index: number) {
    setPreviews((current) => {
      const next = current.filter((_, itemIndex) => itemIndex !== index);
      if (next.length === 0) setTools((tools) => tools.filter((tool) => tool.id !== "write-ledger"));
      return next;
    });
  }

  function cancelPreviews() {
    if (busy || !previews.length) return;
    setPreviews([]);
    setPlan(null);
    setSources([]);
    setTools([]);
    pushMessage("assistant", "已清空待确认预览。可以继续发新的流水。");
  }

  async function appendPreviews() {
    if (!previews.length || busy) return;
    setStatus("writing");
    setTools((current) => upsertLedgerAiTool(current, { ...writeLedgerTool, status: "running", input: { entries: previews.length } }));
    try {
      const entriesToWrite = previews;
      const res = await fetch("/api/ledger/append-batch", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ entries: entriesToWrite }) });
      const data = await readJson<{ error?: string; count?: number }>(res);
      if (!res.ok) throw new Error(data.error || "写入失败");
      const count = typeof data.count === "number" ? data.count : entriesToWrite.length;
      setPreviews([]);
      setPlan(null);
      setSources([]);
      setTools((current) => upsertLedgerAiTool(current, { ...writeLedgerTool, status: "completed", output: { entries: count } }));
      setStreamingStatus("");
      pushMessage("assistant", `已写入 ${count} 条账本记录。你可以继续发下一笔。`);
      setStatus("idle");
      showToast("success", `已写入 ${count} 条账本记录`);
      await load(true);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setTools((current) => upsertLedgerAiTool(current, { ...writeLedgerTool, status: "error", error: message }));
      pushMessage("assistant", `写入失败：${message}`);
      setStatus("error");
      showToast("error", message || "写入失败");
    }
  }

  return (
    <LedgerAiChatShell
      open={open}
      title="AI 记账"
      statusText={streamingStatus || statusText}
      messages={messages}
      input={input}
      placeholder={"例如：\n今天星巴克 38 支付宝\n昨天打车 25 微信\n按 Enter 发送，Shift+Enter 换行"}
      note="AI 只生成预览，不会自动写入。"
      busy={busy}
      inputDisabled={status === "writing"}
      thinkingText={status === "thinking" ? streamingStatus || "AI 正在解析…" : undefined}
      suggestions={bookkeepingSuggestions}
      onInputChange={setInput}
      onSubmit={handleSubmit}
      onReset={resetChat}
      resetRequiresConfirmation={messages.length > 1 || previews.length > 0 || Boolean(input.trim())}
      resetConfirmDescription="本次 AI 对话、待确认预览和当前输入都会被清空。"
      onClose={() => setOpen(false)}
    >
      <LedgerAiPlanCard plan={plan} streamingStatus={status === "thinking" ? streamingStatus : undefined} />
      <LedgerAiToolCard tools={tools} />
      <LedgerAiSourcesCard sources={sources} />
      {previews.length > 0 && (
        <div className="space-y-3">
          <div className="flex items-center justify-between gap-3">
            <div>
              <div className="font-medium text-warm">待确认预览</div>
              <div className="text-xs text-stone">可移除不需要的条目，确认后批量写入。</div>
            </div>
          </div>
          <LedgerAiConfirmationCard
            id="bookkeeping-write"
            acceptedText="已批准，正在写入账本。"
            busy={status === "writing"}
            confirmLabel={status === "writing" ? "写入中…" : `确认写入 ${previews.length} 条`}
            description="AI 只提交待确认预览；写入前仍可删除单条。"
            title="AI 请求写入账本"
            onCancel={cancelPreviews}
            onConfirm={appendPreviews}
          />
          <div className="space-y-2">
            {previews.map((entry, index) => <PreviewCard key={`${entry.date}-${entry.payee}-${index}`} entry={entry} index={index} busy={busy} onRemove={() => removePreview(index)} />)}
          </div>
        </div>
      )}
    </LedgerAiChatShell>
  );
}
