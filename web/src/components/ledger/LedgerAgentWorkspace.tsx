"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { AppWindow, Ban, Bot, Check, ChevronDown, ChevronUp, Database, ExternalLink, LoaderCircle, PanelRight, Play, Send, Trash2, X } from "lucide-react";
import { Bar, BarChart, CartesianGrid, Cell, Line, LineChart, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { apiEndpointLedgerScope, apiFetch } from "@/lib/apiEndpoints";
import { readLedgerAgentStream, type AgentApproval, type AgentArtifact, type AgentFinal, type AgentToolEvent } from "@/lib/ledgerAgentStream";
import type { ParsedTransaction } from "@/lib/schemas";
import type { AccountOperation } from "./types";

type AgentMode = "dock" | "float";

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

export function LedgerAgentWorkspace({
  request,
  context,
  onApplyBQL,
  onNavigate,
  onChanged,
  showToast,
}: {
  request?: LedgerAgentRequest | null;
  context: AgentContext;
  onApplyBQL: (query: string) => void;
  onNavigate: (path: string) => void;
  onChanged: () => void | Promise<void>;
  showToast: (kind: "info" | "success" | "error", text: string) => void;
}) {
  const stored = useMemo(() => readStoredAgent(), []);
  const [open, setOpen] = useState(false);
  const [mode, setMode] = useState<AgentMode>(stored.mode);
  const [sessionId, setSessionId] = useState(stored.sessionId);
  const [timeline, setTimeline] = useState<TimelineItem[]>(stored.messages);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState("就绪");
  const [streamingText, setStreamingText] = useState("");
  const [expandedTools, setExpandedTools] = useState<Record<string, boolean>>({});
  const requestRef = useRef(0);
  const sendRef = useRef<(text: string) => Promise<void>>(async () => undefined);
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);

  useEffect(() => {
    writeStoredAgent({ mode, sessionId, messages: timeline.filter((item): item is MessageItem => item.kind === "message").slice(-40) });
  }, [mode, sessionId, timeline]);

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
    requestAnimationFrame(() => scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight }));
  }, [open, timeline, streamingText, status]);

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
    setTimeline((current) => [...current, { kind: "message", id: nextID(), role: "user", content: prompt }]);
    try {
      const response = await apiFetch("/api/ai/agent/turn", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sessionId, message: prompt, messages: history, context }),
      }, { kind: "write" });
      const final = await consumeStream(response);
      finishTurn(final);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Agent 请求失败";
      setTimeline((current) => [...current, { kind: "message", id: nextID(), role: "assistant", content: `处理失败：${message}` }]);
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
      onArtifact: (artifact) => setTimeline((current) => [...current, { kind: "artifact", id: artifact.id, artifact }]),
      onApproval: (approval) => setTimeline((current) => [...current, { kind: "approval", id: approval.id, approval }]),
    });
  }

  function finishTurn(final: AgentFinal) {
    setSessionId(final.sessionId);
    setStatus(final.pendingApprovalId ? "等待确认" : "就绪");
    if (final.message.trim()) {
      setTimeline((current) => [...current, { kind: "message", id: nextID(), role: "assistant", content: final.message.trim() }]);
    }
    if (final.refreshLedger) {
      showToast("success", "账本已更新");
      void onChanged();
    }
  }

  function upsertTool(tool: AgentToolEvent) {
    setTimeline((current) => {
      const index = current.findIndex((item) => item.kind === "tool" && item.tool.id === tool.id);
      if (index < 0) return [...current, { kind: "tool", id: tool.id, tool }];
      return current.map((item, itemIndex) => itemIndex === index && item.kind === "tool" ? { ...item, tool: { ...item.tool, ...tool } } : item);
    });
  }

  async function resolveApproval(approval: AgentApproval, approved: boolean) {
    if (busy) return;
    setBusy(true);
    setStatus(approved ? "正在执行已确认操作" : "正在取消操作");
    setTimeline((current) => current.map((item) => item.kind === "approval" && item.approval.id === approval.id ? { ...item, resolved: true } : item));
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
      setTimeline((current) => current.map((item) => item.kind === "approval" && item.approval.id === approval.id ? { ...item, resolved: false } : item));
      setStatus("审批失败");
      showToast("error", message);
    } finally {
      setBusy(false);
      setStreamingText("");
    }
  }

  function resetConversation() {
    if (busy) return;
    setSessionId("");
    setTimeline([]);
    setInput("");
    setStreamingText("");
    setStatus("就绪");
  }

  function handleSubmit() {
    void sendMessage(input);
  }

  const shell = open ? (
    <section className={mode === "dock"
      ? "fixed inset-y-0 right-0 z-[90] flex w-full flex-col border-l border-line bg-paper shadow-2xl md:w-[430px]"
      : "fixed inset-0 z-[90] flex flex-col bg-paper shadow-2xl md:inset-auto md:bottom-5 md:right-5 md:h-[min(760px,calc(100dvh-2.5rem))] md:w-[430px] md:rounded-md md:border md:border-line"}
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
          <button type="button" className={`hidden h-8 w-8 place-items-center rounded-md border border-line md:grid ${mode === "dock" ? "bg-brand text-paper" : "text-stone hover:bg-tag"}`} title="右侧停靠" aria-label="右侧停靠" onClick={() => setMode("dock")}><PanelRight className="h-4 w-4" /></button>
          <button type="button" className={`hidden h-8 w-8 place-items-center rounded-md border border-line md:grid ${mode === "float" ? "bg-brand text-paper" : "text-stone hover:bg-tag"}`} title="悬浮窗口" aria-label="悬浮窗口" onClick={() => setMode("float")}><AppWindow className="h-4 w-4" /></button>
          <button type="button" className="grid h-8 w-8 place-items-center rounded-md border border-line text-stone hover:bg-tag" title="新对话" aria-label="新对话" onClick={resetConversation} disabled={busy}><Trash2 className="h-4 w-4" /></button>
          <button type="button" className="grid h-8 w-8 place-items-center rounded-md border border-line text-stone hover:bg-tag" title="关闭" aria-label="关闭" onClick={() => setOpen(false)}><X className="h-4 w-4" /></button>
        </div>
      </header>

      <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto px-3 py-4 md:px-4">
        {!hasConversation && <div className="mb-4 grid grid-cols-1 gap-2 sm:grid-cols-2 md:grid-cols-1">
          {suggestions.map((suggestion) => <button key={suggestion} type="button" className="min-h-11 rounded-md border border-line bg-panel px-3 py-2 text-left text-sm text-olive hover:bg-tag" onClick={() => void sendMessage(suggestion)} disabled={busy}>{suggestion}</button>)}
        </div>}
        <div className="space-y-3">
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
  ) : (
    <button type="button" className="fixed bottom-[calc(5.5rem+env(safe-area-inset-bottom))] right-3 z-[70] grid h-11 w-11 place-items-center rounded-md border border-line bg-brand text-paper shadow-lg hover:bg-brand/90 md:bottom-5 md:right-5" onClick={() => setOpen(true)} aria-label="打开账本 Agent" title="账本 Agent"><Bot className="h-5 w-5" /></button>
  );

  return createPortal(shell, document.body);
}

