"use client";

import { createPortal } from "react-dom";
import { useEffect, useMemo, useRef, useState, type RefObject } from "react";
import { Ban, Bot, Check, ChevronDown, ChevronUp, Database, ExternalLink, LoaderCircle, Maximize2, Minimize2, Play, Plus, Send, ShieldCheck, X } from "lucide-react";
import { Bar, BarChart, CartesianGrid, Cell, Line, LineChart, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { apiEndpointLedgerScope, apiFetch } from "@/lib/apiEndpoints";
import { readLedgerAgentStream, type AgentApproval, type AgentArtifact, type AgentFinal, type AgentToolEvent } from "@/lib/ledgerAgentStream";
import { MessageResponse } from "@/components/ai-elements/message";
import type { ParsedTransaction } from "@/lib/schemas";
import type { AccountOperation } from "./types";

type AgentApprovalPolicy = "on-write" | "always";

type AgentContext = {
  page: string;
  path: string;
  start: string;
  end: string;
  valuationCurrency: string;
  bqlQuery?: string;
};

export type LedgerAgentRequest = {
  id: number;
  prompt?: string;
  autoSubmit?: boolean;
};

type MessageItem = { kind: "message"; id: string; role: "user" | "assistant"; content: string };
type ToolItem = { kind: "tool"; id: string; tool: AgentToolEvent };
type ArtifactItem = { kind: "artifact"; id: string; artifact: AgentArtifact };
type ApprovalItem = { kind: "approval"; id: string; approval: AgentApproval; resolved?: boolean };
type TimelineItem = MessageItem | ToolItem | ArtifactItem | ApprovalItem;
type AgentSession = { id: string; serverSessionId: string; createdAt: number; updatedAt: number; timeline: TimelineItem[] };
const MAX_STORED_TIMELINE_ITEMS = 80;
const MAX_STORED_SESSIONS = 30;

type BQLColumn = { name: string; type: string };
type BQLResult = { columns: BQLColumn[]; rows: unknown[][]; query: string; warnings?: string[]; valuationCurrency: string; rowCount: number };

const suggestions = [
  "查一下本月餐饮支出并画柱状图",
  "生成最近 12 个月支出趋势的 BQL",
  "搜索今年金额较大的异常流水",
  "帮我记一笔今天午餐 35 元，支付宝支付",
];

const chartColors = ["var(--chart-palette-1, var(--chart-primary))", "var(--chart-palette-2, var(--stone))", "var(--chart-palette-3, var(--brand))", "var(--chart-palette-4, var(--warm))"];

function nextID() {
  return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

function createAgentSession(timeline: TimelineItem[] = [], serverSessionId = ""): AgentSession {
  const now = Date.now();
  return { id: nextID(), serverSessionId, createdAt: now, updatedAt: now, timeline };
}

function sessionLabel(session: AgentSession) {
  const firstPrompt = session.timeline.find((item): item is MessageItem => item.kind === "message" && item.role === "user");
  return firstPrompt?.content.trim() || "新对话";
}

function sessionTime(session: AgentSession) {
  return new Intl.DateTimeFormat("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(session.updatedAt);
}

export function LedgerAgentWorkspace({
  request,
  open: controlledOpen,
  onOpenChange,
  context,
  onApplyBQL,
  onNavigate,
  onChanged,
  showToast,
}: {
  request?: LedgerAgentRequest | null;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  context: AgentContext;
  onApplyBQL: (query: string) => void;
  onNavigate: (path: string) => void;
  onChanged: () => void | Promise<void>;
  showToast: (kind: "info" | "success" | "error", text: string) => void;
}) {
  const stored = useMemo(() => readStoredAgent(), []);
  const [uncontrolledOpen, setUncontrolledOpen] = useState(false);
  const [approvalPolicy, setApprovalPolicy] = useState<AgentApprovalPolicy>(stored.approvalPolicy);
  const [sessions, setSessions] = useState<AgentSession[]>(stored.sessions);
  const [activeSessionId, setActiveSessionId] = useState(stored.activeSessionId);
  const [desktopFullscreen, setDesktopFullscreen] = useState(false);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState("就绪");
  const [streamingText, setStreamingText] = useState("");
  const [expandedTools, setExpandedTools] = useState<Record<string, boolean>>({});
  const requestRef = useRef(0);
  const sendRef = useRef<(text: string) => Promise<void>>(async () => undefined);
  const desktopScrollRef = useRef<HTMLDivElement | null>(null);
  const fullscreenScrollRef = useRef<HTMLDivElement | null>(null);
  const mobileScrollRef = useRef<HTMLDivElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const open = controlledOpen ?? uncontrolledOpen;
  const activeSession = sessions.find((session) => session.id === activeSessionId) ?? sessions[0];
  const sessionId = activeSession.serverSessionId;
  const timeline = activeSession.timeline;

  function setOpen(next: boolean) {
    setUncontrolledOpen(next);
    onOpenChange?.(next);
  }

  function updateActiveSession(update: (session: AgentSession) => AgentSession) {
    setSessions((current) => current.map((session) => session.id === activeSession.id ? update(session) : session));
  }

  function updateTimeline(update: (timeline: TimelineItem[]) => TimelineItem[]) {
    updateActiveSession((session) => ({ ...session, timeline: update(session.timeline).slice(-MAX_STORED_TIMELINE_ITEMS), updatedAt: Date.now() }));
  }

  function createSession() {
    if (busy) return;
    const session = createAgentSession();
    setSessions((current) => [session, ...current].slice(0, MAX_STORED_SESSIONS));
    setActiveSessionId(session.id);
    setInput("");
    setStreamingText("");
    setStatus("就绪");
    requestAnimationFrame(() => textareaRef.current?.focus());
  }

  function selectSession(sessionId: string) {
    if (busy || sessionId === activeSession.id) return;
    setActiveSessionId(sessionId);
    setInput("");
    setStreamingText("");
    setStatus("就绪");
  }

  useEffect(() => {
    writeStoredAgent({ approvalPolicy, activeSessionId, sessions });
  }, [activeSessionId, approvalPolicy, sessions]);

  useEffect(() => {
    if (!request || request.id === requestRef.current) return;
    requestRef.current = request.id;
    setOpen(true);
    const prompt = request.prompt?.trim() ?? "";
    if (!prompt) {
      requestAnimationFrame(() => textareaRef.current?.focus());
      return;
    }
    if (request.autoSubmit) {
      window.setTimeout(() => void sendRef.current(prompt), 0);
    } else {
      setInput(prompt);
      requestAnimationFrame(() => textareaRef.current?.focus());
    }
  }, [request]);

  useEffect(() => {
    if (!open) return;
    requestAnimationFrame(() => {
      const scrollRef = window.matchMedia("(min-width: 768px)").matches ? (desktopFullscreen ? fullscreenScrollRef : desktopScrollRef) : mobileScrollRef;
      scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight });
    });
  }, [desktopFullscreen, open, timeline, streamingText, status]);

  useEffect(() => {
    if (!open || (!desktopFullscreen && window.matchMedia("(min-width: 768px)").matches)) return;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = previousOverflow;
    };
  }, [desktopFullscreen, open]);

  useEffect(() => {
    if (!open) setDesktopFullscreen(false);
  }, [open]);

  const conversation = timeline.filter((item): item is MessageItem => item.kind === "message");
  const hasConversation = conversation.some((message) => message.role === "user");

  async function sendMessage(text: string) {
    const prompt = text.trim();
    if (!prompt || busy) return;
    const history = timeline.filter((item): item is MessageItem => item.kind === "message").map((message) => ({ role: message.role, content: message.content }));
    setOpen(true);
    setBusy(true);
    setInput("");
    setStreamingText("");
    setStatus("正在连接 Agent");
    updateTimeline((current) => [...current, { kind: "message", id: nextID(), role: "user", content: prompt }]);
    try {
      const response = await apiFetch("/api/ai/agent/turn", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sessionId, message: prompt, messages: history, context, approvalPolicy }),
      }, { kind: "write" });
      const final = await consumeStream(response);
      finishTurn(final);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Agent 请求失败";
      updateTimeline((current) => [...current, { kind: "message", id: nextID(), role: "assistant", content: `处理失败：${message}` }]);
      setStatus("处理失败");
      showToast("error", message);
    } finally {
      setBusy(false);
      setStreamingText("");
    }
  }

  sendRef.current = sendMessage;

  async function consumeStream(response: Response) {
    return readLedgerAgentStream(response, {
      onMessageDelta: setStreamingText,
      onStatus: setStatus,
      onTool: upsertTool,
      onArtifact: (artifact) => updateTimeline((current) => [...current, { kind: "artifact", id: artifact.id, artifact }]),
      onApproval: (approval) => updateTimeline((current) => [...current, { kind: "approval", id: approval.id, approval }]),
    });
  }

  function finishTurn(final: AgentFinal) {
    updateActiveSession((session) => ({ ...session, serverSessionId: final.sessionId, updatedAt: Date.now() }));
    setStatus(final.pendingApprovalId ? "等待确认" : "就绪");
    if (final.message.trim()) {
      updateTimeline((current) => [...current, { kind: "message", id: nextID(), role: "assistant", content: final.message.trim() }]);
    }
    if (final.refreshLedger) {
      showToast("success", "账本已更新");
      void onChanged();
    }
  }

  function upsertTool(tool: AgentToolEvent) {
    updateTimeline((current) => {
      const index = current.findIndex((item) => item.kind === "tool" && item.tool.id === tool.id);
      if (index < 0) return [...current, { kind: "tool", id: tool.id, tool }];
      return current.map((item, itemIndex) => itemIndex === index && item.kind === "tool" ? { ...item, tool: { ...item.tool, ...tool } } : item);
    });
  }

  async function resolveApproval(approval: AgentApproval, approved: boolean) {
    if (busy) return;
    setBusy(true);
    setStatus(approved ? "正在执行已确认操作" : "正在取消操作");
    updateTimeline((current) => current.map((item) => item.kind === "approval" && item.approval.id === approval.id ? { ...item, resolved: true } : item));
    try {
      const response = await apiFetch("/api/ai/agent/approval", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sessionId: approval.sessionId, approvalId: approval.id, approved }),
      }, { kind: "write" });
      const final = await consumeStream(response);
      finishTurn(final);
    } catch (error) {
      const message = error instanceof Error ? error.message : "审批处理失败";
      updateTimeline((current) => current.map((item) => item.kind === "approval" && item.approval.id === approval.id ? { ...item, resolved: false } : item));
      setStatus("审批失败");
      showToast("error", message);
    } finally {
      setBusy(false);
      setStreamingText("");
    }
  }

  function handleSubmit() {
    void sendMessage(input);
  }

  const panel = (className: string, scrollContainerRef: RefObject<HTMLDivElement | null>) => (
    <section className={className}
      aria-label="全局账本 Agent"
    >
      <header className="flex shrink-0 items-center justify-between border-b border-line bg-panel px-3 pb-3 pt-[calc(env(safe-area-inset-top)+0.75rem)] md:py-3">
        <div className="flex min-w-0 items-center gap-2.5">
          <span className="grid h-9 w-9 shrink-0 place-items-center rounded-md bg-brand text-paper"><Bot className="h-4 w-4" /></span>
          <div className="min-w-0">
            <h2 className="truncate text-sm font-semibold text-ink">账本 Agent</h2>
            <p className="truncate text-xs text-stone">{status}</p>
          </div>
        </div>
        <div className="flex items-center gap-1">
          <button type="button" className="hidden h-8 w-8 place-items-center rounded-md border border-line text-stone hover:bg-tag md:grid" title={desktopFullscreen ? "退出全屏" : "全屏查看会话"} aria-label={desktopFullscreen ? "退出全屏" : "全屏查看会话"} onClick={() => setDesktopFullscreen((current) => !current)}>{desktopFullscreen ? <Minimize2 className="h-4 w-4" /> : <Maximize2 className="h-4 w-4" />}</button>
          <button type="button" className="grid h-8 w-8 place-items-center rounded-md border border-line text-stone hover:bg-tag" title="新建会话" aria-label="新建会话" onClick={createSession} disabled={busy}><Plus className="h-4 w-4" /></button>
          <button type="button" className="grid h-8 w-8 place-items-center rounded-md border border-line text-stone hover:bg-tag" title="关闭" aria-label="关闭" onClick={() => setOpen(false)}><X className="h-4 w-4" /></button>
        </div>
      </header>

      <div ref={scrollContainerRef} className="min-h-0 min-w-0 max-w-full flex-1 overflow-y-auto overflow-x-hidden px-3 py-4 md:px-4">
        {!hasConversation && <div className="mb-4 grid grid-cols-1 gap-2 sm:grid-cols-2 md:grid-cols-1">
          {suggestions.map((suggestion) => <button key={suggestion} type="button" className="min-h-11 rounded-md border border-line bg-panel px-3 py-2 text-left text-sm text-olive hover:bg-tag" onClick={() => void sendMessage(suggestion)} disabled={busy}>{suggestion}</button>)}
        </div>}
        <div className="min-w-0 max-w-full space-y-3">
          {timeline.map((item) => {
            if (item.kind === "message") return <MessageBubble key={item.id} item={item} />;
            if (item.kind === "tool") return <ToolCard key={item.id} tool={item.tool} expanded={Boolean(expandedTools[item.id])} onToggle={() => setExpandedTools((current) => ({ ...current, [item.id]: !current[item.id] }))} />;
            if (item.kind === "artifact") return <ArtifactCard key={item.id} artifact={item.artifact} onApplyBQL={onApplyBQL} onNavigate={onNavigate} />;
            return <ApprovalCard key={item.id} approval={item.approval} resolved={item.resolved} busy={busy} onResolve={resolveApproval} />;
          })}
          {busy && streamingText && <MessageBubble item={{ kind: "message", id: "streaming", role: "assistant", content: streamingText }} />}
          {busy && !streamingText && <div className="flex items-center gap-2 py-2 text-sm text-stone"><LoaderCircle className="h-4 w-4 animate-spin" />{status}</div>}
        </div>
      </div>

      <footer className="shrink-0 border-t border-line bg-panel px-3 pb-[calc(env(safe-area-inset-bottom)+0.75rem)] pt-3 md:p-3">
        <div className="mb-2 flex flex-wrap items-center gap-x-2 gap-y-1.5 px-0.5">
          <ShieldCheck className="h-4 w-4 shrink-0 text-brand" />
          <span className="text-xs font-medium text-ink">审批</span>
          <div className="ml-auto flex min-w-0 rounded-md border border-line bg-paper p-0.5" role="tablist" aria-label="Agent 审批策略">
            <button type="button" role="tab" aria-selected={approvalPolicy === "on-write"} className={`min-w-0 rounded-sm px-2 py-1 text-[11px] ${approvalPolicy === "on-write" ? "bg-brand text-paper" : "text-stone hover:bg-tag"}`} onClick={() => setApprovalPolicy("on-write")}>常规</button>
            <button type="button" role="tab" aria-selected={approvalPolicy === "always"} className={`min-w-0 rounded-sm px-2 py-1 text-[11px] ${approvalPolicy === "always" ? "bg-brand text-paper" : "text-stone hover:bg-tag"}`} onClick={() => setApprovalPolicy("always")}>逐项确认</button>
          </div>
          <span className="basis-full text-[11px] leading-4 text-stone">{approvalPolicy === "always" ? "每个工具调用都要你确认" : "读取自动执行，账本写入始终确认"}</span>
        </div>
        <div className="overflow-hidden rounded-md border border-line bg-paper focus-within:ring-2 focus-within:ring-brand/25">
          <textarea
            ref={textareaRef}
            className="block max-h-40 min-h-20 w-full resize-none bg-transparent px-3 py-2.5 text-sm leading-relaxed text-ink outline-none placeholder:text-stone"
            value={input}
            onChange={(event) => setInput(event.currentTarget.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
                event.preventDefault();
                handleSubmit();
              }
            }}
            placeholder="询问账本，生成 BQL，或创建待确认操作"
            disabled={busy}
          />
          <div className="flex items-center justify-between border-t border-line px-2 py-2">
            <span className="truncate px-1 text-[11px] text-stone">{context.page || "global"}</span>
            <button type="button" className="grid h-8 w-8 shrink-0 place-items-center rounded-md bg-brand text-paper disabled:opacity-45" onClick={handleSubmit} disabled={busy || !input.trim()} aria-label="发送" title="发送"><Send className="h-4 w-4" /></button>
          </div>
        </div>
      </footer>
    </section>
  );

  return <>
    <aside className={`ledger-agent-dock hidden min-w-0 ${desktopFullscreen ? "" : "md:block"}`} data-open={open && !desktopFullscreen ? "true" : "false"} aria-label="账本 Agent 侧栏">
      {open && !desktopFullscreen && panel("flex h-full w-full min-w-0 flex-col overflow-hidden bg-paper", desktopScrollRef)}
    </aside>
    {open && desktopFullscreen && createPortal(
      <section className="fixed inset-0 z-[100] hidden overflow-hidden bg-paper md:flex" aria-label="账本 Agent 全屏工作区">
        <aside className="flex w-72 shrink-0 flex-col border-r border-line bg-panel" aria-label="Agent 会话历史">
          <div className="flex h-16 shrink-0 items-center justify-between border-b border-line px-4">
            <div><h2 className="text-sm font-semibold text-ink">会话历史</h2><p className="text-xs text-stone">{sessions.length} 个会话</p></div>
            <button type="button" className="grid h-8 w-8 place-items-center rounded-md border border-line text-brand hover:bg-tag disabled:opacity-50" title="新建会话" aria-label="新建会话" onClick={createSession} disabled={busy}><Plus className="h-4 w-4" /></button>
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto p-2">
            {[...sessions].sort((left, right) => right.updatedAt - left.updatedAt).map((session) => <button key={session.id} type="button" className={`mb-1 w-full rounded-md px-3 py-2.5 text-left transition ${session.id === activeSession.id ? "bg-brand text-paper" : "text-ink hover:bg-tag"}`} onClick={() => selectSession(session.id)} disabled={busy}>
              <span className="block truncate text-sm font-medium">{sessionLabel(session)}</span>
              <span className={`mt-1 block text-[11px] ${session.id === activeSession.id ? "text-paper/75" : "text-stone"}`}>{sessionTime(session)} · {session.timeline.length} 条记录</span>
            </button>)}
          </div>
        </aside>
        {panel("flex min-w-0 flex-1 flex-col overflow-hidden bg-paper", fullscreenScrollRef)}
      </section>,
      document.body
    )}
    {open && createPortal(panel("fixed inset-0 z-[90] flex min-w-0 max-w-full flex-col overflow-hidden bg-paper shadow-2xl md:hidden", mobileScrollRef), document.body)}
  </>;
}

