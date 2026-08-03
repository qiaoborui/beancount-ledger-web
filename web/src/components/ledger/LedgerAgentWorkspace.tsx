"use client";

import { createPortal } from "react-dom";
import { useEffect, useMemo, useRef, useState, type ReactNode, type RefObject } from "react";
import { Archive, ArchiveRestore, Ban, Bot, Check, ChevronDown, ChevronUp, ClipboardPenLine, Database, ExternalLink, History, LineChart as LineChartIcon, ListChecks, LoaderCircle, Maximize2, Minimize2, MoreHorizontal, Play, Plus, Send, ShieldCheck, SlidersHorizontal, Sparkles, Trash2, Wrench, X } from "lucide-react";
import { Bar, BarChart, CartesianGrid, Cell, Line, LineChart, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { apiEndpointLedgerScope, apiFetch } from "@/lib/apiEndpoints";
import { readLedgerAgentStream, type AgentApproval, type AgentArtifact, type AgentFinal, type AgentToolEvent } from "@/lib/ledgerAgentStream";
import { MessageResponse } from "@/components/ai-elements/message";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuRadioGroup, DropdownMenuRadioItem, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
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
type AgentSession = { id: string; serverSessionId: string; title: string; archived: boolean; createdAt: number; updatedAt: number; timeline: TimelineItem[] };
const MAX_STORED_SESSIONS = 30;
const AGENT_TIMELINE_PAGE_SIZE = 80;
const AGENT_TIMELINE_REFRESH_MS = 1500;
type AgentTimelinePage = { items: TimelineItem[]; nextBefore: number | null };
type TimelinePagination = { loading: boolean; nextBefore: number | null };

type BQLColumn = { name: string; type: string };
type BQLResult = { columns: BQLColumn[]; rows: unknown[][]; query: string; warnings?: string[]; valuationCurrency: string; rowCount: number };

type AgentStarter = { label: string; description: string; prompt: string; icon: ReactNode };

const agentStarters: AgentStarter[] = [
  { label: "支出分析", description: "分类、趋势与异常", prompt: "分析当前周期的支出，按分类、趋势和异常流水给我一份简洁结论。", icon: <LineChartIcon className="h-4 w-4" /> },
  { label: "生成记账草稿", description: "先解析，再等待确认", prompt: "帮我整理一笔交易为待确认的 Beancount 记账草稿：", icon: <ClipboardPenLine className="h-4 w-4" /> },
  { label: "对账检查", description: "定位余额和待处理项", prompt: "检查当前账户范围的待对账项、异常余额和可能重复的流水，给出处理建议。", icon: <ListChecks className="h-4 w-4" /> },
  { label: "账户维护", description: "创建、调整或关闭账户", prompt: "读取现有账户结构，为我创建、调整或关闭账户生成待确认草稿。", icon: <Wrench className="h-4 w-4" /> },
  { label: "导入整理", description: "检查重复与分类缺失", prompt: "检查最近导入的流水，找出重复项、分类缺失和需要人工确认的项目。", icon: <Sparkles className="h-4 w-4" /> },
];

const suggestions = agentStarters.slice(0, 4).map((starter) => starter.prompt);

const chartColors = ["var(--chart-palette-1, var(--chart-primary))", "var(--chart-palette-2, var(--stone))", "var(--chart-palette-3, var(--brand))", "var(--chart-palette-4, var(--warm))"];

function nextID() {
  return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

function containsSensitiveAgentInput(value: string) {
  return /密码|口令|验证码|密钥|身份证|\b(password|passcode|pin|otp|token|secret|cvv)\b/i.test(value) || /(?:\d[ -]?){12,}/.test(value);
}

function createAgentSession(timeline: TimelineItem[] = [], serverSessionId = `session-${nextID()}`): AgentSession {
  const now = Date.now();
  return { id: nextID(), serverSessionId, title: timelineTitle(timeline), archived: false, createdAt: now, updatedAt: now, timeline };
}

function sessionLabel(session: AgentSession) {
  return session.title || timelineTitle(session.timeline) || "新对话";
}

function timelineTitle(timeline: TimelineItem[]) {
  const firstPrompt = timeline.find((item): item is MessageItem => item.kind === "message" && item.role === "user");
  return firstPrompt?.content.trim() || "";
}

function sessionTime(session: AgentSession) {
  return new Intl.DateTimeFormat("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(session.updatedAt);
}

export function LedgerAgentWorkspace({
  presentation = "dock",
  request,
  open: controlledOpen,
  onOpenChange,
  context,
  onApplyBQL,
  onNavigate,
  onChanged,
  showToast,
}: {
  presentation?: "dock" | "page";
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
  const [showArchivedSessions, setShowArchivedSessions] = useState(false);
  const [sessionMutationID, setSessionMutationID] = useState("");
  const [timelinePagination, setTimelinePagination] = useState<Record<string, TimelinePagination>>({});
  const [desktopFullscreen, setDesktopFullscreen] = useState(false);
  const [mobileSessionListOpen, setMobileSessionListOpen] = useState(false);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState("就绪");
  const [streamingText, setStreamingText] = useState("");
  const [expandedTools, setExpandedTools] = useState<Record<string, boolean>>({});
  const requestRef = useRef(0);
  const timelineVersionRef = useRef(0);
  const sessionTitleHydrationRef = useRef(new Set<string>());
  const sendRef = useRef<(text: string) => Promise<void>>(async () => undefined);
  const desktopScrollRef = useRef<HTMLDivElement | null>(null);
  const fullscreenScrollRef = useRef<HTMLDivElement | null>(null);
  const mobileScrollRef = useRef<HTMLDivElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const open = controlledOpen ?? uncontrolledOpen;
  const activeSession = sessions.find((session) => session.id === activeSessionId) ?? sessions[0];
  const sessionId = activeSession.serverSessionId || `session-${activeSession.id}`;
  const timeline = activeSession.timeline;
  const archivedSessionCount = sessions.filter((session) => session.archived).length;
  const sidebarSessions = sessions.filter((session) => !session.archived || showArchivedSessions);
  const lastAssistantMessage = [...timeline].reverse().find((item): item is MessageItem => item.kind === "message" && item.role === "assistant");
  const pendingApproval = timeline.find((item): item is ApprovalItem => item.kind === "approval" && !item.resolved);
  const canContinue = !pendingApproval && (lastAssistantMessage?.content.includes("本次请求已完成 8 轮工具处理") ?? false);

  function setOpen(next: boolean) {
    setUncontrolledOpen(next);
    onOpenChange?.(next);
  }

  function updateActiveSession(update: (session: AgentSession) => AgentSession) {
    setSessions((current) => current.map((session) => session.id === activeSession.id ? update(session) : session));
  }

  function updateTimeline(update: (timeline: TimelineItem[]) => TimelineItem[]) {
    timelineVersionRef.current += 1;
    updateActiveSession((session) => {
      const timeline = update(session.timeline);
      return { ...session, title: session.title || timelineTitle(timeline), timeline, updatedAt: Date.now() };
    });
  }

  function createSession() {
    if (busy) return;
    const session = createAgentSession();
    setSessions((current) => [session, ...current].slice(0, MAX_STORED_SESSIONS));
    setActiveSessionId(session.id);
    setMobileSessionListOpen(false);
    setInput("");
    setStreamingText("");
    setStatus("就绪");
    requestAnimationFrame(() => textareaRef.current?.focus());
  }

  function archiveSession(session: AgentSession, archived: boolean) {
    if (busy || sessionMutationID) return;
    setSessions((current) => current.map((item) => item.id === session.id ? { ...item, archived } : item));
    if (archived && session.id === activeSession.id) {
      const next = sessions.find((item) => item.id !== session.id && !item.archived);
      if (next) setActiveSessionId(next.id);
      else createSession();
    }
  }

  async function deleteSession(session: AgentSession) {
    if (busy || sessionMutationID || (session.id === activeSession.id && pendingApproval)) return;
    if (!window.confirm(`删除“${sessionLabel(session)}”及其 Agent 会话记录？此操作无法恢复。`)) return;
    setSessionMutationID(session.id);
    try {
      await apiFetch(`/api/ai/agent/sessions/${encodeURIComponent(session.serverSessionId || `session-${session.id}`)}`, { method: "DELETE" }, { kind: "write" });
      const next = sessions.find((item) => item.id !== session.id && !item.archived) ?? sessions.find((item) => item.id !== session.id);
      setSessions((current) => current.filter((item) => item.id !== session.id));
      if (session.id === activeSession.id) {
        if (next) setActiveSessionId(next.id);
        else createSession();
      }
      showToast("success", "会话已删除");
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : "删除会话失败");
    } finally {
      setSessionMutationID("");
    }
  }

  function selectSession(sessionId: string) {
    if (busy) return;
    setMobileSessionListOpen(false);
    if (sessionId === activeSession.id) return;
    setActiveSessionId(sessionId);
    setInput("");
    setStreamingText("");
    setStatus("就绪");
  }

  useEffect(() => {
    writeStoredAgent({ approvalPolicy, activeSessionId, sessions });
  }, [activeSessionId, approvalPolicy, sessions]);

  useEffect(() => {
    void loadTimelinePage(sessionId);
  // sessionId changes after a legacy session receives its durable server id.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeSessionId, sessionId]);

  useEffect(() => {
    for (const session of sessions) {
      const serverSessionId = session.serverSessionId || `session-${session.id}`;
      if (session.title || timelineTitle(session.timeline) || sessionTitleHydrationRef.current.has(serverSessionId)) continue;
      sessionTitleHydrationRef.current.add(serverSessionId);
      void loadTimelinePage(serverSessionId);
    }
  }, [sessions]);

  useEffect(() => {
    if (!timelineNeedsServerRefresh(timeline)) return;
    const timer = window.setTimeout(() => void loadTimelinePage(sessionId), AGENT_TIMELINE_REFRESH_MS);
    return () => window.clearTimeout(timer);
  }, [sessionId, timeline]);

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
      const scrollRef = presentation === "page" ? desktopScrollRef : window.matchMedia("(min-width: 768px)").matches ? (desktopFullscreen ? fullscreenScrollRef : desktopScrollRef) : mobileScrollRef;
      scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight });
    });
  }, [desktopFullscreen, open, presentation, timeline, streamingText, status]);

  useEffect(() => {
    if (presentation === "page" || !open || (!desktopFullscreen && window.matchMedia("(min-width: 768px)").matches)) return;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = previousOverflow;
    };
  }, [desktopFullscreen, open, presentation]);

  useEffect(() => {
    if (!open) {
      setDesktopFullscreen(false);
      setMobileSessionListOpen(false);
    }
  }, [open]);

  const conversation = timeline.filter((item): item is MessageItem => item.kind === "message");
  const hasConversation = conversation.some((message) => message.role === "user");

  async function loadTimelinePage(serverSessionId: string, before?: number) {
    if (!serverSessionId) return;
    const timelineVersion = timelineVersionRef.current;
    setTimelinePagination((current) => ({ ...current, [serverSessionId]: { loading: true, nextBefore: current[serverSessionId]?.nextBefore ?? null } }));
    try {
      const query = before ? `?before=${before}` : "";
      const response = await apiFetch(`/api/ai/agent/sessions/${encodeURIComponent(serverSessionId)}/timeline${query}`, undefined, { kind: "read" });
      const page = normalizeAgentTimelinePage(await response.json());
      setSessions((current) => current.map((session) => {
        if ((session.serverSessionId || `session-${session.id}`) !== serverSessionId) return session;
        if (!before) {
          const title = timelineTitle(page.items) || session.title;
          if (!page.items.length) return title === session.title ? session : { ...session, title };
          if (timelineVersion === timelineVersionRef.current) return { ...session, title, timeline: page.items };
          const known = new Set(page.items.map((item) => item.id));
          return { ...session, title, timeline: [...page.items, ...session.timeline.filter((item) => !known.has(item.id))] };
        }
        const known = new Set(session.timeline.map((item) => item.id));
        return { ...session, timeline: [...page.items.filter((item) => !known.has(item.id)), ...session.timeline] };
      }));
      setTimelinePagination((current) => ({ ...current, [serverSessionId]: { loading: false, nextBefore: page.nextBefore } }));
    } catch {
      setTimelinePagination((current) => ({ ...current, [serverSessionId]: { loading: false, nextBefore: current[serverSessionId]?.nextBefore ?? null } }));
    }
  }

  async function sendMessage(text: string) {
    const prompt = text.trim();
    if (!prompt || busy) return;
    if (containsSensitiveAgentInput(prompt)) {
      showToast("error", "请勿在 Agent 对话中输入密码、验证码、令牌或完整卡号");
      return;
    }
    if (pendingApproval) {
      showToast("info", "请先确认或取消待处理操作");
      return;
    }
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
        body: JSON.stringify({ sessionId, message: prompt, context, approvalPolicy }),
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
    setStatus(
      final.pendingApprovalId || final.status === "approval_pending"
        ? "等待确认"
        : final.status === "budget_exhausted"
          ? "任务已暂停"
          : final.status === "cancelled"
            ? "已取消"
            : "就绪"
    );
    if (final.message.trim()) {
      updateTimeline((current) => [...current, { kind: "message", id: nextID(), role: "assistant", content: final.message.trim() }]);
    }
    void loadTimelinePage(final.sessionId);
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

  function selectStarter(starter: AgentStarter) {
    if (busy) return;
    setInput(starter.prompt);
    requestAnimationFrame(() => textareaRef.current?.focus());
  }

  const panel = (className: string, scrollContainerRef: RefObject<HTMLDivElement | null>) => (
    <section className={className}
      aria-label="全局账本 Agent"
    >
      <header className={`flex shrink-0 items-center justify-between border-b border-line bg-panel ${presentation === "page" ? "px-3 py-3" : "px-3 pb-3 pt-[calc(env(safe-area-inset-top)+0.75rem)]"} md:py-3`}>
        <div className="flex min-w-0 items-center gap-2.5">
          <span className="grid h-9 w-9 shrink-0 place-items-center rounded-md bg-brand text-paper"><Bot className="h-4 w-4" /></span>
          <div className="min-w-0">
            <h2 className="truncate text-sm font-semibold text-ink">账本 Agent</h2>
            <p className="truncate text-xs text-stone">{status}</p>
          </div>
        </div>
        <div className="flex items-center gap-1">
          <button type="button" className="grid h-9 w-9 place-items-center rounded-md border border-line text-stone hover:bg-tag md:h-8 md:w-8 md:hidden" title="查看会话历史" aria-label="查看会话历史" onClick={() => setMobileSessionListOpen(true)}><History className="h-4 w-4" /></button>
          {presentation === "dock" && <button type="button" className="hidden h-8 w-8 place-items-center rounded-md border border-line text-stone hover:bg-tag md:grid" title={desktopFullscreen ? "退出全屏" : "全屏查看会话"} aria-label={desktopFullscreen ? "退出全屏" : "全屏查看会话"} onClick={() => setDesktopFullscreen((current) => !current)}>{desktopFullscreen ? <Minimize2 className="h-4 w-4" /> : <Maximize2 className="h-4 w-4" />}</button>}
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button type="button" className="grid h-9 w-9 place-items-center rounded-md border border-line text-stone hover:bg-tag disabled:opacity-45 md:h-8 md:w-8" aria-label="管理当前会话" title="管理当前会话" disabled={busy || Boolean(pendingApproval) || Boolean(sessionMutationID)}><MoreHorizontal className="h-4 w-4" /></button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="border-line bg-paper text-ink">
              <DropdownMenuItem onSelect={() => archiveSession(activeSession, !activeSession.archived)}>{activeSession.archived ? <ArchiveRestore className="h-4 w-4" /> : <Archive className="h-4 w-4" />}{activeSession.archived ? "取消归档" : "归档会话"}</DropdownMenuItem>
              <DropdownMenuItem variant="destructive" onSelect={() => void deleteSession(activeSession)}><Trash2 className="h-4 w-4" />删除会话</DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
          <button type="button" className="grid h-9 w-9 place-items-center rounded-md border border-line text-stone hover:bg-tag md:h-8 md:w-8" title="新建会话" aria-label="新建会话" onClick={createSession} disabled={busy}><Plus className="h-4 w-4" /></button>
          {presentation === "dock" && <button type="button" className="grid h-8 w-8 place-items-center rounded-md border border-line text-stone hover:bg-tag" title="关闭" aria-label="关闭" onClick={() => setOpen(false)}><X className="h-4 w-4" /></button>}
        </div>
      </header>

      <div ref={scrollContainerRef} className="min-h-0 min-w-0 max-w-full flex-1 overflow-y-auto overflow-x-hidden px-3 py-4 md:px-4">
        {!hasConversation && <div className={`mb-4 grid grid-cols-1 gap-2 sm:grid-cols-2 ${presentation === "page" ? "md:grid-cols-2" : "md:grid-cols-1"}`}>
          {suggestions.map((suggestion) => <button key={suggestion} type="button" className="min-h-11 rounded-md border border-line bg-panel px-3 py-2 text-left text-sm text-olive hover:bg-tag" onClick={() => void sendMessage(suggestion)} disabled={busy}>{suggestion}</button>)}
        </div>}
        <div className="min-w-0 max-w-full space-y-3">
          {timelinePagination[sessionId]?.nextBefore != null && <button type="button" className="w-full rounded-md border border-line bg-panel px-3 py-2 text-xs text-olive hover:bg-tag disabled:opacity-50" onClick={() => void loadTimelinePage(sessionId, timelinePagination[sessionId].nextBefore ?? undefined)} disabled={busy || timelinePagination[sessionId]?.loading}>{timelinePagination[sessionId]?.loading ? "正在加载更早记录" : `加载更早记录（每页 ${AGENT_TIMELINE_PAGE_SIZE} 条）`}</button>}
          {timelinePagination[sessionId]?.loading && timeline.length === 0 && <div className="flex items-center gap-2 py-2 text-sm text-stone"><LoaderCircle className="h-4 w-4 animate-spin" />正在加载会话记录</div>}
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

      <footer className="shrink-0 border-t border-line bg-panel px-3 pb-[calc(env(safe-area-inset-bottom)+0.75rem)] pt-2 md:p-3">
        <div className="mb-2 flex items-center justify-between gap-2 px-0.5">
          <div className="flex min-w-0 items-center gap-1.5 text-xs text-stone">
            <ShieldCheck className="h-3.5 w-3.5 shrink-0 text-brand" />
            <span className="truncate">{approvalPolicy === "always" ? "逐项确认" : "写入时确认"}</span>
          </div>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button type="button" className="inline-flex h-8 shrink-0 items-center gap-1.5 rounded-md border border-line bg-paper px-2.5 text-xs font-medium text-ink active:scale-95 hover:bg-tag" aria-label="设置 Agent 审批策略">
                审批<ChevronDown className="h-3.5 w-3.5 text-stone" />
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-64 border-line bg-paper text-ink">
              <DropdownMenuLabel className="text-xs text-stone">审批策略</DropdownMenuLabel>
              <DropdownMenuSeparator className="bg-line" />
              <DropdownMenuRadioGroup value={approvalPolicy} onValueChange={(value) => setApprovalPolicy(value as AgentApprovalPolicy)}>
                <DropdownMenuRadioItem value="on-write" className="py-2.5 text-sm focus:bg-tag focus:text-ink">
                  <span><span className="block font-medium">写入时确认</span><span className="mt-0.5 block text-xs text-stone">读取自动执行，账本写入始终确认</span></span>
                </DropdownMenuRadioItem>
                <DropdownMenuRadioItem value="always" className="py-2.5 text-sm focus:bg-tag focus:text-ink">
                  <span><span className="block font-medium">逐项确认</span><span className="mt-0.5 block text-xs text-stone">每个 Agent 工具调用都要你确认</span></span>
                </DropdownMenuRadioItem>
              </DropdownMenuRadioGroup>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
        <div className="overflow-hidden rounded-md border border-line bg-paper focus-within:ring-2 focus-within:ring-brand/25">
          <textarea
            ref={textareaRef}
            className="block max-h-32 min-h-14 w-full resize-none bg-transparent px-3 py-2.5 text-sm leading-relaxed text-ink outline-none placeholder:text-stone"
            value={input}
            onChange={(event) => setInput(event.currentTarget.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
                event.preventDefault();
                handleSubmit();
              }
            }}
            placeholder="询问账本，或从工具开始"
            disabled={busy || Boolean(pendingApproval)}
          />
          <div className="flex items-center justify-between border-t border-line px-2 py-2">
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <button type="button" className="inline-flex h-8 min-w-0 items-center gap-1.5 rounded-md px-2 text-xs font-medium text-olive active:scale-95 hover:bg-tag disabled:opacity-45" disabled={busy || Boolean(pendingApproval)} aria-label="打开 Agent 工具">
                  <SlidersHorizontal className="h-3.5 w-3.5 text-brand" />工具
                </button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start" className="w-72 border-line bg-paper text-ink">
                <DropdownMenuLabel className="text-xs text-stone">选择一个起点</DropdownMenuLabel>
                <DropdownMenuSeparator className="bg-line" />
                {agentStarters.map((starter) => <DropdownMenuItem key={starter.label} className="items-start gap-2.5 py-2.5 focus:bg-tag focus:text-ink" onSelect={() => selectStarter(starter)}>
                  <span className="mt-0.5 text-brand">{starter.icon}</span>
                  <span><span className="block text-sm font-medium">{starter.label}</span><span className="mt-0.5 block text-xs text-stone">{starter.description}</span></span>
                </DropdownMenuItem>)}
              </DropdownMenuContent>
            </DropdownMenu>
            <div className="flex items-center gap-1.5">
              {canContinue && <button type="button" className="inline-flex h-8 items-center rounded-md border border-line px-2.5 text-xs font-medium text-brand hover:bg-tag disabled:opacity-45" onClick={() => void sendMessage("继续")} disabled={busy}>继续处理</button>}
              <span className="hidden text-[11px] text-stone sm:inline">Enter 发送</span>
              <button type="button" className="grid h-8 w-8 shrink-0 place-items-center rounded-md bg-brand text-paper transition-transform active:scale-95 disabled:opacity-45" onClick={handleSubmit} disabled={busy || Boolean(pendingApproval) || !input.trim()} aria-label="发送" title="发送"><Send className="h-4 w-4" /></button>
            </div>
          </div>
        </div>
      </footer>
    </section>
  );

  if (presentation === "page") return <section className="ledger-agent-page flex h-[calc(100dvh-3.5rem-env(safe-area-inset-top))] min-h-0 min-w-0 max-w-full overflow-hidden bg-paper md:h-dvh" aria-label="账本 Agent 工作区">
    <aside className="hidden min-h-0 w-72 shrink-0 flex-col border-r border-line bg-panel md:flex" aria-label="Agent 会话历史">
      <div className="flex h-16 shrink-0 items-center justify-between border-b border-line px-4"><div><h2 className="text-sm font-semibold text-ink">会话历史</h2><p className="text-xs text-stone">{sessions.length - archivedSessionCount} 个会话</p></div><div className="flex items-center gap-1">{archivedSessionCount > 0 && <button type="button" className="h-8 rounded-md px-2 text-xs text-stone hover:bg-tag" onClick={() => setShowArchivedSessions((current) => !current)}>{showArchivedSessions ? "隐藏归档" : `已归档 ${archivedSessionCount}`}</button>}<button type="button" className="grid h-8 w-8 place-items-center rounded-md border border-line text-brand hover:bg-tag disabled:opacity-50" title="新建会话" aria-label="新建会话" onClick={createSession} disabled={busy}><Plus className="h-4 w-4" /></button></div></div>
      <div className="min-h-0 flex-1 overflow-y-auto p-2">{[...sidebarSessions].sort((left, right) => right.updatedAt - left.updatedAt).map((session) => <button key={session.id} type="button" className={`mb-1 w-full rounded-md px-3 py-2.5 text-left transition ${session.id === activeSession.id ? "bg-brand text-paper" : "text-ink hover:bg-tag"}`} onClick={() => selectSession(session.id)} disabled={busy}><span className="block truncate text-sm font-medium">{session.archived && "已归档 · "}{sessionLabel(session)}</span><span className={`mt-1 block text-[11px] ${session.id === activeSession.id ? "text-paper/75" : "text-stone"}`}>{sessionTime(session)} · 已载入 {session.timeline.length} 条</span></button>)}</div>
    </aside>
    {panel("flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden bg-paper", desktopScrollRef)}
  </section>;

  return <>
    <aside className={`ledger-agent-dock hidden min-w-0 ${desktopFullscreen ? "" : "md:block"}`} data-open={open && !desktopFullscreen ? "true" : "false"} aria-label="账本 Agent 侧栏">
      {open && !desktopFullscreen && panel("flex h-full w-full min-w-0 flex-col overflow-hidden bg-paper", desktopScrollRef)}
    </aside>
    {open && desktopFullscreen && createPortal(
      <section className="fixed inset-0 z-[100] hidden overflow-hidden bg-paper md:flex" aria-label="账本 Agent 全屏工作区">
        <aside className="flex w-72 shrink-0 flex-col border-r border-line bg-panel" aria-label="Agent 会话历史">
          <div className="flex h-16 shrink-0 items-center justify-between border-b border-line px-4">
            <div><h2 className="text-sm font-semibold text-ink">会话历史</h2><p className="text-xs text-stone">{sessions.length - archivedSessionCount} 个会话</p></div>
            <div className="flex items-center gap-1">{archivedSessionCount > 0 && <button type="button" className="h-8 rounded-md px-2 text-xs text-stone hover:bg-tag" onClick={() => setShowArchivedSessions((current) => !current)}>{showArchivedSessions ? "隐藏归档" : `已归档 ${archivedSessionCount}`}</button>}<button type="button" className="grid h-8 w-8 place-items-center rounded-md border border-line text-brand hover:bg-tag disabled:opacity-50" title="新建会话" aria-label="新建会话" onClick={createSession} disabled={busy}><Plus className="h-4 w-4" /></button></div>
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto p-2">
            {[...sidebarSessions].sort((left, right) => right.updatedAt - left.updatedAt).map((session) => <button key={session.id} type="button" className={`mb-1 w-full rounded-md px-3 py-2.5 text-left transition ${session.id === activeSession.id ? "bg-brand text-paper" : "text-ink hover:bg-tag"}`} onClick={() => selectSession(session.id)} disabled={busy}>
              <span className="block truncate text-sm font-medium">{session.archived && "已归档 · "}{sessionLabel(session)}</span>
              <span className={`mt-1 block text-[11px] ${session.id === activeSession.id ? "text-paper/75" : "text-stone"}`}>{sessionTime(session)} · 已载入 {session.timeline.length} 条</span>
            </button>)}
          </div>
        </aside>
        {panel("flex min-w-0 flex-1 flex-col overflow-hidden bg-paper", fullscreenScrollRef)}
      </section>,
      document.body
    )}
    {open && createPortal(panel("fixed inset-0 z-[90] flex min-w-0 max-w-full flex-col overflow-hidden bg-paper shadow-2xl md:hidden", mobileScrollRef), document.body)}
    {open && mobileSessionListOpen && createPortal(
      <section className="fixed inset-0 z-[110] flex flex-col overflow-hidden bg-paper md:hidden" aria-label="移动端会话历史">
        <header className="flex shrink-0 items-center justify-between border-b border-line bg-panel px-3 pb-3 pt-[calc(env(safe-area-inset-top)+0.75rem)]">
          <div><h2 className="text-sm font-semibold text-ink">会话历史</h2><p className="text-xs text-stone">{sessions.length - archivedSessionCount} 个会话</p></div>
          <div className="flex items-center gap-1">
            {archivedSessionCount > 0 && <button type="button" className="h-9 rounded-md px-2 text-xs text-stone hover:bg-tag" onClick={() => setShowArchivedSessions((current) => !current)}>{showArchivedSessions ? "隐藏归档" : `已归档 ${archivedSessionCount}`}</button>}
            <button type="button" className="grid h-9 w-9 place-items-center rounded-md border border-line text-brand hover:bg-tag disabled:opacity-50" title="新建会话" aria-label="新建会话" onClick={createSession} disabled={busy}><Plus className="h-4 w-4" /></button>
            <button type="button" className="grid h-9 w-9 place-items-center rounded-md border border-line text-stone hover:bg-tag" title="返回聊天" aria-label="返回聊天" onClick={() => setMobileSessionListOpen(false)}><X className="h-4 w-4" /></button>
          </div>
        </header>
        <div className="min-h-0 flex-1 overflow-y-auto p-3 pb-[calc(env(safe-area-inset-bottom)+0.75rem)]">
          {[...sidebarSessions].sort((left, right) => right.updatedAt - left.updatedAt).map((session) => <button key={session.id} type="button" className={`mb-2 w-full rounded-md border px-3 py-3 text-left transition ${session.id === activeSession.id ? "border-brand bg-brand text-paper" : "border-line bg-panel text-ink active:bg-tag"}`} onClick={() => selectSession(session.id)} disabled={busy}>
            <span className="block truncate text-sm font-medium">{session.archived && "已归档 · "}{sessionLabel(session)}</span>
            <span className={`mt-1 block text-[11px] ${session.id === activeSession.id ? "text-paper/75" : "text-stone"}`}>{sessionTime(session)} · 已载入 {session.timeline.length} 条</span>
          </button>)}
        </div>
      </section>,
      document.body
    )}
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
  if (artifact.type === "transaction_change") {
    const original = objectString(artifact.data, "original");
    const replacement = objectString(artifact.data, "replacement");
    const reason = objectString(artifact.data, "reason");
    return <div className="min-w-0 max-w-full overflow-hidden rounded-md border border-line bg-panel">
      <h3 className="border-b border-line px-3 py-2 text-sm font-semibold text-ink">{artifact.title}</h3>
      <div className="grid divide-y divide-line sm:grid-cols-2 sm:divide-x sm:divide-y-0">
        <div className="min-w-0 p-3"><div className="mb-1.5 text-xs font-medium text-stone">原始 Beancount</div><pre className="max-h-56 overflow-auto whitespace-pre-wrap rounded-md bg-paper p-2.5 font-mono text-[11px] leading-relaxed text-ink">{original}</pre></div>
        <div className="min-w-0 p-3"><div className="mb-1.5 text-xs font-medium text-stone">{replacement ? "拟议替换" : "拟议操作"}</div>{replacement ? <pre className="max-h-56 overflow-auto whitespace-pre-wrap rounded-md bg-paper p-2.5 font-mono text-[11px] leading-relaxed text-ink">{replacement}</pre> : <div className="rounded-md bg-paper p-2.5 text-sm text-ink">删除此交易{reason ? `：${reason}` : ""}</div>}</div>
      </div>
    </div>;
  }
  if (artifact.type === "transaction_draft") {
    const entries = objectArray<ParsedTransaction>(artifact.data, "entries");
    return <div className="min-w-0 max-w-full overflow-hidden rounded-md border border-line bg-panel p-3"><h3 className="text-sm font-semibold text-ink">{artifact.title} · {entries.length}</h3><div className="mt-2 space-y-2">{entries.map((entry, index) => <div key={`${entry.date}-${entry.payee}-${index}`} className="rounded-md border border-line bg-paper p-2.5"><div className="flex min-w-0 items-center justify-between gap-3 text-sm"><strong className="truncate text-ink">{entry.date} {entry.payee}</strong><span className="shrink-0 text-stone">{entry.postings[0]?.amount} {entry.postings[0]?.currency}</span></div><div className="mt-1 truncate text-xs text-stone">{entry.narration || entry.postings.map((posting) => posting.account).join(" · ")}</div></div>)}</div></div>;
  }
  if (artifact.type === "account_draft") {
    const operations = objectArray<AccountOperation>(artifact.data, "operations");
    return <div className="rounded-md border border-line bg-panel p-3"><h3 className="text-sm font-semibold text-ink">{artifact.title} · {operations.length}</h3><div className="mt-2 divide-y divide-line border-y border-line">{operations.map((operation, index) => <div key={`${operation.kind}-${operation.account}-${index}`} className="flex items-center justify-between gap-3 py-2 text-sm"><span className="min-w-0 truncate text-ink">{operation.account}</span><span className="shrink-0 text-xs uppercase text-stone">{operation.kind}</span></div>)}</div></div>;
  }
  if (artifact.type === "memory_draft") {
    const kind = objectString(artifact.data, "kind");
    const title = objectString(artifact.data, "title");
    const instruction = objectString(artifact.data, "instruction");
    return <div className="min-w-0 max-w-full overflow-hidden rounded-md border border-line bg-panel p-3"><div className="flex items-start gap-2"><Sparkles className="mt-0.5 h-4 w-4 shrink-0 text-brand" /><div className="min-w-0"><h3 className="text-sm font-semibold text-ink">{artifact.title}</h3><p className="mt-1 text-xs text-stone">{memoryKindLabel(kind)}{title ? ` · ${title}` : ""}</p></div></div>{instruction && <p className="mt-2 break-words text-sm leading-relaxed text-olive">{instruction}</p>}</div>;
  }
  if (artifact.type === "navigation") {
    const path = objectString(artifact.data, "path");
    return <button type="button" className="flex w-full items-center justify-between rounded-md border border-line bg-panel px-3 py-2.5 text-sm text-ink hover:bg-tag" onClick={() => onNavigate(path)} disabled={!path}><span>{artifact.title}</span><ExternalLink className="h-4 w-4 text-stone" /></button>;
  }
  return null;
}

