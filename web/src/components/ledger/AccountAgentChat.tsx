"use client";

import { useState } from "react";
import { Ban, Check, Pencil, Plus, Trash2 } from "lucide-react";
import { readAiEventStream } from "@/lib/aiStream";
import { readJson } from "@/lib/clientFetch";
import type { AccountOperation } from "./types";
import { LedgerAiChatShell, type LedgerAiChatMessage } from "./LedgerAiChatShell";
import { LedgerAiPlanCard, type LedgerAiPlan } from "./LedgerAiPlanCard";

type ChatMessage = LedgerAiChatMessage;

type ChatStatus = "idle" | "thinking" | "writing" | "error";

function nextId() {
  return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

export function AccountAgentChat({ open, onClose, onChanged, refreshGitStatus, showToast }: { open: boolean; onClose: () => void; onChanged: () => void | Promise<void>; refreshGitStatus: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void }) {
  const [input, setInput] = useState("");
  const [status, setStatus] = useState<ChatStatus>("idle");
  const [messages, setMessages] = useState<ChatMessage[]>(() => [
    { id: nextId(), role: "assistant", text: "我是账户管理助理。你可以告诉我想创建、调整显示名/分组，或禁用哪些账户；我会先生成草稿。" },
  ]);
  const [operations, setOperations] = useState<AccountOperation[]>([]);
  const [plan, setPlan] = useState<LedgerAiPlan>(null);

  const busy = status === "thinking" || status === "writing";
  const statusText = status === "thinking" ? "AI 正在整理账户草稿…" : status === "writing" ? "正在写入账户定义…" : status === "error" ? "刚才处理失败，可以调整后再发" : operations.length ? `${operations.length} 个操作待确认` : "确认后才会写入 accounts.bean";
  const historyForApi = messages.map(({ role, text }) => ({ role, text }));

  function pushMessage(role: ChatMessage["role"], text: string) {
    setMessages((current) => [...current, { id: nextId(), role, text }]);
  }

  function updateMessage(id: string, text: string) {
    setMessages((current) => current.map((message) => message.id === id ? { ...message, text } : message));
  }

  function resetChat() {
    if (busy) return;
    const hasWork = messages.length > 1 || operations.length > 0 || input.trim();
    if (hasWork && !window.confirm("清空本次账户 AI 对话和待确认草稿？")) return;
    setInput("");
    setOperations([]);
    setPlan(null);
    setStatus("idle");
    setMessages([{ id: nextId(), role: "assistant", text: "我是账户管理助理。你可以告诉我想创建、调整显示名/分组，或禁用哪些账户；我会先生成草稿。" }]);
  }

  async function handleSubmit(text: string) {
    if (!text || busy) return;
    const assistantId = nextId();
    setMessages((current) => [...current, { id: nextId(), role: "user", text }, { id: assistantId, role: "assistant", text: "" }]);
    setStatus("thinking");
    try {
      const res = await fetch("/api/ai/accounts-chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message: text, messages: historyForApi, draftOperations: operations, stream: true }) });
      const data = await readAiEventStream<{ operations?: AccountOperation[]; message?: string; plan?: LedgerAiPlan }>(res, (message) => updateMessage(assistantId, message));
      const nextOperations = Array.isArray(data.operations) ? data.operations : [];
      setOperations(nextOperations);
      setPlan(data.plan ?? null);
      updateMessage(assistantId, typeof data.message === "string" && data.message.trim() ? data.message : nextOperations.length ? `已更新 ${nextOperations.length} 个账户操作草稿。` : "我需要更多信息后再生成草稿。");
      setStatus("idle");
      showToast("success", nextOperations.length ? `AI 已生成 ${nextOperations.length} 个账户操作` : "AI 已回答");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      updateMessage(assistantId, `处理失败：${message}`);
      setStatus("error");
      showToast("error", message || "账户草稿生成失败");
      throw error;
    }
  }

  function removeOperation(index: number) {
    setOperations((current) => current.filter((_, itemIndex) => itemIndex !== index));
  }

  async function applyOperations() {
    if (!operations.length || busy) return;
    setStatus("writing");
    try {
      const res = await fetch("/api/ledger/accounts/operations", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ operations }) });
      const data = await readJson<{ error?: string; count?: number }>(res);
      if (!res.ok) throw new Error(data.error || "账户写入失败");
      const count = typeof data.count === "number" ? data.count : operations.length;
      setOperations([]);
      setPlan(null);
      pushMessage("assistant", `已写入 ${count} 个账户操作。你可以继续整理下一组。`);
      setStatus("idle");
      showToast("success", `已写入 ${count} 个账户操作`);
      await onChanged();
      await refreshGitStatus();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      pushMessage("assistant", `写入失败：${message}`);
      setStatus("error");
      showToast("error", message || "账户写入失败");
    }
  }

  return (
    <LedgerAiChatShell
      open={open}
      title="账户 AI"
      statusText={statusText}
      messages={messages}
      input={input}
      placeholder={"例如：\n新增一个差旅支出分类叫差旅\n把 Income:Other 改名为其他收入\n今天关闭旧的微信零钱账户"}
      note="AI 只生成草稿，不会自动写入。"
      busy={busy}
      inputDisabled={status === "writing"}
      thinkingText={status === "thinking" ? "AI 正在整理…" : undefined}
      widthClassName="md:w-[440px]"
      onInputChange={setInput}
      onSubmit={handleSubmit}
      onReset={resetChat}
      onClose={onClose}
    >
      <LedgerAiPlanCard plan={plan} />
      {operations.length > 0 && (
        <div className="space-y-3 rounded-2xl border border-line bg-panel p-3">
          <div className="flex items-center justify-between gap-3">
            <div>
              <div className="font-medium text-warm">账户操作草稿</div>
              <div className="text-xs text-stone">可移除单项，确认后写入 accounts.bean。</div>
            </div>
            <button type="button" className="shrink-0 rounded-xl bg-brand px-3 py-2 text-sm text-paper disabled:opacity-60" onClick={applyOperations} disabled={busy}>{status === "writing" ? "写入中…" : `确认 ${operations.length} 个`}</button>
          </div>
          <div className="space-y-2">
            {operations.map((operation, index) => <OperationCard key={`${operation.kind}-${operation.account}-${index}`} operation={operation} busy={busy} onRemove={() => removeOperation(index)} />)}
          </div>
        </div>
      )}
    </LedgerAiChatShell>
  );
}