function MessageBubble({ item }: { item: MessageItem }) {
  const user = item.role === "user";
  return <div className={`flex min-w-0 max-w-full ${user ? "justify-end" : "justify-start"}`}>
    <div className={`min-w-0 max-w-[92%] break-words rounded-md px-3 py-2 text-sm leading-relaxed [overflow-wrap:anywhere] ${user ? "bg-brand text-paper whitespace-pre-wrap" : "border border-line bg-panel text-ink [&_pre]:max-w-full [&_pre]:overflow-x-auto [&_pre]:rounded-sm [&_pre]:bg-paper [&_pre]:p-2 [&_code]:break-words [&_a]:break-all"}`}>{user ? item.content : <MessageResponse>{item.content}</MessageResponse>}</div>
  </div>;
}

function ToolCard({ tool, expanded, onToggle }: { tool: AgentToolEvent; expanded: boolean; onToggle: () => void }) {
  const state = tool.status === "running" ? <LoaderCircle className="h-3.5 w-3.5 animate-spin text-brand" /> : tool.status === "completed" ? <Check className="h-3.5 w-3.5 text-[var(--success)]" /> : <Ban className="h-3.5 w-3.5 text-[var(--danger)]" />;
  return <div className="min-w-0 max-w-full overflow-hidden rounded-md border border-line bg-panel">
    <button type="button" className="flex w-full items-center justify-between gap-3 px-3 py-2 text-left" onClick={onToggle}>
      <span className="flex min-w-0 items-center gap-2">{state}<span className="truncate text-sm font-medium text-ink">{tool.title}</span><span className="truncate font-mono text-[10px] text-stone">{tool.name}</span></span>
      {expanded ? <ChevronUp className="h-3.5 w-3.5 shrink-0 text-stone" /> : <ChevronDown className="h-3.5 w-3.5 shrink-0 text-stone" />}
    </button>
    {expanded && <pre className="max-h-44 max-w-full overflow-auto border-t border-line p-3 text-[11px] leading-relaxed text-stone [overflow-wrap:anywhere]">{JSON.stringify(tool.error ? { error: tool.error } : tool.output ?? tool.input ?? {}, null, 2)}</pre>}
  </div>;
}