function MessageBubble({ item }: { item: MessageItem }) {
  const user = item.role === "user";
  return <div className={`flex ${user ? "justify-end" : "justify-start"}`}>
    <div className={`max-w-[88%] whitespace-pre-wrap rounded-md px-3 py-2 text-sm leading-relaxed ${user ? "bg-brand text-paper" : "border border-line bg-panel text-ink"}`}>{item.content}</div>
  </div>;
}

function ToolCard({ tool, expanded, onToggle }: { tool: AgentToolEvent; expanded: boolean; onToggle: () => void }) {
  const state = tool.status === "running" ? <LoaderCircle className="h-3.5 w-3.5 animate-spin text-brand" /> : tool.status === "completed" ? <Check className="h-3.5 w-3.5 text-[var(--success)]" /> : <Ban className="h-3.5 w-3.5 text-[var(--danger)]" />;
  return <div className="rounded-md border border-line bg-panel">
    <button type="button" className="flex w-full items-center justify-between gap-3 px-3 py-2 text-left" onClick={onToggle}>
      <span className="flex min-w-0 items-center gap-2">{state}<span className="truncate text-sm font-medium text-ink">{tool.title}</span><span className="truncate font-mono text-[10px] text-stone">{tool.name}</span></span>
      {expanded ? <ChevronUp className="h-3.5 w-3.5 shrink-0 text-stone" /> : <ChevronDown className="h-3.5 w-3.5 shrink-0 text-stone" />}
    </button>
    {expanded && <pre className="max-h-44 overflow-auto border-t border-line p-3 text-[11px] leading-relaxed text-stone">{JSON.stringify(tool.error ? { error: tool.error } : tool.output ?? tool.input ?? {}, null, 2)}</pre>}
  </div>;
}

function ApprovalCard({ approval, resolved, busy, onResolve }: { approval: AgentApproval; resolved?: boolean; busy: boolean; onResolve: (approval: AgentApproval, approved: boolean) => void }) {
  return <div className="rounded-md border border-[var(--warning)] bg-panel p-3">
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
    return <div className="rounded-md border border-line bg-panel">
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
    return <div className="rounded-md border border-line bg-panel p-3"><h3 className="text-sm font-semibold text-ink">{artifact.title} · {entries.length}</h3><div className="mt-2 space-y-2">{entries.map((entry, index) => <div key={`${entry.date}-${entry.payee}-${index}`} className="rounded-md border border-line bg-paper p-2.5"><div className="flex items-center justify-between gap-3 text-sm"><strong className="truncate text-ink">{entry.date} {entry.payee}</strong><span className="shrink-0 text-stone">{entry.postings[0]?.amount} {entry.postings[0]?.currency}</span></div><div className="mt-1 truncate text-xs text-stone">{entry.narration || entry.postings.map((posting) => posting.account).join(" · ")}</div></div>)}</div></div>;
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
  const data = result.rows.map((row, index) => ({ label: String(row[labelIndex] ?? `行 ${index + 1}`), value: Number(row[valueIndex]) })).filter((item) => Number.isFinite(item.value));
  return data.length ? { data } : null;
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

function readStoredAgent(): { mode: AgentMode; sessionId: string; messages: MessageItem[] } {
  try {
    const raw = window.localStorage.getItem(storageKey());
    if (!raw) return { mode: "dock", sessionId: "", messages: [] };
    const value = JSON.parse(raw) as { mode?: string; sessionId?: string; messages?: MessageItem[] };
    return {
      mode: value.mode === "float" ? "float" : "dock",
      sessionId: typeof value.sessionId === "string" ? value.sessionId : "",
      messages: Array.isArray(value.messages) ? value.messages.filter((item) => item?.kind === "message" && (item.role === "user" || item.role === "assistant") && typeof item.content === "string").slice(-40) : [],
    };
  } catch {
    return { mode: "dock", sessionId: "", messages: [] };
  }
}

function writeStoredAgent(value: { mode: AgentMode; sessionId: string; messages: MessageItem[] }) {
  try {
    window.localStorage.setItem(storageKey(), JSON.stringify(value));
  } catch {
    // Conversation persistence is optional.
  }
}