function OperationCard({ operation, busy, onRemove }: { operation: AccountOperation; busy: boolean; onRemove: () => void }) {
  const icon = operation.kind === "create" ? <Plus className="h-3.5 w-3.5" /> : operation.kind === "update" ? <Pencil className="h-3.5 w-3.5" /> : <Ban className="h-3.5 w-3.5" />;
  const title = operation.kind === "create" ? "创建账户" : operation.kind === "update" ? "更新账户" : "禁用账户";
  return (
    <div className="rounded-2xl border border-line bg-paper p-3 shadow-sm">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2 font-medium text-warm"><span className="grid h-6 w-6 place-items-center rounded-xl bg-tag text-brand">{icon}</span>{title}</div>
          <div className="mt-1 truncate text-sm text-olive">{operation.account}</div>
          <div className="mt-0.5 text-xs text-stone">{operation.date}{operation.alias ? ` · ${operation.alias}` : ""}{operation.group ? ` · ${operation.group}` : ""}</div>
        </div>
        <button type="button" className="shrink-0 rounded-lg border border-line p-1.5 text-stone hover:text-[var(--danger)] disabled:opacity-50" onClick={onRemove} disabled={busy} aria-label="移除这个账户操作">
          <Trash2 className="h-3.5 w-3.5" />
        </button>
      </div>
      {operation.kind !== "disable" && <div className="mt-2 inline-flex items-center gap-1 rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone"><Check className="h-3 w-3" />{operation.kind === "create" ? "open CNY" : "metadata"}</div>}
    </div>
  );
}