function ApprovalCard({ approval, resolved, busy, onResolve }: { approval: AgentApproval; resolved?: boolean; busy: boolean; onResolve: (approval: AgentApproval, approved: boolean) => void }) {
  return <div className="min-w-0 max-w-full overflow-hidden rounded-md border border-[var(--warning)] bg-panel p-3">
    <div className="flex items-start gap-2"><Database className="mt-0.5 h-4 w-4 shrink-0 text-[var(--warning)]" /><div className="min-w-0"><div className="text-sm font-semibold text-ink">{approval.toolTitle}</div><div className="mt-1 text-sm text-stone">{approval.summary}</div></div></div>
    <div className="mt-3 flex justify-end gap-2">
      <button type="button" className="h-8 rounded-md border border-line px-3 text-sm text-stone hover:bg-tag disabled:opacity-50" onClick={() => onResolve(approval, false)} disabled={busy || resolved}>取消</button>
      <button type="button" className="h-8 rounded-md bg-brand px-3 text-sm text-paper hover:bg-brand/90 disabled:opacity-50" onClick={() => onResolve(approval, true)} disabled={busy || resolved}>{resolved ? "处理中" : "确认执行"}</button>
    </div>
  </div>;
}

function ArtifactCard({ artifact, onApplyBQL, onNavigate }: { artifact: AgentArtifact; onApplyBQL: (query: string) => void; onNavigate: (path: string) => void }) {
  if (artifact.type === "bql_query") {
    const query = objectString(artifact.data, "query");
    return <div className="min-w-0 max-w-full overflow-hidden rounded-md border border-line bg-panel">
      <div className="flex items-center justify-between border-b border-line px-3 py-2"><span className="text-sm font-semibold text-ink">{artifact.title}</span><button type="button" className="inline-flex h-8 items-center gap-1.5 rounded-md bg-brand px-2.5 text-xs text-paper" onClick={() => onApplyBQL(query)} disabled={!query}><Play className="h-3.5 w-3.5" />应用</button></div>
      <pre className="max-h-56 overflow-auto whitespace-pre-wrap p-3 font-mono text-[11px] leading-relaxed text-olive">{query}</pre>
    </div>;
  }
  if (artifact.type === "table") return <BQLTableCard title={artifact.title} result={artifact.data as BQLResult} />;
  if (artifact.type === "chart") {
    const data = artifact.data as { kind?: string; result?: BQLResult };
    return data.result ? <BQLChartCard title={artifact.title} kind={data.kind ?? "bar"} result={data.result} /> : null;
  }
  if (artifact.type === "transaction_draft") {
    const entries = objectArray<ParsedTransaction>(artifact.data, "entries");
    return <div className="min-w-0 max-w-full overflow-hidden rounded-md border border-line bg-panel p-3"><h3 className="text-sm font-semibold text-ink">{artifact.title} · {entries.length}</h3><div className="mt-2 space-y-2">{entries.map((entry, index) => <div key={`${entry.date}-${entry.payee}-${index}`} className="rounded-md border border-line bg-paper p-2.5"><div className="flex min-w-0 items-center justify-between gap-3 text-sm"><strong className="truncate text-ink">{entry.date} {entry.payee}</strong><span className="shrink-0 text-stone">{entry.postings[0]?.amount} {entry.postings[0]?.currency}</span></div><div className="mt-1 truncate text-xs text-stone">{entry.narration || entry.postings.map((posting) => posting.account).join(" · ")}</div></div>)}</div></div>;
  }
  if (artifact.type === "account_draft") {
    const operations = objectArray<AccountOperation>(artifact.data, "operations");
    return <div className="rounded-md border border-line bg-panel p-3"><h3 className="text-sm font-semibold text-ink">{artifact.title} · {operations.length}</h3><div className="mt-2 divide-y divide-line border-y border-line">{operations.map((operation, index) => <div key={`${operation.kind}-${operation.account}-${index}`} className="flex items-center justify-between gap-3 py-2 text-sm"><span className="min-w-0 truncate text-ink">{operation.account}</span><span className="shrink-0 text-xs uppercase text-stone">{operation.kind}</span></div>)}</div></div>;
  }
  if (artifact.type === "navigation") {
    const path = objectString(artifact.data, "path");
    return <button type="button" className="flex w-full items-center justify-between rounded-md border border-line bg-panel px-3 py-2.5 text-sm text-ink hover:bg-tag" onClick={() => onNavigate(path)} disabled={!path}><span>{artifact.title}</span><ExternalLink className="h-4 w-4 text-stone" /></button>;
  }
  return null;
}

