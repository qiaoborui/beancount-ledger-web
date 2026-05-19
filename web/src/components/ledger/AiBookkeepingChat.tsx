"use client";

import { useEffect, useRef, useState, type CSSProperties, type FormEvent, type KeyboardEvent } from "react";
import { Bot, Send, Trash2, X } from "lucide-react";
import { readJson } from "@/lib/clientFetch";
import type { ParsedTransaction } from "@/lib/schemas";

type ChatMessage = {
  id: string;
  role: "user" | "assistant" | "system";
  text: string;
};

type ChatStatus = "idle" | "thinking" | "writing" | "error";

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

export function AiBookkeepingChat({ load, refreshGitStatus, showToast, openSignal = 0 }: { load: (forceFresh?: boolean) => void | Promise<void>; refreshGitStatus: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void; openSignal?: number }) {
  const [open, setOpen] = useState(false);
  const [input, setInput] = useState("");
  const [status, setStatus] = useState<ChatStatus>("idle");
  const [messages, setMessages] = useState<ChatMessage[]>(() => [
    { id: nextId(), role: "assistant", text: "我是你的 AI 记账助理。可以直接发多笔流水，我会先生成预览，不会自动写入。" },
  ]);
  const [previews, setPreviews] = useState<ParsedTransaction[]>([]);
  const [keyboardHeight, setKeyboardHeight] = useState(0);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);

  useEffect(() => {
    if (openSignal > 0) setOpen(true);
  }, [openSignal]);

  useEffect(() => {
    if (!open) { setKeyboardHeight(0); return; }
    const vv = window.visualViewport;
    if (!vv) return;
    const update = () => {
      const kbH = Math.max(0, window.innerHeight - vv.height - (vv.offsetTop || 0));
      setKeyboardHeight(kbH > 50 ? kbH : 0);
    };
    vv.addEventListener("resize", update);
    vv.addEventListener("scroll", update);
    update();
    return () => { vv.removeEventListener("resize", update); vv.removeEventListener("scroll", update); };
  }, [open]);

  const busy = status === "thinking" || status === "writing";
  const statusText = status === "thinking" ? "AI 正在理解这笔账…" : status === "writing" ? "正在写入账本…" : status === "error" ? "刚才处理失败，可以改一下再发" : previews.length ? `${previews.length} 条待确认` : "预览确认后才会写入";
  const historyForApi = messages.filter((message) => message.role === "user" || message.role === "assistant").map(({ role, text }) => ({ role: role as "user" | "assistant", text }));

  function resetChat() {
    if (busy) return;
    const hasWork = messages.length > 1 || previews.length > 0 || input.trim();
    if (hasWork && !window.confirm("清空本次 AI 对话和待确认预览？")) return;
    setInput("");
    setPreviews([]);
    setStatus("idle");
    setMessages([{ id: nextId(), role: "assistant", text: "我是你的 AI 记账助理。可以直接发多笔流水，我会先生成预览，不会自动写入。" }]);
    textareaRef.current?.focus();
  }

  function pushMessage(role: ChatMessage["role"], text: string) {
    setMessages((current) => [...current, { id: nextId(), role, text }]);
  }

  async function handleSubmit(event?: FormEvent) {
    event?.preventDefault();
    const text = input.trim();
    if (!text || busy) return;

    setInput("");
    pushMessage("user", text);
    setStatus("thinking");
    try {
      const res = await fetch("/api/ai/chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message: text, messages: historyForApi, draftEntries: previews }) });
      const data = await readJson<{ error?: string; entries?: ParsedTransaction[]; message?: string }>(res);
      if (!res.ok) throw new Error(data.error || "解析失败");
      const entries = Array.isArray(data.entries) ? data.entries as ParsedTransaction[] : [];
      const hadPreviews = previews.length > 0;
      setPreviews(entries);
      pushMessage("assistant", typeof data.message === "string" && data.message.trim() ? data.message : entries.length ? `已更新 ${entries.length} 条预览。` : hadPreviews ? "已清空预览。" : "已回答。");
      setStatus("idle");
      showToast("success", entries.length ? `AI 已生成 ${entries.length} 条预览` : hadPreviews ? "AI 已清空预览" : "AI 已回答");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      pushMessage("assistant", `解析失败：${message}`);
      setStatus("error");
      showToast("error", message || "解析失败");
    } finally {
      textareaRef.current?.focus();
    }
  }

  function handleKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      void handleSubmit();
    }
  }

  function removePreview(index: number) {
    setPreviews((current) => current.filter((_, itemIndex) => itemIndex !== index));
  }

  async function appendPreviews() {
    if (!previews.length || busy) return;
    setStatus("writing");
    try {
      const entriesToWrite = previews;
      const res = await fetch("/api/ledger/append-batch", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ entries: entriesToWrite }) });
      const data = await readJson<{ error?: string; count?: number }>(res);
      if (!res.ok) throw new Error(data.error || "写入失败");
      const count = typeof data.count === "number" ? data.count : entriesToWrite.length;
      setPreviews([]);
      pushMessage("assistant", `已写入 ${count} 条账本记录。你可以继续发下一笔。`);
      setStatus("idle");
      showToast("success", `已写入 ${count} 条账本记录`);
      await load(true);
      await refreshGitStatus();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      pushMessage("assistant", `写入失败：${message}`);
      setStatus("error");
      showToast("error", message || "写入失败");
    }
  }

  return (
    <>
      {open && (
        <div
          className="kami-float fixed inset-x-0 top-0 bottom-[var(--ai-chat-bottom)] z-50 flex w-full flex-col overflow-hidden bg-paper md:inset-x-auto md:right-6 md:top-auto md:bottom-[calc(7rem+env(safe-area-inset-bottom))] md:h-[min(78dvh,680px)] md:w-[420px] md:max-w-md md:rounded-3xl md:border md:border-line"
          style={{ "--ai-chat-bottom": `${keyboardHeight}px` } as CSSProperties}
        >
          <div className="flex shrink-0 items-center justify-between border-b border-line bg-panel px-4 pb-3 pt-[calc(env(safe-area-inset-top)+0.75rem)] md:py-3">
            <div className="flex items-center gap-2">
              <div className="grid h-9 w-9 place-items-center rounded-2xl bg-brand text-paper"><Bot className="h-4 w-4" /></div>
              <div>
                <div className="font-serif text-lg text-warm">AI 记账</div>
                <div className="text-xs text-stone">{statusText}</div>
              </div>
            </div>
            <div className="flex items-center gap-2">
              <button type="button" className="rounded-xl border border-line p-2 text-stone hover:text-[var(--danger)] disabled:opacity-50" onClick={resetChat} disabled={busy} aria-label="清空 AI 对话和预览" title="清空对话">
                <Trash2 className="h-4 w-4" />
              </button>
              <button type="button" className="rounded-xl border border-line p-2 text-stone hover:text-warm" onClick={() => setOpen(false)} aria-label="关闭 AI 记账">
                <X className="h-4 w-4" />
              </button>
            </div>
          </div>

          <div className="flex-1 space-y-3 overflow-y-auto p-4">
            {messages.map((message) => (
              <div key={message.id} className={`flex ${message.role === "user" ? "justify-end" : "justify-start"}`}>
                <div className={`max-w-[86%] whitespace-pre-wrap rounded-2xl px-3 py-2 text-sm leading-relaxed ${message.role === "user" ? "bg-brand text-paper" : "border border-line bg-panel text-warm"}`}>{message.text}</div>
              </div>
            ))}
            {busy && status === "thinking" && <div className="text-sm text-stone">AI 正在解析…</div>}

            {previews.length > 0 && (
              <div className="space-y-3 rounded-2xl border border-line bg-panel p-3">
                <div className="flex items-center justify-between gap-3">
                  <div>
                    <div className="font-medium text-warm">待确认预览</div>
                    <div className="text-xs text-stone">可移除不需要的条目，确认后批量写入。</div>
                  </div>
                  <button type="button" className="shrink-0 rounded-xl bg-brand px-3 py-2 text-sm text-paper disabled:opacity-60" onClick={appendPreviews} disabled={busy}>{status === "writing" ? "写入中…" : `确认写入 ${previews.length} 条`}</button>
                </div>
                <div className="space-y-2">
                  {previews.map((entry, index) => <PreviewCard key={`${entry.date}-${entry.payee}-${index}`} entry={entry} index={index} busy={busy} onRemove={() => removePreview(index)} />)}
                </div>
              </div>
            )}
          </div>

          <form className="shrink-0 border-t border-line bg-paper px-4 pb-[calc(env(safe-area-inset-bottom)+0.75rem)] pt-3 md:p-3" onSubmit={handleSubmit}>
            <textarea ref={textareaRef} className="h-24 w-full resize-none rounded-2xl border border-line bg-panel p-3 text-sm outline-none focus:border-brand" placeholder={"例如：\n今天星巴克 38 支付宝\n昨天打车 25 微信\n按 Enter 发送，Shift+Enter 换行"} value={input} onChange={(event) => setInput(event.target.value)} onKeyDown={handleKeyDown} disabled={status === "writing"} />
            <div className="mt-2 flex items-center justify-between gap-3">
              <div className="text-xs text-stone">AI 只生成预览，不会自动写入。</div>
              <button type="submit" className="inline-flex items-center gap-2 rounded-xl bg-brand px-4 py-2 text-sm text-paper disabled:opacity-60" disabled={!input.trim() || busy}>
                <Send className="h-3.5 w-3.5" />发送
              </button>
            </div>
          </form>
        </div>
      )}

    </>
  );
}