function memoryKindLabel(kind: string) {
  switch (kind) {
    case "preference": return "偏好";
    case "category_rule": return "分类规则";
    case "account_alias": return "账户别名";
    case "recurring": return "周期习惯";
    case "response_style": return "回复风格";
    default: return "记忆";
  }
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
      title: typeof session.title === "string" ? session.title.trim() : timelineTitle(restoreTimeline(session.timeline)),
      archived: session.archived === true,
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
  });
}

export function timelineNeedsServerRefresh(timeline: TimelineItem[]) {
  const last = timeline.at(-1);
  return Boolean(last && !(last.kind === "message" && last.role === "assistant"));
}

export function normalizeAgentTimelinePage(value: unknown): AgentTimelinePage {
  const page = value && typeof value === "object" ? value as Record<string, unknown> : {};
  return {
    items: restoreTimeline(page.items),
    nextBefore: typeof page.nextBefore === "number" && Number.isInteger(page.nextBefore) && page.nextBefore > 0 ? page.nextBefore : null,
  };
}

function writeStoredAgent(value: { approvalPolicy: AgentApprovalPolicy; activeSessionId: string; sessions: AgentSession[] }) {
  try {
    window.localStorage.setItem(storageKey(), JSON.stringify({
      ...value,
      // History is loaded from the server in pages. Keep only session metadata
      // locally, so browser quota can never silently trim a conversation.
      sessions: value.sessions.slice(0, MAX_STORED_SESSIONS).map((session) => ({ id: session.id, serverSessionId: session.serverSessionId, title: session.title || timelineTitle(session.timeline), archived: session.archived, createdAt: session.createdAt, updatedAt: session.updatedAt, timeline: [] })),
    }));
  } catch {
    // Conversation persistence is optional.
  }
}