function BQLTableCard({ title, result }: { title: string; result: BQLResult }) {
  if (!result?.columns || !result?.rows) return null;
  return <div className="overflow-hidden rounded-md border border-line bg-panel">
    <div className="flex items-center justify-between border-b border-line px-3 py-2"><span className="text-sm font-semibold text-ink">{title}</span><span className="text-xs text-stone">{result.rowCount} 行</span></div>
    <div className="max-h-64 overflow-auto"><table className="min-w-full text-left text-xs"><thead className="sticky top-0 bg-tag text-stone"><tr>{result.columns.map((column) => <th key={column.name} className="whitespace-nowrap border-b border-line px-2.5 py-2 font-medium">{column.name}</th>)}</tr></thead><tbody>{result.rows.slice(0, 12).map((row, rowIndex) => <tr key={rowIndex} className="border-b border-line/70">{result.columns.map((column, columnIndex) => <td key={`${rowIndex}-${column.name}`} className="max-w-40 truncate whitespace-nowrap px-2.5 py-2 text-ink">{formatValue(row[columnIndex], column)}</td>)}</tr>)}</tbody></table></div>
  </div>;
}

function BQLChartCard({ title, kind, result }: { title: string; kind: string; result: BQLResult }) {
  const model = buildChartData(result);
  if (!model) return <BQLTableCard title={title} result={result} />;
  const data = kind === "pie" ? model.data.filter((item) => item.value > 0).slice(0, 10) : model.data.slice(0, 30);
  return <div className="rounded-md border border-line bg-panel">
    <div className="border-b border-line px-3 py-2 text-sm font-semibold text-ink">{title}</div>
    <div className="h-64 px-2 py-3"><ResponsiveContainer width="100%" height="100%">{kind === "pie" ? <PieChart><Tooltip /><Pie data={data} dataKey="value" nameKey="label" innerRadius="45%" outerRadius="75%">{data.map((item, index) => <Cell key={item.label} fill={chartColors[index % chartColors.length]} />)}</Pie></PieChart> : kind === "line" ? <LineChart data={data}><CartesianGrid stroke="var(--chart-grid)" strokeDasharray="3 3" vertical={false} /><XAxis dataKey="label" tick={{ fontSize: 10 }} tickLine={false} axisLine={false} /><YAxis tick={{ fontSize: 10 }} tickLine={false} axisLine={false} width={52} /><Tooltip /><Line type="monotone" dataKey="value" stroke="var(--chart-primary)" strokeWidth={2} dot={false} /></LineChart> : <BarChart data={data}><CartesianGrid stroke="var(--chart-grid)" strokeDasharray="3 3" vertical={false} /><XAxis dataKey="label" tick={{ fontSize: 10 }} tickLine={false} axisLine={false} /><YAxis tick={{ fontSize: 10 }} tickLine={false} axisLine={false} width={52} /><Tooltip /><Bar dataKey="value" fill="var(--chart-primary)" radius={[3, 3, 0, 0]} /></BarChart>}</ResponsiveContainer></div>
  </div>;
}

function buildChartData(result: BQLResult) {
  const valueIndex = result.columns.findIndex((column) => column.type === "money" || column.type === "number");
  const labelIndex = result.columns.findIndex((column, index) => index !== valueIndex && column.type !== "money" && column.type !== "number");
  if (valueIndex < 0 || labelIndex < 0) return null;
  const valueColumn = result.columns[valueIndex];
  const data = result.rows.map((row, index) => {
    const numeric = Number(row[valueIndex]);
    return {
      label: String(row[labelIndex] ?? `行 ${index + 1}`),
      value: normalizeBQLChartValue(numeric, valueColumn),
    };
  }).filter((item) => Number.isFinite(item.value));
  return data.length ? { data } : null;
}

export function normalizeBQLChartValue(value: number, column: BQLColumn) {
  return column.type === "money" ? value / 100 : value;
}

function formatValue(value: unknown, column: BQLColumn) {
  if (value == null) return "";
  if (typeof value === "number" && column.type === "money") return new Intl.NumberFormat("zh-CN", { minimumFractionDigits: 2 }).format(value / 100);
  if (typeof value === "number") return new Intl.NumberFormat("zh-CN").format(value);
  return String(value);
}

function objectString(value: unknown, key: string) {
  if (!value || typeof value !== "object") return "";
  const result = (value as Record<string, unknown>)[key];
  return typeof result === "string" ? result : "";
}

function objectArray<T>(value: unknown, key: string): T[] {
  if (!value || typeof value !== "object") return [];
  const result = (value as Record<string, unknown>)[key];
  return Array.isArray(result) ? result as T[] : [];
}

function storageKey() {
  return `ledger.agent.workspace.v1:${apiEndpointLedgerScope()}`;
}

function readStoredAgent(): { approvalPolicy: AgentApprovalPolicy; activeSessionId: string; sessions: AgentSession[] } {
  try {
    const raw = window.localStorage.getItem(storageKey());
    if (!raw) {
      const session = createAgentSession();
      return { approvalPolicy: "on-write", activeSessionId: session.id, sessions: [session] };
    }
    const value = JSON.parse(raw) as { approvalPolicy?: string; activeSessionId?: string; sessions?: unknown; sessionId?: string; timeline?: unknown; messages?: unknown };
    const sessions = restoreSessions(value.sessions);
    if (!sessions.length) sessions.push(createAgentSession(restoreTimeline(value.timeline ?? value.messages), typeof value.sessionId === "string" ? value.sessionId : ""));
    const activeSessionId = typeof value.activeSessionId === "string" && sessions.some((session) => session.id === value.activeSessionId) ? value.activeSessionId : sessions[0].id;
    return {
      approvalPolicy: value.approvalPolicy === "always" ? "always" : "on-write",
      activeSessionId,
      sessions,
    };
  } catch {
    const session = createAgentSession();
    return { approvalPolicy: "on-write", activeSessionId: session.id, sessions: [session] };
  }
}

export function restoreSessions(value: unknown): AgentSession[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const session = item as Record<string, unknown>;
    if (typeof session.id !== "string") return [];
    const createdAt = typeof session.createdAt === "number" && Number.isFinite(session.createdAt) ? session.createdAt : Date.now();
    const updatedAt = typeof session.updatedAt === "number" && Number.isFinite(session.updatedAt) ? session.updatedAt : createdAt;
    return [{
      id: session.id,
      serverSessionId: typeof session.serverSessionId === "string" ? session.serverSessionId : "",
      createdAt,
      updatedAt,
      timeline: restoreTimeline(session.timeline),
    }];
  }).slice(0, MAX_STORED_SESSIONS);
}

export function restoreTimeline(value: unknown): TimelineItem[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is TimelineItem => {
    if (!item || typeof item !== "object") return false;
    const candidate = item as Record<string, unknown>;
    if (typeof candidate.id !== "string") return false;
    if (candidate.kind === "message") return (candidate.role === "user" || candidate.role === "assistant") && typeof candidate.content === "string";
    if (candidate.kind === "tool") {
      const tool = candidate.tool;
      return Boolean(tool && typeof tool === "object" && typeof (tool as Record<string, unknown>).id === "string" && typeof (tool as Record<string, unknown>).name === "string" && typeof (tool as Record<string, unknown>).title === "string" && ["running", "completed", "error"].includes(String((tool as Record<string, unknown>).status)));
    }
    if (candidate.kind === "artifact") {
      const artifact = candidate.artifact;
      return Boolean(artifact && typeof artifact === "object" && typeof (artifact as Record<string, unknown>).id === "string" && typeof (artifact as Record<string, unknown>).type === "string" && typeof (artifact as Record<string, unknown>).title === "string" && "data" in (artifact as Record<string, unknown>));
    }
    if (candidate.kind === "approval") {
      const approval = candidate.approval;
      return Boolean(approval && typeof approval === "object" && typeof (approval as Record<string, unknown>).id === "string" && typeof (approval as Record<string, unknown>).sessionId === "string" && typeof (approval as Record<string, unknown>).toolName === "string");
    }
    return false;
  }).slice(-MAX_STORED_TIMELINE_ITEMS);
}

function writeStoredAgent(value: { approvalPolicy: AgentApprovalPolicy; activeSessionId: string; sessions: AgentSession[] }) {
  try {
    window.localStorage.setItem(storageKey(), JSON.stringify({
      ...value,
      sessions: value.sessions.slice(0, MAX_STORED_SESSIONS).map((session) => ({ ...session, timeline: session.timeline.slice(-MAX_STORED_TIMELINE_ITEMS) })),
    }));
  } catch {
    // Conversation persistence is optional.
  }
}
